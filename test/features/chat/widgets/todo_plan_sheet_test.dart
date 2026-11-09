// Phase 3 plan UI tests (docs/write_todos_improvement_plan.md §2.4.3/§2.4.5).
//
// - TodoPlanSheet: empty state, items/progress, user clear confirmation and
//   the cleared state after the event is appended.
// - TodoPlanLiveDock: running-only visibility, live snapshot updates, and
//   disappearance when the run ends (transcript card is not this widget).
// - todoStateFromToolParts: success-only projection over in-memory parts.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}) => ToolUIPart(
  id: 'call_1',
  toolName: todoToolName,
  arguments: <String, dynamic>{'todos': todos},
  content: content,
  loading: false,
  status: status,
);

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
    testWidgets('hidden when the run is not active', (tester) async {
      final notifier = StreamingContentNotifier();
      await tester.pumpWidget(
        _wrap(
          TodoPlanLiveDock(
            visible: false,
            streamingMessageId: 'm1',
            toolParts: {
              'm1': [_todoPart(todos: const [])],
            },
            notifier: notifier,
          ),
        ),
      );
      expect(find.text('Current plan'), findsNothing);
    });

    testWidgets('shows the live snapshot and updates on tool parts', (
      tester,
    ) async {
      final notifier = StreamingContentNotifier();
      final parts = <String, List<ToolUIPart>>{
        'm1': [
          _todoPart(
            todos: const [
              {'content': 'First step', 'status': 'completed'},
              {'content': 'Second step', 'status': 'in_progress'},
            ],
          ),
        ],
      };
      await tester.pumpWidget(
        _wrap(
          TodoPlanLiveDock(
            visible: true,
            streamingMessageId: 'm1',
            toolParts: parts,
            notifier: notifier,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Current plan'), findsOneWidget);
      expect(find.text('Second step'), findsOneWidget);
      expect(find.text('1/2'), findsOneWidget);

      parts['m1'] = [
        _todoPart(
          todos: const [
            {'content': 'First step', 'status': 'completed'},
            {'content': 'Second step', 'status': 'completed'},
          ],
        ),
      ];
      notifier.notifyToolPartsUpdated('m1');
      await tester.pump();

      expect(find.text('2/2'), findsOneWidget);
    });

    testWidgets('no dock content while no plan has been written', (
      tester,
    ) async {
      final notifier = StreamingContentNotifier();
      await tester.pumpWidget(
        _wrap(
          TodoPlanLiveDock(
            visible: true,
            streamingMessageId: 'm1',
            toolParts: {
              'm1': [
                _todoPart(
                  todos: const [],
                  content: '{"type":"tool_error","error":"invalid_todos","tool":"write_todos"}',
                ),
              ],
            },
            notifier: notifier,
          ),
        ),
      );
      await tester.pump();

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
}
