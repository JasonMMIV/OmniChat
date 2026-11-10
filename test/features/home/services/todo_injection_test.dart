// write_todos injection gating + synthetic trailing state pair tests
// (docs/write_todos_improvement_plan.md §2.3 / §5).
//
// Covers:
// - `hasWriteTodosEnabled` shares the tool-registration conditions
//   (supportsTools × planning switch × per-tool toggle), plus the projection
//   kill switch (`todoEventProjectionV1`) default. The workspace is NOT part
//   of the gate (Phase 3-4).
// - `appendTodoStatePair` shape: real toolCallId preference, hash fallback
//   on collision, no duplicated pair, cleared state, and system-message
//   byte-stability (todo updates never touch the cache prefix).

import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/chat/todo_models.dart';
import 'package:OmniChat/core/services/chat/tool_replay.dart';
import 'package:OmniChat/features/home/services/message_builder_service.dart';
import 'package:OmniChat/features/home/services/tool_handler_service.dart';

Future<SettingsProvider> _loadedProvider() async {
  final sp = SettingsProvider();
  final done = Completer<void>();
  void listener() {
    if (!done.isCompleted) done.complete();
  }

  sp.addListener(listener);
  await done.future.timeout(const Duration(seconds: 10));
  sp.removeListener(listener);
  return sp;
}

Map<String, dynamic> _decoded(Object? jsonText) =>
    jsonDecode(jsonText as String) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('hasWriteTodosEnabled (gating predicate, §2.3.1)', () {
    test('model without tools → never', () async {
      final settings = await _loadedProvider();
      expect(
        ToolHandlerService.hasWriteTodosEnabled(settings, supportsTools: false),
        isFalse,
      );
    });

    test('workspace is irrelevant → planning stays on', () async {
      final settings = await _loadedProvider();
      expect(settings.planningEnabled, isTrue);
      expect(
        ToolHandlerService.hasWriteTodosEnabled(settings, supportsTools: true),
        isTrue,
      );
    });

    test('planning switch off → never; legacy per-tool off → never', () async {
      final settings = await _loadedProvider();
      await settings.setPlanningEnabled(false);
      expect(
        ToolHandlerService.hasWriteTodosEnabled(settings, supportsTools: true),
        isFalse,
      );
      await settings.setPlanningEnabled(true);
      await settings.setWorkspaceToolEnabled(todoToolName, false);
      expect(
        ToolHandlerService.hasWriteTodosEnabled(settings, supportsTools: true),
        isFalse,
      );
    });

    test('projection kill switch defaults to true', () async {
      final settings = await _loadedProvider();
      expect(settings.todoEventProjectionV1, isTrue);
      await settings.setTodoEventProjectionV1(false);
      expect(settings.todoEventProjectionV1, isFalse);
    });
  });

  group('appendTodoStatePair (§2.3.2)', () {
    final items = const [
      TodoItem(content: 'A', status: todoStatusCompleted),
      TodoItem(content: 'B', status: todoStatusInProgress),
    ];

    test('appends a well-formed trailing call/result pair', () {
      final api = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': 'hi'},
      ];
      appendTodoStatePair(
        api,
        TodoState(
          items: items,
          hasExplicitState: true,
          sourceToolCallId: 'call_real',
        ),
      );
      expect(api.length, 4);
      final call = api[2];
      final result = api[3];
      expect(call['role'], 'assistant');
      final calls = call['tool_calls'] as List;
      expect((calls.single as Map)['id'], 'call_real');
      expect(((calls.single as Map)['function'] as Map)['name'], todoToolName);
      expect(result['role'], 'tool');
      expect(result['tool_call_id'], 'call_real');
      final decoded = _decoded(result['content']);
      expect(decoded['items'], isNotEmpty);
      expect(decoded['notice'], isNotNull);
      expect(decoded['notice'], contains('Resume from the first unfinished'));
      expect(decoded['notice'], contains('rewrite ALL todos'));
    });

    test('system message bytes are untouched (cache prefix stability)', () {
      const system = 'YOU ARE A HELPFUL ASSISTANT';
      final api = <Map<String, dynamic>>[
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': 'hi'},
      ];
      appendTodoStatePair(api, TodoState(items: items, hasExplicitState: true));
      expect(api[0]['content'] as String, system);
    });

    test('empty + non-explicit state never appends', () {
      final api = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hi'},
      ];
      appendTodoStatePair(
        api,
        const TodoState(items: [], hasExplicitState: false),
      );
      expect(api.length, 1);
    });

    test('explicit clear appends an empty todos pair', () {
      final api = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hi'},
      ];
      appendTodoStatePair(
        api,
        const TodoState(items: [], hasExplicitState: true),
      );
      expect(api.length, 3);
      final calls =
          ((api[1]['tool_calls'] as List).single as Map)['function'] as Map;
      expect(_decoded(calls['arguments'])['todos'], isEmpty);
      final decoded = _decoded(api[2]['content']);
      expect(decoded['cleared'], isTrue);
      expect(decoded['items'], isEmpty);
      expect(decoded['notice'], contains('cleared'));
    });

    test('all-complete state tells the model no further update is needed', () {
      final api = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hi'},
      ];
      appendTodoStatePair(
        api,
        TodoState(
          items: const [
            TodoItem(content: 'A', status: todoStatusCompleted),
            TodoItem(content: 'B', status: todoStatusCompleted),
          ],
          hasExplicitState: true,
        ),
      );
      final decoded = _decoded(api[2]['content']);
      expect(decoded['notice'], contains('all items are completed'));
      expect(decoded['notice'], contains('No further write_todos update'));
    });

    test('colliding real id falls back to a stable hash id', () {
      final api = <Map<String, dynamic>>[
        {
          'role': 'assistant',
          'content': '\n\n',
          'tool_calls': [
            {
              'id': 'call_real',
              'type': 'function',
              'function': {'name': 'file_read', 'arguments': '{}'},
            },
          ],
        },
        {
          'role': 'tool',
          'name': 'file_read',
          'tool_call_id': 'call_real',
          'content': 'x',
        },
      ];
      appendTodoStatePair(
        api,
        TodoState(
          items: items,
          hasExplicitState: true,
          sourceToolCallId: 'call_real',
        ),
      );
      expect(api.length, 4);
      final newCall = (api[2]['tool_calls'] as List).single as Map;
      expect(newCall['id'], isNot('call_real'));
      expect(newCall['id'], startsWith('todo_state_'));
    });

    test('missing real id uses the deterministic hash fallback', () {
      final api = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hi'},
      ];
      appendTodoStatePair(api, TodoState(items: items, hasExplicitState: true));
      final call = (api[1]['tool_calls'] as List).single as Map;
      final first = call['id'];
      expect(first, startsWith('todo_state_'));

      // Retry with the same state → the same id (no timestamp churn).
      final api2 = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hi'},
      ];
      appendTodoStatePair(
        api2,
        TodoState(items: items, hasExplicitState: true),
      );
      expect(((api2[1]['tool_calls'] as List).single as Map)['id'], first);
    });

    test('re-assembly does not duplicate the trailing pair', () {
      final api = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hi'},
      ];
      final state = TodoState(items: items, hasExplicitState: true);
      appendTodoStatePair(api, state);
      final lengthAfterFirst = api.length;
      appendTodoStatePair(api, state);
      expect(api.length, lengthAfterFirst);
    });

    test('pair shape matches the existing replay pair contract '
        '(provider parity, §2.3.2)', () {
      // The synthetic pair must be indistinguishable from a historical
      // replay pair built by buildToolReplayPairs + neutralMessagesFor: the
      // Claude/Gemini/OpenAI converters key off exactly this shape, so a
      // match here is the transport-parity guarantee.
      final replayPairs = buildToolReplayPairs([
        {
          'id': 'call_hist',
          'name': 'file_read',
          'arguments': {'path': 'a.txt'},
          'content': '{"ok":true}',
        },
      ], messageId: 'm1');
      expect(replayPairs, hasLength(1));
      final replay = replayPairs.single;
      final replayApi = <Map<String, dynamic>>[
        {
          'role': 'assistant',
          'content': '\n\n',
          'tool_calls': [
            {
              'id': replay.toolCallId,
              'type': 'function',
              'function': {
                'name': replay.toolName,
                'arguments': jsonEncode(replay.event['arguments']),
              },
            },
          ],
        },
        {
          'role': 'tool',
          'name': replay.toolName,
          'tool_call_id': replay.toolCallId,
          'content': replay.content,
        },
      ];

      final todoApi = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hi'},
      ];
      appendTodoStatePair(
        todoApi,
        TodoState(items: items, hasExplicitState: true),
      );
      final todoCall = todoApi[1];
      final todoTool = todoApi[2];

      // Assistant call message: identical key set + value types.
      expect(todoCall.keys.toSet(), replayApi[0].keys.toSet());
      expect(todoCall['content'], replayApi[0]['content']);
      final replayCall = (replayApi[0]['tool_calls'] as List).single as Map;
      final todoCallEntry = (todoCall['tool_calls'] as List).single as Map;
      expect(todoCallEntry.keys.toSet(), replayCall.keys.toSet());
      expect(todoCallEntry['type'], replayCall['type']);
      final replayFn = replayCall['function'] as Map;
      final todoFn = todoCallEntry['function'] as Map;
      expect(todoFn.keys.toSet(), replayFn.keys.toSet());
      expect(todoFn['arguments'], isA<String>());
      expect(() => jsonDecode(todoFn['arguments'] as String), returnsNormally);

      // Tool result message: identical key set + value types.
      expect(todoTool.keys.toSet(), replayApi[1].keys.toSet());
      expect(todoTool['role'], 'tool');
      expect(todoTool['tool_call_id'], todoCallEntry['id']);
      expect(todoTool['name'], todoToolName);
      expect(() => jsonDecode(todoTool['content'] as String), returnsNormally);
    });
  });
}
