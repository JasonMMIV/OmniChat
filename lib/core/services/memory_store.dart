import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/assistant_memory.dart';
import 'logging/flutter_logger.dart';
import '../models/memory_entry.dart';

/// Result of a write attempt.
class MemoryWriteResult {
  const MemoryWriteResult({
    required this.entry,
    this.truncated = false,
    this.duplicate = false,
  });

  final MemoryEntry entry;
  final bool truncated;
  final bool duplicate;
}

/// v2 memory store: SharedPreferences JSON (`memory_entries_v2`) with typed
/// payloads, a legacy v1 importer and a single serialized write path.
class MemoryStore {
  const MemoryStore._();

  static const String v2Key = 'memory_entries_v2';
  static const String legacyKey = 'assistant_memories_v1';
  static const String legacyImportCountKey = 'memory_v1_import_count_v2';

  /// Soft cap: writes are still accepted above it, the tool returns a warning.
  static const int softEntryLimit = 200;

  static List<MemoryEntry>? _cache;
  static Future<void> _queue = Future<void>.value();

  /// Bumped whenever the persisted payload may have changed outside this
  /// process-local cache (backup restore). Providers compare it in
  /// `initialize()` so a restore becomes visible without an app restart.
  static int _revision = 0;
  static int get revision => _revision;

  static bool get isLoaded => _cache != null;

  /// Runs [action] after every previously queued write, eliminating the
  /// lost-update race of read-modify-write on a shared JSON blob.
  static Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  static Future<List<MemoryEntry>> _loadLocked() async {
    if (_cache != null) return _cache!;
    final prefs = await SharedPreferences.getInstance();
    var raw = prefs.getString(v2Key);
    if (raw == null) {
      final imported = await _importLegacyLocked(prefs);
      _cache = imported;
      return imported;
    }
    _cache = _decodePayload(raw);
    return _cache!;
  }

  static List<MemoryEntry> _decodePayload(String raw) {
    if (raw.trim().isEmpty) return <MemoryEntry>[];
    try {
      final decoded = jsonDecode(raw);
      final List<dynamic> arr;
      if (decoded is Map) {
        arr = (decoded['entries'] as List?) ?? const <dynamic>[];
      } else if (decoded is List) {
        arr = decoded;
      } else {
        return <MemoryEntry>[];
      }
      final out = <MemoryEntry>[];
      final seenIds = <String>{};
      var dropped = 0;
      for (final e in arr) {
        if (e is! Map) continue;
        final entry = MemoryEntry.fromJson(e.cast<String, dynamic>());
        if (entry.content.trim().isEmpty) continue;
        // Entries without a stable id cannot be edited or merged reliably;
        // skip them instead of inventing a new identity on every load.
        if (entry.id.isEmpty || !seenIds.add(entry.id)) {
          dropped++;
          continue;
        }
        out.add(entry);
      }
      if (dropped > 0) {
        FlutterLogger.log(
          'Memory payload: dropped $dropped entr(ies) without a unique id',
          tag: 'memory-store',
        );
      }
      return out;
    } catch (_) {
      return <MemoryEntry>[];
    }
  }

  /// One-time import of `assistant_memories_v1`. The legacy key is kept
  /// read-only: nothing is moved or deleted so a rollback can still find it.
  static Future<List<MemoryEntry>> _importLegacyLocked(
    SharedPreferences prefs,
  ) async {
    final legacyRaw = prefs.getString(legacyKey);
    if (legacyRaw == null || legacyRaw.trim().isEmpty) return <MemoryEntry>[];

    final List<AssistantMemory> legacy;
    try {
      final arr = jsonDecode(legacyRaw) as List<dynamic>;
      legacy = <AssistantMemory>[
        for (final e in arr)
          if (e is Map) AssistantMemory.fromJson(e.cast<String, dynamic>()),
      ];
    } catch (_) {
      return <MemoryEntry>[];
    }

    final now = DateTime.now();
    final seen = <String>{};
    final out = <MemoryEntry>[];
    for (final m in legacy) {
      final content = m.content.trim();
      if (content.isEmpty) continue;
      final assistantId = m.assistantId.trim();
      final scope = assistantId.isEmpty
          ? MemoryScope.global
          : MemoryScope.assistant;
      final norm = MemoryEntry.normalizeContent(content);
      final dedupeKey = '${scope.name}|${assistantId.toLowerCase()}|$norm';
      if (!seen.add(dedupeKey)) continue;
      out.add(
        MemoryEntry(
          id: _uniqueId(out),
          scope: scope,
          assistantId: scope == MemoryScope.assistant ? assistantId : null,
          type: MemoryType.identity,
          status: MemoryStatus.active,
          content: content,
          source: MemorySource.manual,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }

    final payload = <String, dynamic>{
      'v': 2,
      'entries': <Map<String, dynamic>>[for (final e in out) e.toJson()],
    };
    await prefs.setString(v2Key, jsonEncode(payload));
    await prefs.setInt(legacyImportCountKey, out.length);
    return out;
  }

  static String _uniqueId(List<MemoryEntry> existing) {
    final used = existing.map((e) => e.id).toSet();
    var id = MemoryEntry.generateId();
    var guard = 0;
    while (used.contains(id) && guard < 16) {
      id = MemoryEntry.generateId();
      guard++;
    }
    return id;
  }

  static Future<void> _persist(List<MemoryEntry> entries) async {
    _cache = List<MemoryEntry>.of(entries);
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      'v': 2,
      'entries': <Map<String, dynamic>>[for (final e in entries) e.toJson()],
    };
    await prefs.setString(v2Key, jsonEncode(payload));
  }

  static Future<List<MemoryEntry>> getAll() => _serialized(() async {
    final loaded = await _loadLocked();
    return List<MemoryEntry>.of(loaded);
  });

  /// Active entries visible from one assistant: its own plus global.
  static Future<List<MemoryEntry>> getVisibleFor(String assistantId) async {
    final all = await getAll();
    return all
        .where(
          (e) =>
              e.status == MemoryStatus.active &&
              (e.scope == MemoryScope.global || e.assistantId == assistantId),
        )
        .toList();
  }

  /// All entries visible from one assistant (including archived), for UI.
  static Future<List<MemoryEntry>> getForAssistant(
    String assistantId, {
    bool includeArchived = true,
  }) async {
    final all = await getAll();
    return all
        .where(
          (e) =>
              (includeArchived || e.status == MemoryStatus.active) &&
              (e.scope == MemoryScope.global || e.assistantId == assistantId),
        )
        .toList();
  }

  /// Truncates to [MemoryEntry.maxContentChars]; returns whether it happened.
  static ({String content, bool truncated}) _prepareContent(String content) {
    final trimmed = content.trim();
    if (trimmed.length <= MemoryEntry.maxContentChars) {
      return (content: trimmed, truncated: false);
    }
    return (
      content: trimmed.substring(0, MemoryEntry.maxContentChars),
      truncated: true,
    );
  }

  static Future<MemoryWriteResult> insert({
    required MemoryType type,
    required String content,
    required MemoryScope scope,
    String? assistantId,
    MemorySource source = MemorySource.manual,
    bool skipExactDuplicate = false,
  }) => _serialized(() async {
    final all = await _loadLocked();
    final prepared = _prepareContent(content);
    final text = prepared.content;
    final normalizedAssistantId = (assistantId ?? '').trim();
    final resolvedScope = normalizedAssistantId.isEmpty
        ? MemoryScope.global
        : scope;
    final resolvedAssistantId = resolvedScope == MemoryScope.assistant
        ? normalizedAssistantId
        : null;

    if (skipExactDuplicate) {
      final norm = MemoryEntry.normalizeContent(text);
      for (final existing in all) {
        if (existing.status != MemoryStatus.active) continue;
        if (existing.scope != resolvedScope) continue;
        if ((existing.assistantId ?? '') != (resolvedAssistantId ?? '')) {
          continue;
        }
        if (existing.normalizedContent == norm) {
          return MemoryWriteResult(
            entry: existing,
            duplicate: true,
            truncated: prepared.truncated,
          );
        }
      }
    }

    final now = DateTime.now();
    final entry = MemoryEntry(
      id: _uniqueId(all),
      scope: resolvedScope,
      assistantId: resolvedAssistantId,
      type: type,
      status: MemoryStatus.active,
      content: text,
      source: source,
      createdAt: now,
      updatedAt: now,
    );
    final next = List<MemoryEntry>.of(all)..add(entry);
    await _persist(next);
    return MemoryWriteResult(entry: entry, truncated: prepared.truncated);
  });

  static Future<MemoryWriteResult?> update(
    String id, {
    String? content,
    MemoryType? type,
    MemoryScope? scope,
    String? assistantId,
    MemoryStatus? status,
    MemorySource? source,
  }) => _serialized(() async {
    final all = await _loadLocked();
    final idx = all.indexWhere((e) => e.id == id);
    if (idx == -1) return null;
    final current = all[idx];
    final prepared = content == null ? null : _prepareContent(content);
    var next = current.copyWith(
      content: prepared?.content,
      type: type,
      status: status,
      source: source,
      updatedAt: DateTime.now(),
    );
    if (scope != null) {
      final resolvedAssistantId = (assistantId ?? current.assistantId ?? '')
          .trim();
      if (scope == MemoryScope.assistant) {
        if (resolvedAssistantId.isEmpty) {
          // Never downgrade an assistant-scoped write to global silently:
          // callers must pass the owning assistant id.
          throw ArgumentError.value(
            assistantId,
            'assistantId',
            'assistantId is required for an assistant-scoped memory.',
          );
        }
        next = next.copyWith(
          scope: MemoryScope.assistant,
          assistantId: resolvedAssistantId,
        );
      } else {
        next = next.copyWith(scope: MemoryScope.global, clearAssistantId: true);
      }
    }
    final truncated = prepared?.truncated ?? false;
    final updated = List<MemoryEntry>.of(all)..[idx] = next;
    await _persist(updated);
    return MemoryWriteResult(entry: next, truncated: truncated);
  });

  static Future<bool> archive(String id) =>
      _setStatus(id, MemoryStatus.archived);

  static Future<bool> restore(String id) => _setStatus(id, MemoryStatus.active);

  static Future<bool> _setStatus(String id, MemoryStatus status) =>
      _serialized(() async {
        final all = await _loadLocked();
        final idx = all.indexWhere((e) => e.id == id);
        if (idx == -1) return false;
        final updated = List<MemoryEntry>.of(all)
          ..[idx] = all[idx].copyWith(
            status: status,
            updatedAt: DateTime.now(),
          );
        await _persist(updated);
        return true;
      });

  static Future<bool> deletePermanently(String id) => _serialized(() async {
    final all = await _loadLocked();
    final next = all.where((e) => e.id != id).toList();
    if (next.length == all.length) return false;
    await _persist(next);
    return true;
  });

  /// Removes every assistant-scoped entry (active and archived) when the
  /// owning assistant is deleted.
  static Future<int> deleteOrphanAssistantMemories(String assistantId) =>
      _serialized(() async {
        final all = await _loadLocked();
        final next = all
            .where(
              (e) =>
                  !(e.scope == MemoryScope.assistant &&
                      e.assistantId == assistantId),
            )
            .toList();
        final removed = all.length - next.length;
        if (removed > 0) await _persist(next);
        return removed;
      });

  static Future<int> legacyImportedCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(legacyImportCountKey) ?? 0;
  }

  /// Forces the next read to reload from SharedPreferences (backup restore).
  static Future<void> invalidateCache() => _serialized(() async {
    _cache = null;
    _revision++;
  });

  /// Test hook: clears in-memory state and the write queue.
  static void resetForTest() {
    _cache = null;
    _queue = Future<void>.value();
    _revision++;
  }

  /// Merges two `memory_entries_v2` payloads for backup merge mode.
  ///
  /// Identity is (scope, assistantId, normalized content); on conflict the
  /// newer `updatedAt` wins. Above [softEntryLimit], the oldest archived
  /// entries are dropped first, then the oldest active ones.
  static String mergePayloads(String? existingRaw, String? incomingRaw) {
    final merged = <String, MemoryEntry>{};
    void addAll(String? raw) {
      if (raw == null || raw.trim().isEmpty) return;
      for (final entry in _decodePayload(raw)) {
        final key = '${entry.scope.name}|'
            '${(entry.assistantId ?? '').toLowerCase()}|'
            '${entry.normalizedContent}';
        final current = merged[key];
        if (current == null ||
            entry.updatedAt.isAfter(current.updatedAt)) {
          merged[key] = entry;
        }
      }
    }

    addAll(existingRaw);
    addAll(incomingRaw);

    var entries = merged.values.toList();
    if (entries.length > softEntryLimit) {
      final removable = entries.toList()
        ..sort((a, b) {
          if (a.isArchived != b.isArchived) return a.isArchived ? -1 : 1;
          final byUpdated = a.updatedAt.compareTo(b.updatedAt);
          return byUpdated != 0 ? byUpdated : a.id.compareTo(b.id);
        });
      final drop = <String>{
        for (final e in removable.take(entries.length - softEntryLimit)) e.id,
      };
      entries = entries.where((e) => !drop.contains(e.id)).toList();
    }

    return jsonEncode(<String, dynamic>{
      'v': 2,
      'entries': <Map<String, dynamic>>[for (final e in entries) e.toJson()],
    });
  }
}

