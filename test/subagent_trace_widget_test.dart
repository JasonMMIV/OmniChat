import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/features/chat/widgets/chat_message_widget.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

void main() {
  const trace = <String, dynamic>{
    'status': 'max_steps',
    'profile': 'explore',
    'steps': 12,
    'toolCalls': 14,
    'tokens': 54210,
    'summarySource': 'wrap_up',
    'items': [
      {'t': 'file_grep', 'ms': 120, 'chars': 800},
    ],
    'more': 1,
  };

  testWidgets('the helper trace expands and collapses', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SubagentTraceExpander(
            trace: trace,
            color: const Color(0xFF7E7F83),
          ),
        ),
      ),
    );

    expect(find.text('Helper trace'), findsOneWidget);
    expect(find.textContaining('file_grep'), findsNothing);

    await tester.tap(find.text('Helper trace'));
    await tester.pumpAndSettle();

    expect(find.textContaining('file_grep'), findsOneWidget);
    expect(find.textContaining('120 ms'), findsOneWidget);
    expect(find.textContaining('800 chars'), findsOneWidget);
    expect(find.textContaining('1 more'), findsOneWidget);

    await tester.tap(find.text('Helper trace'));
    await tester.pumpAndSettle();
    expect(find.textContaining('file_grep'), findsNothing);
  });

  test('ToolUIPart.copyWith preserves the helper trace', () {
    const part = ToolUIPart(
      id: 'call-1',
      toolName: 'spawn_subagent',
      arguments: <String, dynamic>{},
      subagentTrace: trace,
    );

    final updated = part.copyWith(loading: false);
    expect(updated.subagentTrace, trace);
  });
}
