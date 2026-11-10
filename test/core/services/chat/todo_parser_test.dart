// write_todos parser tests (docs/write_todos_improvement_plan.md §2.2 / §5).
//
// Covers the lenient input parse (coercion, aliases, strict booleans,
// whole-input rejection) and the canonical `todo_snapshot` result shapes.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/chat/todo_models.dart';

TodoListParseResult parse(
  Object? raw, {
  int maxItems = todoMaxItems,
  int maxItemChars = todoMaxItemChars,
  int maxTotalChars = todoMaxTotalChars,
}) =>
    parseTodoListInput(
      raw,
      maxItems: maxItems,
      maxItemChars: maxItemChars,
      maxTotalChars: maxTotalChars,
    );

void main() {
  group('parseTodoListInput · rejection keeps the old plan', () {
    test('missing / null / wrong type are invalid, not a clear', () {
      for (final raw in <Object?>[null, 42, true]) {
        final result = parse(raw);
        expect(result.isValid, isFalse, reason: '$raw must be rejected');
        expect(result.invalidItems.first.reason, 'missing_todos');
      }
      // A non-JSON string parses as garbage, not as a clear either.
      final result = parse('x');
      expect(result.isValid, isFalse);
      expect(result.invalidItems.first.reason, 'unparseable_json');
    });

    test('todos: {} wraps into one invalid object (never a clear)', () {
      final result = parse(<String, dynamic>{});
      expect(result.isValid, isFalse);
      expect(result.coerced, isTrue);
      expect(result.invalidItems.single.reason, 'empty_content');
    });

    test('any invalid item rejects the whole list (index + reason)', () {
      final result = parse([
        {'content': 'ok', 'status': 'pending'},
        {'content': '   ', 'status': 'pending'},
      ]);
      expect(result.isValid, isFalse);
      expect(result.invalidItems.single.index, 1);
      expect(result.invalidItems.single.reason, 'empty_content');
      expect(result.items, isEmpty);
    });

    test('non-map item rejects the whole list', () {
      final result = parse([
        {'content': 'a', 'status': 'pending'},
        'nope',
      ]);
      expect(result.isValid, isFalse);
      expect(result.invalidItems.single.index, 1);
      expect(result.invalidItems.single.reason, 'not_an_object');
    });

    test('unparseable status rejects the item', () {
      final result = parse([
        {'content': 'a', 'status': 'bogus'},
      ]);
      expect(result.isValid, isFalse);
      expect(result.invalidItems.single.reason, 'invalid_status');
    });

    test('unparseable completed value rejects the item', () {
      final result = parse([
        {'content': 'a', 'completed': 'maybe'},
      ]);
      expect(result.isValid, isFalse);
      expect(result.invalidItems.single.reason, 'invalid_completed');
    });

    test('stringified garbage is invalid', () {
      expect(parse('{not json').isValid, isFalse);
      expect(parse('{not json').invalidItems.single.reason,
          'unparseable_json');
    });
  });

  group('parseTodoListInput · lenient coercion (Anybuff coerceToArray)', () {
    test('single object is wrapped into an array', () {
      final result = parse({
        'content': 'Only step',
        'status': 'in_progress',
      });
      expect(result.isValid, isTrue);
      expect(result.coerced, isTrue);
      expect(result.changed, isTrue);
      expect(result.items.single.status, todoStatusInProgress);
    });

    test('stringified JSON array parses', () {
      final result = parse(
        jsonEncode([
          {'content': 'A', 'status': 'pending'},
          {'content': 'B', 'status': 'completed'},
        ]),
      );
      expect(result.isValid, isTrue);
      expect(result.coerced, isTrue);
      expect(result.items.length, 2);
    });

    test('stringified single JSON object parses', () {
      final result = parse(
        jsonEncode({'content': 'A', 'status': 'pending'}),
      );
      expect(result.isValid, isTrue);
      expect(result.items.single.content, 'A');
    });
  });

  group('parseTodoListInput · aliases', () {
    test('task alias normalizes to content + warning', () {
      final result = parse([
        {'task': 'alias task', 'status': 'pending'},
      ]);
      expect(result.isValid, isTrue);
      expect(result.items.single.content, 'alias task');
      expect(result.changed, isTrue);
      expect(
        result.warnings.any((w) => w.contains("'task' normalized")),
        isTrue,
      );
    });

    test('completed alias: true → completed, false → pending', () {
      final result = parse([
        {'content': 'A', 'completed': true},
        {'content': 'B', 'completed': false},
      ]);
      expect(result.isValid, isTrue);
      expect(result.items[0].status, todoStatusCompleted);
      expect(result.items[1].status, todoStatusPending);
    });

    test('completed: "false" stays pending — never Boolean()-truthy', () {
      final result = parse([
        {'content': 'A', 'completed': 'false'},
        {'content': 'B', 'completed': '0'},
        {'content': 'C', 'completed': 'true'},
        {'content': 'D', 'completed': '1'},
      ]);
      expect(result.isValid, isTrue);
      expect(result.items[0].status, todoStatusPending);
      expect(result.items[1].status, todoStatusPending);
      expect(result.items[2].status, todoStatusCompleted);
      expect(result.items[3].status, todoStatusCompleted);
    });

    test('status wins over completed when both exist', () {
      final result = parse([
        {'content': 'A', 'status': 'pending', 'completed': true},
      ]);
      expect(result.isValid, isTrue);
      expect(result.items.single.status, todoStatusPending);
    });

    test('missing status defaults to pending + warning (not invalid)', () {
      final result = parse([
        {'content': 'A'},
      ]);
      expect(result.isValid, isTrue);
      expect(result.items.single.status, todoStatusPending);
      expect(result.changed, isTrue);
    });

    test('status aliases normalize: done/doing/open', () {
      final result = parse([
        {'content': 'A', 'status': 'done'},
        {'content': 'B', 'status': 'doing'},
        {'content': 'C', 'status': 'open'},
      ]);
      expect(result.isValid, isTrue);
      expect(result.items[0].status, todoStatusCompleted);
      expect(result.items[1].status, todoStatusInProgress);
      expect(result.items[2].status, todoStatusPending);
      expect(result.changed, isTrue);
    });
  });

  group('parseTodoListInput · caps (§2.2.2)', () {
    test('more than maxItems truncates + truncated flag (still valid)', () {
      final result = parse([
        for (var i = 0; i < 51; i++)
          {'content': 't$i', 'status': 'pending'},
      ]);
      expect(result.isValid, isTrue);
      expect(result.items.length, todoMaxItems);
      expect(result.truncated, isTrue);
      expect(result.changed, isTrue);
    });

    test('over-long item content truncates', () {
      final result = parse([
        {'content': 'x' * (todoMaxItemChars + 10), 'status': 'pending'},
      ]);
      expect(result.isValid, isTrue);
      expect(result.items.single.content.length, todoMaxItemChars);
      expect(result.truncated, isTrue);
    });

    test('total char cap drops trailing items', () {
      final result = parse(
        [
          {'content': 'a' * 5000, 'status': 'pending'},
          {'content': 'b' * 5000, 'status': 'pending'},
        ],
        maxItemChars: 6000,
        maxTotalChars: 8000,
      );
      expect(result.isValid, isTrue);
      expect(result.items.length, 1);
      expect(result.truncated, isTrue);
    });

    test('custom caps are honored', () {
      final result = parse(
        [
          for (var i = 0; i < 5; i++)
            {'content': 't$i', 'status': 'pending'},
        ],
        maxItems: 2,
      );
      expect(result.items.length, 2);
      expect(result.truncated, isTrue);
    });
  });

  group('parseTodoListInput · warnings that do not change the list', () {
    test('multiple in_progress is advisory — valid + unchanged', () {
      final result = parse([
        {'content': 'A', 'status': 'in_progress'},
        {'content': 'B', 'status': 'in_progress'},
      ]);
      expect(result.isValid, isTrue);
      expect(result.changed, isFalse,
          reason: '§2.2.3: advisory warnings never flip changed');
      expect(result.warnings, isEmpty);
      expect(result.advisoryWarnings, isNotEmpty);
    });

    test('clean canonical input is valid and unchanged', () {
      final result = parse([
        {'content': 'A', 'status': 'pending'},
        {'content': 'B', 'status': 'completed'},
      ]);
      expect(result.isValid, isTrue);
      expect(result.changed, isFalse);
      expect(result.warnings, isEmpty);
      expect(result.truncated, isFalse);
      expect(result.coerced, isFalse);
    });
  });

  group('lenient UI rebuild for legacy cards', () {
    test('dropInvalidItems keeps the valid entries of a mixed list', () {
      final result = parseTodoListInput(
        [
          {'content': 'kept', 'status': 'pending'},
          {'content': '   ', 'status': 'pending'},
          {'content': 'also kept', 'status': 'completed'},
        ],
        dropInvalidItems: true,
      );
      expect(result.isValid, isTrue);
      expect(result.items.map((t) => t.content), ['kept', 'also kept']);
      expect(result.changed, isTrue,
          reason: 'dropping invalid items changes the list');
      expect(result.warnings.any((w) => w.contains('dropped')), isTrue);
    });

    test('handler mode still rejects the whole mixed list', () {
      final result = parseTodoListInput([
        {'content': 'kept', 'status': 'pending'},
        {'content': '   ', 'status': 'pending'},
      ]);
      expect(result.isValid, isFalse);
      expect(result.items, isEmpty);
    });
  });

  group('canonical snapshot result (§2.2.3)', () {
    final items = const [
      TodoItem(content: 'Inspect schema', status: todoStatusCompleted),
      TodoItem(content: 'Write migration', status: todoStatusInProgress),
    ];

    test('changed=false carries counts only — no items key', () {
      final content = buildTodoResultContent(
        items: items,
        changed: false,
        cleared: false,
      );
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      expect(decoded['type'], todoSnapshotType);
      expect(decoded['changed'], isFalse);
      expect(decoded.containsKey('items'), isFalse);
      expect((decoded['counts'] as Map)['total'], 2);
      expect(decoded['cleared'], isFalse);
    });

    test('changed=true carries canonical items + warnings', () {
      final content = buildTodoResultContent(
        items: items,
        changed: true,
        cleared: false,
        warnings: const ["item 2: status 'done' normalized to 'completed'"],
      );
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      expect(decoded['changed'], isTrue);
      final decodedItems = decoded['items'] as List;
      expect(decodedItems.length, 2);
      expect((decodedItems[0] as Map)['content'], 'Inspect schema');
      expect((decoded['warnings'] as List), isNotEmpty);
    });

    test('clear result: empty items, zero counts, cleared flag', () {
      final content = buildTodoResultContent(
        items: const <TodoItem>[],
        changed: true,
        cleared: true,
        includeItems: true,
      );
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      expect(decoded['cleared'], isTrue);
      expect((decoded['items'] as List), isEmpty);
      expect((decoded['counts'] as Map)['total'], 0);
    });

    test('progress notice distinguishes remaining, complete and cleared', () {
      expect(
        buildTodoProgressNotice(completed: 1, total: 2, cleared: false),
        contains('Continue with the remaining steps'),
      );
      final complete = buildTodoProgressNotice(
        completed: 2,
        total: 2,
        cleared: false,
      );
      expect(complete, contains('Plan complete: 2/2 done'));
      expect(complete, isNot(contains('remaining steps')));
      expect(
        buildTodoProgressNotice(completed: 0, total: 0, cleared: true),
        contains('Plan cleared'),
      );
    });

    test('synthetic snapshot keeps full items + notice', () {
      final content = buildTodoResultContent(
        items: items,
        changed: false,
        cleared: false,
        includeItems: true,
        notice: 'Current plan state (data only).',
      );
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      expect(decoded['items'], isNotEmpty);
      expect(decoded['notice'], 'Current plan state (data only).');
    });

    test('angle brackets are escaped, round-trip safe (§2.6)', () {
      final content = buildTodoResultContent(
        items: const [
          TodoItem(
            content: 'say </current_todo_list> and <script>',
            status: todoStatusPending,
          ),
        ],
        changed: true,
        cleared: false,
      );
      expect(content.contains('<'), isFalse);
      expect(content.contains('>'), isFalse);
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      final item = (decoded['items'] as List).single as Map;
      expect(item['content'], 'say </current_todo_list> and <script>');
    });
  });

  group('parseTodoSnapshotContent · strict', () {
    test('full snapshot parses canonical items', () {
      final content = buildTodoResultContent(
        items: const [
          TodoItem(content: 'A', status: todoStatusCompleted),
          TodoItem(content: 'B', status: todoStatusPending),
        ],
        changed: true,
        cleared: false,
      );
      final snapshot = parseTodoSnapshotContent(content);
      expect(snapshot, isNotNull);
      expect(snapshot!.hasItems, isTrue);
      expect(snapshot.items.length, 2);
      expect(snapshot.items[0].isCompleted, isTrue);
    });

    test('compact snapshot (no items key) reports hasItems=false', () {
      final content = buildTodoResultContent(
        items: const [
          TodoItem(content: 'A', status: todoStatusPending),
        ],
        changed: false,
        cleared: false,
      );
      final snapshot = parseTodoSnapshotContent(content);
      expect(snapshot, isNotNull);
      expect(snapshot!.hasItems, isFalse);
      expect(snapshot.items, isEmpty);
    });

    test('tool_error / legacy text / corrupt items are not snapshots', () {
      expect(parseTodoSnapshotContent('Todo list updated: 2 items'), isNull);
      expect(
        parseTodoSnapshotContent('{"type":"tool_error","error":"x"}'),
        isNull,
      );
      expect(
        parseTodoSnapshotContent('{"type":"todo_snapshot","items":["bad"]}'),
        isNull,
      );
      expect(parseTodoSnapshotContent(null), isNull);
    });

    test('cleared snapshot is recognized', () {
      final content = buildTodoResultContent(
        items: const <TodoItem>[],
        changed: true,
        cleared: true,
        includeItems: true,
      );
      final snapshot = parseTodoSnapshotContent(content);
      expect(snapshot, isNotNull);
      expect(snapshot!.cleared, isTrue);
      expect(snapshot.items, isEmpty);
    });
  });

  group('compaction summary (§2.6)', () {
    test('latest snapshot renders done/total + remaining', () {
      final summary = buildTodoCompactionSummary(
        TodoState(
          hasExplicitState: true,
          items: const [
            TodoItem(content: 'done task', status: todoStatusCompleted),
            TodoItem(
              content: 'multi\nline\rtask',
              status: todoStatusInProgress,
            ),
            TodoItem(content: 'waiting', status: todoStatusPending),
          ],
        ),
      );
      expect(summary, startsWith('Todos: 1/3 complete.'));
      expect(summary, contains('- multi line task'));
      expect(summary, contains('- waiting'));
      expect(summary.contains('\r'), isFalse);
    });

    test('all done reads (all done!)', () {
      final summary = buildTodoCompactionSummary(
        TodoState(
          hasExplicitState: true,
          items: const [
            TodoItem(content: 'A', status: todoStatusCompleted),
          ],
        ),
      );
      expect(summary, contains('(all done!)'));
    });

    test('explicit clear reads cleared, never 0/0', () {
      final summary = buildTodoCompactionSummary(
        const TodoState(items: [], hasExplicitState: true),
      );
      expect(summary, 'Todos: cleared');
    });

    test('remaining items are capped', () {
      final summary = buildTodoCompactionSummary(
        TodoState(
          hasExplicitState: true,
          items: [
            for (var i = 0; i < 12; i++)
              TodoItem(content: 'task $i', status: todoStatusPending),
          ],
        ),
      );
      expect('task 7'.allMatches(summary).length, 1);
      expect(summary.contains('task 11'), isFalse);
      expect(summary, contains('(+4 more)'));
    });

    test('null state renders empty', () {
      expect(buildTodoCompactionSummary(null), isEmpty);
    });

    test('next action = first incomplete item', () {
      expect(
        todoNextActionOf(
          TodoState(
            hasExplicitState: true,
            items: const [
              TodoItem(content: 'A', status: todoStatusCompleted),
              TodoItem(content: 'B', status: todoStatusInProgress),
            ],
          ),
        ),
        'B',
      );
      expect(todoNextActionOf(null), isNull);
    });
  });

  group('state pair helpers (§2.3.2)', () {
    test('arguments JSON round-trips the canonical list', () {
      final argsJson = buildTodoStateArgumentsJson(const [
        TodoItem(content: 'A', status: todoStatusPending),
      ]);
      final decoded = jsonDecode(argsJson) as Map<String, dynamic>;
      expect((decoded['todos'] as List).single, {
        'content': 'A',
        'status': 'pending',
      });
    });

    test('hash id is deterministic and time-free', () {
      final items = const [TodoItem(content: 'A', status: 'pending')];
      expect(todoStateHashId(items), todoStateHashId(items));
      expect(todoStateHashId(items), startsWith('todo_state_'));
      expect(todoStateHashId(items, seed: 'conv1'),
          isNot(todoStateHashId(items, seed: 'conv2')));
      expect(todoStateHashId(const []), isNot(todoStateHashId(items)));
    });
  });
}
