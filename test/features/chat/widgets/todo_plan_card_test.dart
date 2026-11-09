// TodoPlanCard widget tests (docs/write_todos_improvement_plan.md §2.4.1).
//
// Pins the card state machine: the spinner tracks status/loading only —
// never `content == null` — and tool_error / interrupted / cleared states
// render instead of faking a plan.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/chat/todo_models.dart';
import 'package:OmniChat/features/chat/widgets/cowork_tool_cards.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// IosCardPress reads the haptics preference on tap; a minimal double keeps
/// the card test independent of the full settings load.
class _CardSettings extends ChangeNotifier implements SettingsProvider {
  @override
  bool get hapticsOnCardTap => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: ChangeNotifierProvider<SettingsProvider>.value(
    value: _CardSettings(),
    child: Scaffold(body: child),
  ),
);

Map<String, dynamic> _args([
  List<Map<String, String>> todos = const [
    {'content': 'Step one', 'status': 'pending'},
    {'content': 'Step two', 'status': 'completed'},
  ],
]) => {'todos': todos};

void main() {
  testWidgets('live part: loading=true shows spinner', (tester) async {
    await tester.pumpWidget(
      _wrap(TodoPlanCard(arguments: _args(), content: null, loading: true)),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('persisted pending status shows spinner', (tester) async {
    await tester.pumpWidget(
      _wrap(TodoPlanCard(arguments: _args(), content: null, status: 'pending')),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('restored completed card without body renders from arguments '
      '— no eternal spinner', (tester) async {
    await tester.pumpWidget(
      _wrap(
        TodoPlanCard(
          arguments: _args(),
          content: null,
          status: 'completed',
          contentLoaded: false,
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Step one'), findsOneWidget);
    expect(find.text('Step two'), findsOneWidget);
    expect(find.textContaining('1/2'), findsOneWidget);
  });

  testWidgets('canonical snapshot content wins over raw arguments '
      '(changed=true)', (tester) async {
    final content = buildTodoResultContent(
      items: const [
        TodoItem(content: 'normalized item', status: 'in_progress'),
      ],
      changed: true,
      cleared: false,
    );
    await tester.pumpWidget(
      _wrap(
        TodoPlanCard(arguments: _args(), content: content, status: 'completed'),
      ),
    );
    expect(find.text('normalized item'), findsOneWidget);
    expect(find.text('Step one'), findsNothing);
    expect(find.textContaining('0/1'), findsOneWidget);
  });

  testWidgets('tool_error content shows the error, not a plan', (tester) async {
    await tester.pumpWidget(
      _wrap(
        TodoPlanCard(
          arguments: _args(),
          content:
              '{"type":"tool_error","error":"invalid_todos","message":"bad list",'
              '"tool":"write_todos"}',
          status: 'completed',
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Plan update failed'), findsOneWidget);
    expect(find.textContaining('bad list'), findsOneWidget);
    expect(find.text('Step one'), findsNothing);
  });

  testWidgets('interrupted status shows the interruption note, no spinner', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        TodoPlanCard(arguments: _args(), content: null, status: 'interrupted'),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('interrupted'), findsOneWidget);
  });

  testWidgets('cleared snapshot shows the cleared note', (tester) async {
    final content = buildTodoResultContent(
      items: const <TodoItem>[],
      changed: true,
      cleared: true,
      includeItems: true,
    );
    await tester.pumpWidget(
      _wrap(
        TodoPlanCard(
          arguments: {'todos': <Object>[]},
          content: content,
          status: 'completed',
        ),
      ),
    );
    expect(find.textContaining('cleared'), findsOneWidget);
    expect(find.text('Plan cleared.'), findsOneWidget);
  });

  testWidgets('older plan cards start collapsed; tapping opens them', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        TodoPlanCard(
          arguments: _args(),
          content: null,
          status: 'completed',
          isLatestPlan: false,
        ),
      ),
    );
    // Collapsed: items not rendered, progress still visible.
    expect(find.text('Step one'), findsNothing);
    expect(find.textContaining('1/2'), findsOneWidget);

    await tester.tap(find.text('Plan'));
    await tester.pump();
    expect(find.text('Step one'), findsOneWidget);
    expect(find.text('Step two'), findsOneWidget);
  });

  testWidgets('an older card collapses when a newer plan appears',
      (tester) async {
    await tester.pumpWidget(_wrap(TodoPlanCard(
      arguments: _args(),
      content: null,
      status: 'completed',
    )));
    expect(find.text('Step one'), findsOneWidget);

    await tester.pumpWidget(_wrap(TodoPlanCard(
      arguments: _args(),
      content: null,
      status: 'completed',
      isLatestPlan: false,
    )));
    await tester.pump();
    expect(find.text('Step one'), findsNothing);
  });

  testWidgets('a collapsed failed card still reports the failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        TodoPlanCard(
          arguments: _args(),
          content:
              '{"type":"tool_error","error":"invalid_todos","message":"bad list",'
              '"tool":"write_todos"}',
          status: 'completed',
          isLatestPlan: false,
        ),
      ),
    );
    expect(
      find.text('Plan update failed. The previous plan is unchanged.'),
      findsOneWidget,
    );
  });

  testWidgets('all-completed arguments auto-collapse to the summary', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        TodoPlanCard(
          arguments: _args([
            {'content': 'Done A', 'status': 'completed'},
            {'content': 'Done B', 'status': 'completed'},
          ]),
          content: null,
          status: 'completed',
        ),
      ),
    );
    // Collapsed: items not rendered.
    expect(find.text('Done A'), findsNothing);
    expect(find.textContaining('2/2'), findsOneWidget);
  });
}
