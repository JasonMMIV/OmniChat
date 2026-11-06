import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/models/memory_entry.dart';
import 'package:OmniChat/core/services/memory_store.dart';

String _payload(List<MemoryEntry> entries) => jsonEncode(<String, dynamic>{
  'v': 2,
  'entries': [for (final e in entries) e.toJson()],
});

MemoryEntry _entry({
  required String id,
  required String content,
  String assistantId = 'a1',
  MemoryScope scope = MemoryScope.assistant,
  MemoryStatus status = MemoryStatus.active,
  DateTime? updated,
}) => MemoryEntry(
  id: id,
  scope: scope,
  assistantId: scope == MemoryScope.assistant ? assistantId : null,
  type: MemoryType.identity,
  status: status,
  content: content,
  source: MemorySource.manual,
  createdAt: updated ?? DateTime(2026, 1, 1),
  updatedAt: updated ?? DateTime(2026, 1, 1),
);

List<MemoryEntry> _decode(String raw) {
  final map = jsonDecode(raw) as Map<String, dynamic>;
  return [
    for (final e in map['entries'] as List)
      MemoryEntry.fromJson((e as Map).cast<String, dynamic>()),
  ];
}

void main() {
  test('unions both sides by scope, assistant and normalized content', () {
    final merged = _decode(
      MemoryStore.mergePayloads(
        _payload([_entry(id: 'mem_1', content: 'likes tea')]),
        _payload([_entry(id: 'mem_2', content: 'ships Flutter apps')]),
      ),
    );
    expect(merged, hasLength(2));
    expect(merged.map((e) => e.content), containsAll(['likes tea', 'ships Flutter apps']));
  });

  test('a normalized duplicate keeps the newer updatedAt', () {
    final merged = _decode(
      MemoryStore.mergePayloads(
        _payload([
          _entry(
            id: 'mem_old',
            content: 'Likes  Tea',
            updated: DateTime(2026, 1, 1),
          ),
        ]),
        _payload([
          _entry(
            id: 'mem_new',
            content: 'likes tea',
            updated: DateTime(2026, 2, 1),
          ),
        ]),
      ),
    );
    expect(merged, hasLength(1));
    expect(merged.single.id, 'mem_new');
  });

  test('equal timestamps keep the existing local entry', () {
    final merged = _decode(
      MemoryStore.mergePayloads(
        _payload([_entry(id: 'mem_local', content: 'fact')]),
        _payload([_entry(id: 'mem_remote', content: 'fact')]),
      ),
    );
    expect(merged.single.id, 'mem_local');
  });

  test('different scopes are distinct entries', () {
    final merged = _decode(
      MemoryStore.mergePayloads(
        _payload([_entry(id: 'mem_1', content: 'fact')]),
        _payload([
          _entry(id: 'mem_2', content: 'fact', scope: MemoryScope.global),
        ]),
      ),
    );
    expect(merged, hasLength(2));
  });

  test('caps at 200 by dropping the oldest archived entries first', () {
    final entries = <MemoryEntry>[
      for (var i = 0; i < 150; i++)
        _entry(
          id: 'mem_a${i.toString().padLeft(3, '0')}',
          content: 'archived $i',
          status: MemoryStatus.archived,
          updated: DateTime(2025, 1, 1).add(Duration(minutes: i)),
        ),
      for (var i = 0; i < 60; i++)
        _entry(
          id: 'mem_b${i.toString().padLeft(3, '0')}',
          content: 'active $i',
          updated: DateTime(2026, 1, 1).add(Duration(minutes: i)),
        ),
    ];
    final merged = _decode(MemoryStore.mergePayloads(null, _payload(entries)));
    expect(merged, hasLength(200));
    expect(merged.where((e) => !e.isArchived), hasLength(60));
    expect(merged.where((e) => e.isArchived), hasLength(140));
    // The ten oldest archived entries are the ones dropped.
    expect(merged.any((e) => e.id == 'mem_a000'), isFalse);
    expect(merged.any((e) => e.id == 'mem_a009'), isFalse);
    expect(merged.any((e) => e.id == 'mem_a010'), isTrue);
  });
}
