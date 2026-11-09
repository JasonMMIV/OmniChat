// Todo projection tests (docs/write_todos_improvement_plan.md §2.1.2 / §5).
//
// Pure rules over the active message branch: latest successful event wins,
// failed events never advance state, clear is an explicit empty state, and
// version selection is honored via collapseVersions-shaped input.

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/services/chat/storage/message_part_codec.dart';
import 'package:OmniChat/core/services/chat/todo_models.dart';
import 'package:OmniChat/core/services/chat/todo_projection.dart';

ChatMessage _assistant(
  String id, {
  String content = '',
  String? groupId,
  int version = 0,
}) =>
    ChatMessage(
      id: id,
      role: 'assistant',
      content: content,
      conversationId: 'conv1',
      timestamp: DateTime(2026, 1, 1),
      groupId: groupId,
      version: version,
    );

Map<String, dynamic> _todoEvent({
  required Object? todos,
  String? id,
  String? content,
  String? approvalState,
  String? name = todoToolName,
}) =>
    <String, dynamic>{
      'name': name,
      'id': id ?? '',
      'arguments': {'todos': todos},
      'content': content,
      if (approvalState != null) 'approvalState': approvalState,
    };

String _canonicalContent(List<TodoItem> items) => buildTodoResultContent(
      items: items,
      changed: true,
      cleared: false,
    );

void main() {
  test('no events → null (never inject)', () {
    final messages = [_assistant('a1')];
    final state = projectTodoState(
      activeMessages: messages,
      eventsByMessageId: const {'a1': []},
    );
    expect(state, isNull);
  });

  test('successful event projects items and source ids', () {
    final messages = [_assistant('a1')];
    final state = projectTodoState(
      activeMessages: messages,
      eventsByMessageId: {
        'a1': [
          _todoEvent(
            id: 'call_1',
            todos: [
              {'content': 'A', 'status': 'pending'},
              {'content': 'B', 'status': 'completed'},
            ],
            content: _canonicalContent(const [
              TodoItem(content: 'A', status: todoStatusPending),
              TodoItem(content: 'B', status: todoStatusCompleted),
            ]),
          ),
        ],
      },
    );
    expect(state, isNotNull);
    expect(state!.items.length, 2);
    expect(state.sourceMessageId, 'a1');
    expect(state.sourceToolCallId, 'call_1');
    expect(state.hasExplicitState, isTrue);
    expect(state.updatedAt, messages.first.timestamp);
  });

  test('compact snapshot result is rebuilt from arguments', () {
    final messages = [_assistant('a1')];
    final state = projectTodoState(
      activeMessages: messages,
      eventsByMessageId: {
        'a1': [
          _todoEvent(
            id: 'call_1',
            todos: [
              {'content': 'A', 'status': 'pending'},
            ],
            content: buildTodoResultContent(
              items: const [
                TodoItem(content: 'A', status: todoStatusPending),
              ],
              changed: false,
              cleared: false,
            ),
          ),
        ],
      },
    );
    expect(state, isNotNull);
    expect(state!.items.single.content, 'A');
  });

  test('legacy human-readable result falls back to arguments', () {
    final messages = [_assistant('a1')];
    final state = projectTodoState(
      activeMessages: messages,
      eventsByMessageId: {
        'a1': [
          _todoEvent(
            id: 'call_1',
            todos: [
              {'task': 'legacy', 'completed': false},
            ],
            content: 'Todo list updated: 1 items (0 in progress, 0 completed).',
          ),
        ],
      },
    );
    expect(state, isNotNull);
    expect(state!.items.single.content, 'legacy');
    expect(state.items.single.status, todoStatusPending);
  });

  test('tool_error result never advances state', () {
    final messages = [_assistant('a1')];
    final state = projectTodoState(
      activeMessages: messages,
      eventsByMessageId: {
        'a1': [
          _todoEvent(
            id: 'call_1',
            todos: [
              {'content': 'A', 'status': 'pending'},
            ],
            content:
                '{"type":"tool_error","error":"invalid_todos","tool":"write_todos"}',
          ),
        ],
      },
    );
    expect(state, isNull);
  });

  test('failed write after a success keeps the earlier state', () {
    final messages = [_assistant('a1')];
    final state = projectTodoState(
      activeMessages: messages,
      eventsByMessageId: {
        'a1': [
          _todoEvent(
            id: 'call_1',
            todos: [
              {'content': 'A', 'status': 'pending'},
            ],
            content: _canonicalContent(const [
              TodoItem(content: 'A', status: todoStatusPending),
            ]),
          ),
          _todoEvent(
            id: 'call_2',
            todos: null,
            content:
                '{"type":"tool_error","error":"invalid_todos","tool":"write_todos"}',
          ),
        ],
      },
    );
    expect(state, isNotNull);
    expect(state!.items.single.content, 'A');
  });

  test('interrupted / pending events are skipped (success only)', () {
    final messages = [_assistant('a1')];
    final state = projectTodoState(
      activeMessages: messages,
      eventsByMessageId: {
        'a1': [
          _todoEvent(
            id: 'call_1',
            todos: [
              {'content': 'A', 'status': 'pending'},
            ],
            content: null,
            approvalState: kApprovalPending,
          ),
        ],
      },
    );
    expect(state, isNull);
  });

  test('todos: [] with success projects an explicit cleared state', () {
    final messages = [_assistant('a1')];
    final state = projectTodoState(
      activeMessages: messages,
      eventsByMessageId: {
        'a1': [
          _todoEvent(
            id: 'call_clear',
            todos: <Object>[],
            content: buildTodoResultContent(
              items: const <TodoItem>[],
              changed: true,
              cleared: true,
              includeItems: true,
            ),
          ),
        ],
      },
    );
    expect(state, isNotNull);
    expect(state!.isCleared, isTrue);
    expect(state.items, isEmpty);
    expect(state.hasExplicitState, isTrue);
  });

  test('later events override earlier ones; same message last wins', () {
    final messages = [_assistant('a1'), _assistant('a2')];
    final state = projectTodoState(
      activeMessages: messages,
      eventsByMessageId: {
        'a1': [
          _todoEvent(
            id: 'call_1',
            todos: [
              {'content': 'old', 'status': 'pending'},
            ],
            content: _canonicalContent(const [
              TodoItem(content: 'old', status: todoStatusPending),
            ]),
          ),
        ],
        'a2': [
          _todoEvent(
            id: 'call_2',
            todos: [
              {'content': 'first', 'status': 'pending'},
            ],
            content: _canonicalContent(const [
              TodoItem(content: 'first', status: todoStatusPending),
            ]),
          ),
          _todoEvent(
            id: 'call_3',
            todos: [
              {'content': 'second', 'status': 'in_progress'},
            ],
            content: _canonicalContent(const [
              TodoItem(content: 'second', status: todoStatusInProgress),
            ]),
          ),
        ],
      },
    );
    expect(state, isNotNull);
    expect(state!.sourceMessageId, 'a2');
    expect(state.sourceToolCallId, 'call_3');
    expect(state.items.single.content, 'second');
  });

  test('non-write_todos events are ignored', () {
    final messages = [_assistant('a1')];
    final state = projectTodoState(
      activeMessages: messages,
      eventsByMessageId: {
        'a1': [
          _todoEvent(
            name: 'file_write',
            id: 'call_x',
            todos: [
              {'content': 'A', 'status': 'pending'},
            ],
            content: '{"type":"tool_error","error":"whatever"}',
          ),
        ],
      },
    );
    expect(state, isNull);
  });

  test('only the selected version branch is projected', () {
    // Group a1 has two versions, each carrying a different plan; the caller
    // collapses with versionSelections before projecting (§2.1.2).
    final v0 = _assistant('a1-v0', groupId: 'g1', version: 0);
    final v1 = _assistant('a1-v1', groupId: 'g1', version: 1);
    TodoState? project(List<ChatMessage> active) => projectTodoState(
          activeMessages: active,
          eventsByMessageId: {
            'a1-v0': [
              _todoEvent(
                id: 'call_v0',
                todos: [
                  {'content': 'plan v0', 'status': 'pending'},
                ],
                content: _canonicalContent(const [
                  TodoItem(content: 'plan v0', status: todoStatusPending),
                ]),
              ),
            ],
            'a1-v1': [
              _todoEvent(
                id: 'call_v1',
                todos: [
                  {'content': 'plan v1', 'status': 'pending'},
                ],
                content: _canonicalContent(const [
                  TodoItem(content: 'plan v1', status: todoStatusPending),
                ]),
              ),
            ],
          },
        );

    // Selected version 0 → v0's plan; the default (last) → v1's plan.
    expect(project([v0, v1])!.items.single.content, 'plan v1');
  });
}
