import 'package:flutter/foundation.dart';

import '../models/memory_entry.dart';
import '../services/logging/flutter_logger.dart';
import '../services/memory_store.dart';

/// Long-term memory provider.
///
/// Loads lazily on first use: request assembly awaits [initialize], so a cold
/// start that goes straight to chat still injects existing memories (P0-1).
class MemoryProvider extends ChangeNotifier {
  List<MemoryEntry> _entries = <MemoryEntry>[];
  bool _initialized = false;
  int _loadedRevision = -1;
  Future<void>? _loading;

  List<MemoryEntry> get all => List<MemoryEntry>.unmodifiable(_entries);
  bool get initialized => _initialized;

  bool get isEmpty => _entries.isEmpty;

  /// Active entries visible from [assistantId]: its own plus global entries.
  List<MemoryEntry> visibleFor(String assistantId) => _entries
      .where(
        (e) =>
            e.status == MemoryStatus.active &&
            (e.scope == MemoryScope.global || e.assistantId == assistantId),
      )
      .toList();

  List<MemoryEntry> forAssistant(
    String assistantId, {
    bool includeArchived = true,
  }) => _entries
      .where(
        (e) =>
            (includeArchived || e.status == MemoryStatus.active) &&
            (e.scope == MemoryScope.global || e.assistantId == assistantId),
      )
      .toList();

  /// Global entries only (for the global memory settings page).
  List<MemoryEntry> get globalEntries =>
      _entries.where((e) => e.scope == MemoryScope.global).toList();

  /// Single-flight initialization; safe to call from every request assembly.
  ///
  /// A backup restore bumps [MemoryStore.revision], so the next call reloads
  /// even when this provider was already initialized.
  Future<void> initialize() {
    if (_initialized && _loadedRevision == MemoryStore.revision) {
      return Future<void>.value();
    }
    final pending = _loading;
    if (pending != null) return pending;
    final future = _loadFromStore();
    _loading = future;
    return future.whenComplete(() => _loading = null);
  }

  Future<void> _loadFromStore() async {
    try {
      _entries = await MemoryStore.getAll();
      _initialized = true;
      _loadedRevision = MemoryStore.revision;
      notifyListeners();
    } catch (e, st) {
      // Keep `_initialized` false so the next request retries instead of
      // serving an empty memory list for the rest of the session.
      _initialized = false;
      FlutterLogger.log(
        'Failed to load memories: $e\n$st',
        tag: 'memory-provider',
      );
    }
  }

  /// Explicit reload; throws when the store cannot be read.
  Future<void> loadAll() async {
    _entries = await MemoryStore.getAll();
    _initialized = true;
    _loadedRevision = MemoryStore.revision;
    notifyListeners();
  }

  /// Reloads after an external mutation (backup restore, assistant deletion).
  /// Never throws: a failed refresh must not fail the completed restore.
  Future<void> reload() async {
    try {
      await loadAll();
    } catch (e, st) {
      FlutterLogger.log(
        'Failed to reload memories: $e\n$st',
        tag: 'memory-provider',
      );
    }
  }

  Future<MemoryWriteResult> add({
    required MemoryScope scope,
    String? assistantId,
    required MemoryType type,
    required String content,
    MemorySource source = MemorySource.manual,
    bool skipExactDuplicate = false,
  }) async {
    final result = await MemoryStore.insert(
      scope: scope,
      assistantId: assistantId,
      type: type,
      content: content,
      source: source,
      skipExactDuplicate: skipExactDuplicate,
    );
    await _reloadSilently();
    return result;
  }

  Future<MemoryWriteResult?> updateEntry(
    String id, {
    String? content,
    MemoryType? type,
    MemoryScope? scope,
    String? assistantId,
    MemoryStatus? status,
  }) async {
    final result = await MemoryStore.update(
      id,
      content: content,
      type: type,
      scope: scope,
      assistantId: assistantId,
      status: status,
    );
    await _reloadSilently();
    return result;
  }

  Future<bool> archive(String id) async {
    final ok = await MemoryStore.archive(id);
    await _reloadSilently();
    return ok;
  }

  Future<bool> restore(String id) async {
    final ok = await MemoryStore.restore(id);
    await _reloadSilently();
    return ok;
  }

  Future<bool> deletePermanently(String id) async {
    final ok = await MemoryStore.deletePermanently(id);
    await _reloadSilently();
    return ok;
  }

  Future<void> _reloadSilently() async {
    try {
      _entries = await MemoryStore.getAll();
      _initialized = true;
      _loadedRevision = MemoryStore.revision;
      notifyListeners();
    } catch (e, st) {
      // The write already succeeded; a refresh failure must not turn it into
      // a tool error (the model would retry and duplicate the entry).
      FlutterLogger.log(
        'Failed to refresh memories after write: $e\n$st',
        tag: 'memory-provider',
      );
    }
  }
}
