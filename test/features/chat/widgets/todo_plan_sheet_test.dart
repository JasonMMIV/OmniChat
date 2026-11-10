// Phase 3 plan UI tests (docs/write_todos_improvement_plan.md §2.4.3/§2.4.5).
//
// - TodoPlanSheet: empty state, items/progress, user clear confirmation and
//   the cleared state after the event is appended.
// - TodoPlanLiveDock: conversation-backed visibility — visible while the
//   active branch's latest successful plan has an incomplete item (running
//   or idle), hidden when complete/cleared/failed-without-fallback, with
//   version-selection and tool-revision rebuild contracts.
// - todoStateFromToolParts: success-only projection over in-memory parts.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/services/chat/todo_models.dart';
import 'package:OmniChat/features/chat/widgets/chat_message_widget.dart'
    show ToolUIPart;
import 'package:OmniChat/features/chat/widgets/todo_plan_sheet.dart';
import 'package:OmniChat/features/home/controllers/streaming_content_notifier.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
import 'package:OmniChat/shared/widgets/snackbar.dart';

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

TodoState _state({
  List<TodoItem> items = const [
    TodoItem(content: 'Draft the plan', status: todoStatusCompleted),
    TodoItem(content: 'Implement the feature', status: todoStatusInProgress),
    TodoItem(content: 'Validate the build', status: todoStatusPending),
  ],
  bool updated = true,
}) => TodoState(
  items: items,
  hasExplicitState: true,
  updatedAt: updated ? DateTime(2026, 11, 10, 14, 30) : null,
);

ToolUIPart _todoPart({
  required Object? todos,
  String? content,
  String? status,
  String id = 'call_1',
}) => ToolUIPart(
  id: id,
  toolName: todoToolName,
  arguments: <String, dynamic>{'todos': todos},
  content: content,
  loading: false,
  status: status,
);

ChatMessage _assistantMessage(
  String id, {
  String? groupId,
  int version = 0,
  DateTime? timestamp,
}) => ChatMessage(
  id: id,
  role: 'assistant',
  content: '',
  conversationId: 'c1',
  groupId: groupId,
  version: version,
  timestamp: timestamp ?? DateTime(2026, 11, 10, 14, 0),
);

Map<String, List<ToolUIPart>> _partsWith(
  String messageId,
  List<ToolUIPart> parts,
) => <String, List<ToolUIPart>>{messageId: parts};

List<Map<String, String>> _incompletePlan() => const [
  {'content': 'First step', 'status': 'completed'},
  {'content': 'Second step', 'status': 'in_progress'},
];

List<Map<String, String>> _completedPlan() => const [
  {'content': 'First step', 'status': 'completed'},
  {'content': 'Second step', 'status': 'completed'},
];

void main() {
  group('TodoPlanSheet', () {
    testWidgets('no plan shows the empty state, not a fake plan', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(TodoPlanSheet(loadPlan: () async => null)));
      await tester.pumpAndSettle();

      expect(find.text('No plan yet'), findsWidgets);
      expect(
        find.textContaining('When a multi-step task starts'),
        findsOneWidget,
      );
      expect(find.text('Clear plan'), findsNothing);
    });

    testWidgets('renders sections, progress and clear action', (tester) async {
      await tester.pumpWidget(
        _wrap(
          TodoPlanSheet(
            loadPlan: () async => _state(),
            clearPlan: () async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Current plan'), findsOneWidget);
      expect(find.textContaining('1/3'), findsWidgets);
      expect(find.text('Draft the plan'), findsOneWidget);
      expect(find.text('Implement the feature'), findsOneWidget);
      expect(find.text('Validate the build'), findsOneWidget);
      expect(find.text('Clear plan'), findsOneWidget);
    });

    testWidgets('clear asks for confirmation and shows the cleared state', (
      tester,
    ) async {
      var cleared = 0;
      await tester.pumpWidget(
        _wrap(
          TodoPlanSheet(
            loadPlan: () async => _state(),
            clearPlan: () async {
              cleared++;
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Clear plan'));
      await tester.pumpAndSettle();
      expect(find.text('Clear this plan?'), findsOneWidget);

      await tester.tap(find.text('Clear plan').last);
      await tester.pumpAndSettle();

      expect(cleared, 1);
      expect(find.text('No active plan'), findsWidgets);
      // The sheet switched to the explicit cleared state; the snackbar lives
      // in the app-level toast host, outside this widget test.
      expect(find.textContaining('was cleared'), findsOneWidget);

      // Fire the toast's auto-dismiss timer, then finish the exit animation
      // before the test navigator (which owns its ticker) is disposed.
      await tester.pump(const Duration(seconds: 4));
      AppSnackBarManager().dismissAll();
      await tester.pumpAndSettle();
    });

    testWidgets('cleared state renders as cleared', (tester) async {
      await tester.pumpWidget(
        _wrap(
          TodoPlanSheet(
            loadPlan: () async =>
                const TodoState(items: <TodoItem>[], hasExplicitState: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No active plan'), findsWidgets);
      expect(find.textContaining('was cleared'), findsOneWidget);
      expect(find.text('Clear plan'), findsNothing);
    });
  });

  group('TodoPlanLiveDock', () {
    testWidgets('hidden when no plan has been written', (tester) async {
      final notifier = StreamingContentNotifier();
      await tester.pumpWidget(
        _wrap(
          TodoPlanLiveDock(
            messages: [_assistantMessage('m1')],
            versionSelections: const <String, int>{},
            toolParts: _partsWith('m1', [
              _todoPart(
                todos: const [],
                content: '{"type":"tool_error","error":"invalid_todos","tool":"write_todos"}',
              ),
            ]),
            notifier: notifier,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Current plan'), findsNothing);
    });

    testWidgets('shows the plan while a run is active and after it goes idle', (
      tester,
    ) async {
      final notifier = StreamingContentNotifier();
      final parts = _partsWith('m1', [
        _todoPart(
          todos: const [
            {'content': 'First step', 'status': 'completed'},
            {'content': 'Second step', 'status': 'in_progress'},
          ],
        ),
      ]);
      await tester.pumpWidget(
        _wrap(
          TodoPlanLiveDock(
            messages: [
              _assistantMessage('m1', timestamp: DateTime(2026, 11, 10, 12)),
            ],
            versionSelections: const <String, int>{},
            toolParts: parts,
            notifier: notifier,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Current plan'), findsOneWidget);
      expect(find.text('Second step'), findsOneWidget);
      expect(find.text('1/2'), findsOneWidget);

      // A later tool update replaces the live snapshot; there is no run-state
      // input, so the dock keeps rendering while the plan stays incomplete.
      parts['m1'] = [
        _todoPart(
          todos: const [
            {'content': 'First step', 'status': 'completed'},
            {'content': 'Second step', 'status': 'in_progress'},
            {'content': 'Third step', 'status': 'pending'},
          ],
        ),
      ];
      notifier.notifyToolPartsUpdated('m1');
      await tester.pumpAndSettle();

      expect(find.text('Current plan'), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
    });

    testWidgets('stays visible from an older message while idle', (
      tester,
    ) async {
      final notifier = StreamingContentNotifier();
      await tester.pumpWidget(
        _wrap(
          TodoPlanLiveDock(
            messages: [
              _assistantMessage('m1', timestamp: DateTime(2026, 11, 10, 12)),
              _assistantMessage('m2', timestamp: DateTime(2026, 11, 10, 12, 5)),
            ],
            versionSelections: const <String, int>{},
            toolParts: _partsWith('m1', [_todoPart(todos: _incompletePlan())]),
            notifier: notifier,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Current plan'), findsOneWidget);
      expect(find.text('Second step'), findsOneWidget);
    });

    testWidgets('hides once every item is completed', (tester) async {
      final notifier = StreamingContentNotifier();
      final parts = _partsWith('m1', [_todoPart(todos: _incompletePlan())]);
      await tester.pumpWidget(
        _wrap(
          TodoPlanLiveDock(
            messages: [_assistantMessage('m1')],
            versionSelections: const <String, int>{},
            toolParts: parts,
            notifier: notifier,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Current plan'), findsOneWidget);

      final completedPart = _todoPart(todos: _completedPlan(), id: 'call_2');
      parts['m1'] = [completedPart];
      notifier.notifyToolPartsUpdated('m1');
      await tester.pumpAndSettle();

      expect(find.text('Current plan'), findsNothing);
    });

    testWidgets('a newer completed plan hides an older incomplete one', (
      tester,
    ) async {
      final notifier = StreamingContentNotifier();
      await tester.pumpWidget(
        _wrap(
          TodoPlanLiveDock(
            messages: [_assistantMessage('m1'), _assistantMessage('m2')],
            versionSelections: const <String, int>{},
            toolParts: <String, List<ToolUIPart>>{
              'm1': [_todoPart(todos: _incompletePlan())],
              'm2': [_todoPart(todos: _completedPlan(), id: 'call_2')],
            },
            notifier: notifier,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Current plan'), findsNothing);
    });

    testWidgets('hides after an idle user clear via toolRevision', (
      tester,
    ) async {
      final notifier = StreamingContentNotifier();
      final parts = _partsWith('m1', [_todoPart(todos: _incompletePlan())]);
      await tester.pumpWidget(
        _wrap(
          TodoPlanLiveDock(
            messages: [_assistantMessage('m1')],
            versionSelections: const <String, int>{},
            toolParts: parts,
            notifier: notifier,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Current plan'), findsOneWidget);

      // User clear appends a successful `todos: []` event even when no stream
      // notifier exists for the message.
      parts['m1'] = [
        ...parts['m1']!,
        _todoPart(
          todos: const [],
          id: 'user_clear_1',
          content: buildTodoResultContent(
            items: const <TodoItem>[],
            changed: true,
            cleared: true,
          ),
        ),
      ];
      notifier.notifyToolPartsUpdated('m1');
      await tester.pumpAndSettle();

      expect(find.text('Current plan'), findsNothing);
    });

    testWidgets('ignores a failed retry and keeps the previous plan', (
      tester,
    ) async {
      final notifier = StreamingContentNotifier();
      await tester.pumpWidget(
        _wrap(
          TodoPlanLiveDock(
            messages: [_assistantMessage('m1'), _assistantMessage('m2')],
            versionSelections: const <String, int>{},
            toolParts: <String, List<ToolUIPart>>{
              'm1': [_todoPart(todos: _incompletePlan())],
              'm2': [
                _todoPart(
                  todos: const [],
                  id: 'call_failed',
                  content: '{"type":"tool_error","error":"invalid_todos","tool":"write_todos"}',
                ),
              ],
            },
            notifier: notifier,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Current plan'), findsOneWidget);
      expect(find.text('Second step'), findsOneWidget);
    });

    testWidgets('projects only the selected version branch', (tester) async {
      final notifier = StreamingContentNotifier();
      final messages = [
        _assistantMessage('m_old', groupId: 'g1', version: 0),
        _assistantMessage('m_new', groupId: 'g1', version: 1),
      ];
      final parts = <String, List<ToolUIPart>>{
        'm_old': [_todoPart(todos: _incompletePlan())],
        'm_new': [_todoPart(todos: _completedPlan(), id: 'call_new')],
      };

      Widget dock(Map<String, int> selections) => _wrap(
        TodoPlanLiveDock(
          messages: messages,
          versionSelections: selections,
          toolParts: parts,
          notifier: notifier,
        ),
      );

      await tester.pumpWidget(dock(const <String, int>{'g1': 0}));
      await tester.pumpAndSettle();
      expect(find.text('Current plan'), findsOneWidget);
      expect(find.text('Second step'), findsOneWidget);

      await tester.pumpWidget(dock(const <String, int>{'g1': 1}));
      await tester.pumpAndSettle();
      expect(find.text('Current plan'), findsNothing);
    });
  });

  group('todoStateFromToolParts', () {
    test('ignores failed and interrupted parts', () {
      expect(
        todoStateFromToolParts([
          _todoPart(
            todos: const [
              {'content': 'A', 'status': 'pending'},
            ],
            status: 'interrupted',
          ),
        ]),
        isNull,
      );
      expect(
        todoStateFromToolParts([
          _todoPart(
            todos: const [
              {'content': 'A', 'status': 'pending'},
            ],
            content: '{"type":"tool_error","error":"invalid_todos","tool":"write_todos"}',
          ),
        ]),
        isNull,
      );
    });

    test('last successful part wins', () {
      final state = todoStateFromToolParts([
        _todoPart(
          todos: const [
            {'content': 'old', 'status': 'pending'},
          ],
        ),
        _todoPart(
          todos: const [
            {'content': 'new', 'status': 'completed'},
          ],
        ),
      ]);
      expect(state, isNotNull);
      expect(state!.items.single.content, 'new');
    });

    test('cleared snapshot projects an explicit empty state', () {
      final state = todoStateFromToolParts([
        _todoPart(
          todos: const [],
          content: buildTodoResultContent(
            items: const <TodoItem>[],
            changed: true,
            cleared: true,
          ),
        ),
      ]);
      expect(state, isNotNull);
      expect(state!.isCleared, isTrue);
    });
  });

  group('StreamingContentNotifier toolRevision', () {
    test('bumps for tool updates without a per-message notifier and on clear', () {
      final notifier = StreamingContentNotifier();
      var revisions = 0;
      notifier.toolRevision.addListener(() => revisions++);

      notifier.notifyToolPartsUpdated('not-streaming');
      expect(revisions, 1);

      notifier.clear();
      expect(revisions, 2);

      notifier.dispose();
    });

    test('ignores tool updates after dispose', () {
      final notifier = StreamingContentNotifier();
      notifier.dispose();

      expect(() => notifier.notifyToolPartsUpdated('m1'), returnsNormally);
    });
  });
}
