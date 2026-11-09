// Compaction todo summary tests (docs/write_todos_improvement_plan.md
// §1.8.5 / §2.6 / §5): the knowledge block gains a `Todos:` line built from
// the LATEST successful snapshot, gated on the planning tool.

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/compaction/history_compactor.dart';
import 'package:OmniChat/core/services/chat/todo_models.dart';

void main() {
  List<Map<String, dynamic>> messages() => [
        {'role': 'user', 'content': 'Fix the parser bugs in foo.dart'},
      ];

  test('todo summary line is pinned into the knowledge block', () {
    final summary = buildTodoCompactionSummary(
      TodoState(
        hasExplicitState: true,
        items: const [
          TodoItem(content: 'Repro the bug', status: todoStatusCompleted),
          TodoItem(content: 'Patch parser', status: todoStatusInProgress),
        ],
      ),
    );
    final block = buildKnowledgeBlock(
      messages(),
      nextActionOverride: 'Patch parser',
      todoSummaryOverride: summary,
    );
    expect(block, contains('Todos: 1/2 complete.'));
    expect(block, contains('- Patch parser'));
    expect(block, contains('Next Action: Patch parser'));
    // Todos section sits before Next Action.
    expect(
      block.indexOf('Todos:') < block.indexOf('Next Action:'),
      isTrue,
    );
  });

  test('the LATEST snapshot wins — not the first one', () {
    // The compactor receives one summary built by the caller from the
    // projection; the projection contract (latest event wins) is covered in
    // todo_projection_test. Here we pin that the override text is used
    // verbatim, so a stale first-snapshot summary cannot leak in.
    final latest = buildTodoCompactionSummary(
      TodoState(
        hasExplicitState: true,
        items: const [
          TodoItem(content: 'stale task', status: todoStatusCompleted),
          TodoItem(content: 'fresh task', status: todoStatusPending),
        ],
      ),
    );
    final block = buildKnowledgeBlock(
      messages(),
      nextActionOverride: 'fresh task',
      todoSummaryOverride: latest,
    );
    expect(block, contains('1/2 complete.'));
    expect(block, contains('fresh task'));
    expect(
      block.contains('stale task'),
      isFalse,
      reason: 'completed items are not listed, only remaining ones',
    );
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
    final block = buildKnowledgeBlock(
      messages(),
      todoSummaryOverride: summary,
    );
    expect(block, contains('(all done!)'));
  });

  test('explicit clear reads `Todos: cleared`', () {
    final summary = buildTodoCompactionSummary(
      const TodoState(items: [], hasExplicitState: true),
    );
    final block = buildKnowledgeBlock(
      messages(),
      todoSummaryOverride: summary,
    );
    expect(block, contains('Todos: cleared'));
    expect(block.contains('0/0'), isFalse);
  });

  test('no plan / ungated → no Todos line at all', () {
    final block = buildKnowledgeBlock(messages());
    expect(block.contains('Todos:'), isFalse);

    final block2 = buildKnowledgeBlock(
      messages(),
      todoSummaryOverride: buildTodoCompactionSummary(null),
    );
    expect(block2.contains('Todos:'), isFalse);
  });

  test('long summaries are capped by the summary builder', () {
    final summary = buildTodoCompactionSummary(
      TodoState(
        hasExplicitState: true,
        items: [
          for (var i = 0; i < 30; i++)
            TodoItem(content: 'task $i ' * 10, status: todoStatusPending),
        ],
      ),
    );
    expect(summary.length, lessThanOrEqualTo(401)); // 400 + ellipsis
    final block = buildKnowledgeBlock(
      messages(),
      todoSummaryOverride: summary,
    );
    expect(block, contains('Todos: 0/30 complete.'));
  });

  test('compactHistoryMessages passes the summary through', () {
    final messagesOut = <Map<String, dynamic>>[
      {'role': 'user', 'content': 'Goal: fix bugs'},
      {
        'role': 'assistant',
        'content': 'Inspecting files',
        'tool_calls': [
          {
            'id': 'call_1',
            'type': 'function',
            'function': {
              'name': 'file_read',
              'arguments': '{"path":"foo.dart"}',
            },
          },
        ],
      },
      {
        'role': 'tool',
        'name': 'file_read',
        'tool_call_id': 'call_1',
        'content': 'file body',
      },
    ];
    final summary = compactHistoryMessages(
      messagesOut,
      nextActionOverride: 'Patch parser',
      todoSummaryOverride: 'Todos: 1/2 complete. Remaining:\n- Patch parser',
    );
    expect(summary, isNotNull);
    final text = summary!['content'] as String;
    expect(text, contains('Todos: 1/2 complete.'));
    expect(text, contains('Next Action: Patch parser'));
  });
}
