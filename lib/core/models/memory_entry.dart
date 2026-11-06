import 'dart:math';

/// Long-term memory model (v2).
///
/// Reference: `docs/記憶功能改善實作計畫(已實作).md` M2-1. Behaviour contract adapted
/// from Chevey339/kelivo's memory rewrite (AGPL-3.0); this is an independent
/// implementation for OmniChat, not a line-by-line port.

enum MemoryScope { global, assistant }

enum MemoryType { identity, workflow, voice, instruction }

enum MemoryStatus { active, archived }

enum MemorySource { manual, tool, extracted, distilled }

/// How an assistant decides the scope of memories written through tools.
enum MemoryWriteScope {
  alwaysGlobal,
  alwaysAssistant,
  toolDefaultGlobal,
  toolDefaultAssistant,
}

/// Dedupe strategy used by the manual memory organizer (Phase 3).
enum MemoryDedupeMode { strict, llm }

class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.scope,
    required this.assistantId,
    required this.type,
    required this.status,
    required this.content,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Single-entry write cap (characters, not bytes — mixed CJK/Latin content
  /// is roughly ≤ 6 KB UTF-8 at this limit).
  static const int maxContentChars = 2000;

  final String id;
  final MemoryScope scope;

  /// Required when [scope] is [MemoryScope.assistant]; null for global.
  final String? assistantId;
  final MemoryType type;
  final MemoryStatus status;
  final String content;
  final MemorySource source;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isGlobal => scope == MemoryScope.global;
  bool get isArchived => status == MemoryStatus.archived;

  /// Content identity used for exact-duplicate detection: trimmed, collapsed
  /// whitespace, lowercased.
  static String normalizeContent(String input) =>
      input.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  String get normalizedContent => normalizeContent(content);

  /// `mem_` + 8 lowercase hex characters.
  static String generateId([Random? random]) {
    final rnd = random ?? Random.secure();
    final buf = StringBuffer('mem_');
    for (var i = 0; i < 8; i++) {
      buf.write(rnd.nextInt(16).toRadixString(16));
    }
    return buf.toString();
  }

  MemoryEntry copyWith({
    String? id,
    MemoryScope? scope,
    String? assistantId,
    bool clearAssistantId = false,
    MemoryType? type,
    MemoryStatus? status,
    String? content,
    MemorySource? source,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => MemoryEntry(
    id: id ?? this.id,
    scope: scope ?? this.scope,
    assistantId: clearAssistantId ? null : (assistantId ?? this.assistantId),
    type: type ?? this.type,
    status: status ?? this.status,
    content: content ?? this.content,
    source: source ?? this.source,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'scope': scope.name,
    'assistantId': scope == MemoryScope.assistant ? assistantId : null,
    'type': type.name,
    'status': status.name,
    'content': content,
    'source': source.name,
    'createdAt': createdAt.microsecondsSinceEpoch,
    'updatedAt': updatedAt.microsecondsSinceEpoch,
  };

  /// Defensive payload parsing: every field falls back to a default so a
  /// cross-version or hand-edited backup can never crash the load.
  static MemoryEntry fromJson(Map<String, dynamic> json) {
    final scope = _enumByName(
      MemoryScope.values,
      json['scope'],
      MemoryScope.assistant,
    );
    final rawAssistantId = (json['assistantId'] ?? '').toString().trim();
    final createdAt = _dateFromMicros(json['createdAt']);
    final updatedAt = _dateFromMicros(json['updatedAt']);
    final content = (json['content'] ?? '').toString();
    // Missing ids stay empty: inventing an id on every decode would give the
    // same entry a different identity on each load (merge/edit instability).
    // MemoryStore skips id-less payload rows instead.
    final id = (json['id'] ?? '').toString().trim();
    return MemoryEntry(
      id: id,
      scope: scope,
      assistantId: scope == MemoryScope.assistant && rawAssistantId.isNotEmpty
          ? rawAssistantId
          : null,
      type: _enumByName(MemoryType.values, json['type'], MemoryType.identity),
      status: _enumByName(
        MemoryStatus.values,
        json['status'],
        MemoryStatus.active,
      ),
      content: content,
      source: _enumByName(MemorySource.values, json['source'], MemorySource.manual),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  static DateTime _dateFromMicros(Object? raw) {
    final micros = (raw as num?)?.toInt() ?? 0;
    if (micros <= 0) return DateTime.fromMicrosecondsSinceEpoch(0);
    return DateTime.fromMicrosecondsSinceEpoch(micros);
  }

  static T _enumByName<T extends Enum>(List<T> values, Object? raw, T fallback) {
    final name = (raw ?? '').toString().trim().toLowerCase();
    for (final v in values) {
      if (v.name.toLowerCase() == name) return v;
    }
    return fallback;
  }
}
