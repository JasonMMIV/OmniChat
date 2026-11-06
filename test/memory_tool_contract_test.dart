import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/assistant.dart';
import 'package:OmniChat/core/models/memory_entry.dart';
import 'package:OmniChat/core/providers/memory_provider.dart';
import 'package:OmniChat/core/services/memory/memory_tool_handler.dart';
import 'package:OmniChat/core/services/memory/memory_tools.dart';
import 'package:OmniChat/core/services/memory_store.dart';
import 'package:OmniChat/features/home/services/tool_handler_service.dart';

Map<String, dynamic> _decode(String? raw) =>
    (jsonDecode(raw!) as Map).cast<String, dynamic>();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MemoryStore.resetForTest();
  });

  test('advertises the V1 tool surface and scope only under toolDefault*', () {
    final withScope = MemoryTools.definitions(allowScopeParameter: true);
    final withoutScope = MemoryTools.definitions(allowScopeParameter: false);
    List<String> names(List<Map<String, dynamic>> defs) => [
      for (final d in defs) ((d['function'] as Map)['name']).toString(),
    ];
    expect(names(withScope), [
      'memory_read',
      'memory_update',
      'memory_edit',
      'memory_delete',
    ]);
    final updateWith = (withScope[1]['function'] as Map)['parameters'] as Map;
    final updateWithout =
        (withoutScope[1]['function'] as Map)['parameters'] as Map;
    expect((updateWith['properties'] as Map).containsKey('scope'), isTrue);
    expect((updateWithout['properties'] as Map).containsKey('scope'), isFalse);
    expect(names(withoutScope), isNot(contains('create_memory')));
  });

  test('tool scope is allowed only for the two toolDefault policies', () {
    const alwaysGlobal = Assistant(
      id: 'a1',
      name: 'A',
      memoryWriteScope: MemoryWriteScope.alwaysGlobal,
    );
    const alwaysAssistant = Assistant(
      id: 'a1',
      name: 'A',
      memoryWriteScope: MemoryWriteScope.alwaysAssistant,
    );
    const toolGlobal = Assistant(
      id: 'a1',
      name: 'A',
      memoryWriteScope: MemoryWriteScope.toolDefaultGlobal,
    );
    const toolAssistant = Assistant(
      id: 'a1',
      name: 'A',
      memoryWriteScope: MemoryWriteScope.toolDefaultAssistant,
    );
    expect(ToolHandlerService.allowsMemoryToolScope(alwaysGlobal), isFalse);
    expect(ToolHandlerService.allowsMemoryToolScope(alwaysAssistant), isFalse);
    expect(ToolHandlerService.allowsMemoryToolScope(toolGlobal), isTrue);
    expect(ToolHandlerService.allowsMemoryToolScope(toolAssistant), isTrue);
  });

  test(
    'memory_update returns JSON with an id and honours scope policy',
    () async {
      final provider = MemoryProvider();
      const assistant = Assistant(
        id: 'a1',
        name: 'A',
        enableMemory: true,
        memoryWriteScope: MemoryWriteScope.alwaysGlobal,
      );

      final created = _decode(
        await MemoryToolHandler.handle(
          'memory_update',
          {
            'type': 'identity',
            'content': 'prefers concise answers',
            'scope': 'assistant',
          },
          assistant,
          provider,
        ),
      );
      expect(created['action'], 'created');
      expect(created['id'], startsWith('mem_'));
      final entries = await MemoryStore.getAll();
      expect(entries.single.scope, MemoryScope.global);
      expect(entries.single.source, MemorySource.tool);

      final skipped = _decode(
        await MemoryToolHandler.handle(
          'memory_update',
          {'type': 'identity', 'content': 'Prefers  concise answers'},
          assistant,
          provider,
        ),
      );
      expect(skipped['action'], 'skipped');
      expect(skipped['id'], created['id']);
    },
  );

  test('toolDefaultAssistant lets the model pick scope', () async {
    final provider = MemoryProvider();
    const assistant = Assistant(
      id: 'a1',
      name: 'A',
      enableMemory: true,
      memoryWriteScope: MemoryWriteScope.toolDefaultAssistant,
    );

    await MemoryToolHandler.handle(
      'memory_update',
      {'type': 'workflow', 'content': 'ships Flutter apps', 'scope': 'global'},
      assistant,
      provider,
    );
    final entry = (await MemoryStore.getAll()).single;
    expect(entry.scope, MemoryScope.global);
    expect(entry.type, MemoryType.workflow);
  });

  test('legacy create/edit/delete aliases keep working', () async {
    final provider = MemoryProvider();
    const assistant = Assistant(id: 'a1', name: 'A', enableMemory: true);

    final created = _decode(
      await MemoryToolHandler.handle(
        'create_memory',
        {'content': 'old tool name'},
        assistant,
        provider,
      ),
    );
    expect(created['action'], 'created');
    final id = created['id'] as String;

    final edited = _decode(
      await MemoryToolHandler.handle(
        'edit_memory',
        {'id': id, 'content': 'updated content'},
        assistant,
        provider,
      ),
    );
    expect(edited['action'], 'edited');
    expect((await MemoryStore.getAll()).single.content, 'updated content');

    final deleted = _decode(
      await MemoryToolHandler.handle(
        'delete_memory',
        {'id': id},
        assistant,
        provider,
      ),
    );
    expect(deleted['action'], 'deleted');
    expect((await MemoryStore.getAll()).single.isArchived, isTrue);
  });

  test('failures are distinguishable structured tool_error payloads', () async {
    final provider = MemoryProvider();
    const assistant = Assistant(id: 'a1', name: 'A', enableMemory: true);

    final invalid = _decode(
      await MemoryToolHandler.handle(
        'memory_edit',
        {'content': 'no id'},
        assistant,
        provider,
      ),
    );
    expect(invalid['error'], 'tool_error');
    expect(invalid['code'], 'invalid_args');

    final missing = _decode(
      await MemoryToolHandler.handle(
        'memory_edit',
        {'id': 'mem_deadbeef', 'content': 'x'},
        assistant,
        provider,
      ),
    );
    expect(missing['error'], 'tool_error');
    expect(missing['code'], 'not_found');

    final empty = _decode(
      await MemoryToolHandler.handle(
        'memory_update',
        {'type': 'identity', 'content': '   '},
        assistant,
        provider,
      ),
    );
    expect(empty['code'], 'invalid_args');
    expect(await MemoryStore.getAll(), isEmpty);
  });

  test('rejects malformed pagination and unknown types', () async {
    final provider = MemoryProvider();
    const assistant = Assistant(id: 'a1', name: 'A', enableMemory: true);

    final badLimit = _decode(
      await MemoryToolHandler.handle(
        'memory_read',
        {'limit': 'two'},
        assistant,
        provider,
      ),
    );
    expect(badLimit['code'], 'invalid_args');

    final numericLimit = _decode(
      await MemoryToolHandler.handle(
        'memory_read',
        {'limit': '2'},
        assistant,
        provider,
      ),
    );
    expect(numericLimit['total'], 0);

    final badType = _decode(
      await MemoryToolHandler.handle(
        'memory_update',
        {'type': 'preference', 'content': 'x'},
        assistant,
        provider,
      ),
    );
    expect(badType['code'], 'invalid_args');

    final badFilter = _decode(
      await MemoryToolHandler.handle(
        'memory_read',
        {'type': 'preference'},
        assistant,
        provider,
      ),
    );
    expect(badFilter['code'], 'invalid_args');
    expect(await MemoryStore.getAll(), isEmpty);
  });

  test('memory_read paginates and filters by type', () async {
    final provider = MemoryProvider();
    const assistant = Assistant(id: 'a1', name: 'A', enableMemory: true);

    for (var i = 0; i < 3; i++) {
      await MemoryToolHandler.handle(
        'memory_update',
        {'type': i == 0 ? 'workflow' : 'identity', 'content': 'fact $i'},
        assistant,
        provider,
      );
    }
    final page = _decode(
      await MemoryToolHandler.handle(
        'memory_read',
        {'limit': 2, 'offset': 0},
        assistant,
        provider,
      ),
    );
    expect(page['total'], 3);
    expect(page['has_more'], isTrue);
    expect(page['next_offset'], 2);
    expect(page['items'], hasLength(2));

    final filtered = _decode(
      await MemoryToolHandler.handle(
        'memory_read',
        {'type': 'workflow'},
        assistant,
        provider,
      ),
    );
    expect(filtered['total'], 1);
    expect(filtered['items'], hasLength(1));
  });

  test('memory tools are unavailable when memory is disabled', () async {
    final provider = MemoryProvider();
    const assistant = Assistant(id: 'a1', name: 'A');
    expect(MemoryToolHandler.handles('memory_update', assistant), isFalse);
    final result = await MemoryToolHandler.handle(
      'memory_update',
      {'type': 'identity', 'content': 'x'},
      assistant,
      provider,
    );
    expect(result, isNull);
  });
}
