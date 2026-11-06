import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:OmniChat/core/models/memory_entry.dart';
import 'package:OmniChat/core/services/memory_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MemoryStore.resetForTest();
  });

  test('round-trips typed entries through memory_entries_v2', () async {
    await MemoryStore.insert(
      type: MemoryType.identity,
      content: 'likes tea',
      scope: MemoryScope.assistant,
      assistantId: 'a1',
    );
    await MemoryStore.insert(
      type: MemoryType.workflow,
      content: 'ships Flutter apps',
      scope: MemoryScope.assistant,
      assistantId: 'a1',
    );
    await MemoryStore.insert(
      type: MemoryType.voice,
      content: 'prefers concise answers',
      scope: MemoryScope.global,
    );

    await MemoryStore.invalidateCache();
    final all = await MemoryStore.getAll();
    expect(all, hasLength(3));
    final global = all.firstWhere((e) => e.scope == MemoryScope.global);
    expect(global.assistantId, isNull);
    expect(global.type, MemoryType.voice);
    expect(global.source, MemorySource.manual);
    expect(global.createdAt.microsecondsSinceEpoch, greaterThan(0));
  });

  test('truncates content at 2000 characters on write', () async {
    final result = await MemoryStore.insert(
      type: MemoryType.identity,
      content: 'x' * 2500,
      scope: MemoryScope.assistant,
      assistantId: 'a1',
    );
    expect(result.truncated, isTrue);
    expect(result.entry.content.length, MemoryEntry.maxContentChars);
  });

  test('skips exact duplicates when asked', () async {
    final first = await MemoryStore.insert(
      type: MemoryType.identity,
      content: 'Likes  Tea',
      scope: MemoryScope.assistant,
      assistantId: 'a1',
      skipExactDuplicate: true,
    );
    final second = await MemoryStore.insert(
      type: MemoryType.identity,
      content: ' likes tea ',
      scope: MemoryScope.assistant,
      assistantId: 'a1',
      skipExactDuplicate: true,
    );
    expect(first.duplicate, isFalse);
    expect(second.duplicate, isTrue);
    expect(second.entry.id, first.entry.id);
    expect(await MemoryStore.getAll(), hasLength(1));
  });

  test('imports legacy assistant_memories_v1 once and keeps the key', () async {
    final legacy = jsonEncode(<Map<String, dynamic>>[
      {'id': 1, 'assistantId': 'a1', 'content': 'old fact one'},
      {'id': 2, 'assistantId': 'a1', 'content': 'old fact two'},
    ]);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'assistant_memories_v1': legacy,
    });
    MemoryStore.resetForTest();

    final imported = await MemoryStore.getAll();
    expect(imported, hasLength(2));
    expect(imported.every((e) => e.type == MemoryType.identity), isTrue);
    expect(imported.every((e) => e.source == MemorySource.manual), isTrue);
    expect(imported.every((e) => e.scope == MemoryScope.assistant), isTrue);
    expect(imported.every((e) => e.assistantId == 'a1'), isTrue);
    expect(await MemoryStore.legacyImportedCount(), 2);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('assistant_memories_v1'), legacy);
    expect(prefs.getString(MemoryStore.v2Key), isNotNull);
  });

  test('serializes concurrent writes without lost updates', () async {
    await Future.wait(<Future<void>>[
      for (var i = 0; i < 10; i++)
        MemoryStore.insert(
          type: MemoryType.identity,
          content: 'concurrent fact $i',
          scope: MemoryScope.assistant,
          assistantId: 'a1',
        ),
    ]);
    expect(await MemoryStore.getAll(), hasLength(10));
  });

  test('archives, restores and permanently deletes', () async {
    final result = await MemoryStore.insert(
      type: MemoryType.identity,
      content: 'temporary',
      scope: MemoryScope.assistant,
      assistantId: 'a1',
    );
    expect(await MemoryStore.archive(result.entry.id), isTrue);
    expect((await MemoryStore.getAll()).first.isArchived, isTrue);
    expect(await MemoryStore.getVisibleFor('a1'), isEmpty);
    expect(await MemoryStore.restore(result.entry.id), isTrue);
    expect(await MemoryStore.getVisibleFor('a1'), hasLength(1));
    expect(await MemoryStore.deletePermanently(result.entry.id), isTrue);
    expect(await MemoryStore.getAll(), isEmpty);
  });

  test('deletes assistant-scoped orphans but keeps global entries', () async {
    await MemoryStore.insert(
      type: MemoryType.identity,
      content: 'a1 fact',
      scope: MemoryScope.assistant,
      assistantId: 'a1',
    );
    await MemoryStore.insert(
      type: MemoryType.identity,
      content: 'a2 fact',
      scope: MemoryScope.assistant,
      assistantId: 'a2',
    );
    await MemoryStore.insert(
      type: MemoryType.identity,
      content: 'global fact',
      scope: MemoryScope.global,
    );
    final archived = await MemoryStore.insert(
      type: MemoryType.identity,
      content: 'a1 archived',
      scope: MemoryScope.assistant,
      assistantId: 'a1',
    );
    await MemoryStore.archive(archived.entry.id);

    expect(await MemoryStore.deleteOrphanAssistantMemories('a1'), 2);
    final remaining = await MemoryStore.getAll();
    expect(remaining, hasLength(2));
    expect(remaining.any((e) => e.assistantId == 'a1'), isFalse);
    expect(remaining.any((e) => e.scope == MemoryScope.global), isTrue);
  });

  test('malformed payloads decode to an empty list instead of throwing', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      MemoryStore.v2Key: '{not json',
    });
    MemoryStore.resetForTest();
    expect(await MemoryStore.getAll(), isEmpty);
  });

  test('getVisibleFor includes global and own entries only', () async {
    await MemoryStore.insert(
      type: MemoryType.identity,
      content: 'own',
      scope: MemoryScope.assistant,
      assistantId: 'a1',
    );
    await MemoryStore.insert(
      type: MemoryType.identity,
      content: 'other',
      scope: MemoryScope.assistant,
      assistantId: 'a2',
    );
    await MemoryStore.insert(
      type: MemoryType.identity,
      content: 'global',
      scope: MemoryScope.global,
    );
    final visible = await MemoryStore.getVisibleFor('a1');
    expect(visible.map((e) => e.content), containsAll(['own', 'global']));
    expect(visible.map((e) => e.content), isNot(contains('other')));
  });
}
