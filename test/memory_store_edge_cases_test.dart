import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/memory_entry.dart';
import 'package:OmniChat/core/services/memory_store.dart';

MemoryEntry _entry({required String id, String content = 'fact'}) =>
    MemoryEntry(
      id: id,
      scope: MemoryScope.assistant,
      assistantId: 'a1',
      type: MemoryType.identity,
      status: MemoryStatus.active,
      content: content,
      source: MemorySource.manual,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MemoryStore.resetForTest();
  });

  test('missing ids are not invented during decode', () {
    final decoded = MemoryEntry.fromJson(<String, dynamic>{
      'scope': 'assistant',
      'assistantId': 'a1',
      'type': 'identity',
      'content': 'fact',
    });
    expect(decoded.id, isEmpty);
  });

  test('payload rows without an id are skipped', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      MemoryStore.v2Key: jsonEncode(<String, dynamic>{
        'v': 2,
        'entries': <Map<String, dynamic>>[
          _entry(id: 'mem_00000001').toJson(),
          <String, dynamic>{'content': 'orphan without id'},
          _entry(id: 'mem_00000001', content: 'duplicate id').toJson(),
        ],
      }),
    });
    MemoryStore.resetForTest();

    final entries = await MemoryStore.getAll();
    expect(entries, hasLength(1));
    expect(entries.single.id, 'mem_00000001');
  });

  test('assistant scope without an assistant id is rejected', () async {
    final created = await MemoryStore.insert(
      scope: MemoryScope.global,
      type: MemoryType.identity,
      content: 'global fact',
    );

    await expectLater(
      MemoryStore.update(created.entry.id, scope: MemoryScope.assistant),
      throwsArgumentError,
    );
  });
}
