import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/chat/chat_service.dart';
import 'package:OmniChat/features/chat/widgets/chat_message_widget.dart';
import 'package:OmniChat/features/home/controllers/stream_controller.dart'
    as home_stream;
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
    expect(find.text('Search contents'), findsNothing);

    await tester.tap(find.text('Helper trace'));
    await tester.pumpAndSettle();

    // Each child action is a compact tool card, not a monospace trace line.
    expect(find.text('Search contents'), findsOneWidget);
    expect(find.text('120 ms · 800 chars'), findsOneWidget);
    expect(find.textContaining('1 more'), findsOneWidget);

    await tester.tap(find.text('Helper trace'));
    await tester.pumpAndSettle();
    expect(find.text('Search contents'), findsNothing);
  });

  testWidgets('a running child action shows a live card', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SubagentTraceExpander(
            trace: const <String, dynamic>{
              'status': 'running',
              'profile': 'explore',
              'toolCalls': 1,
              'items': <Map<String, dynamic>>[],
              'running': 'file_read',
            },
            color: const Color(0xFF7E7F83),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Helper trace'));
    // The running spinner animates forever; pump one frame instead of
    // waiting for a settle that can never happen.
    await tester.pump();

    expect(find.text('Read file'), findsOneWidget);
    expect(find.text('Running…'), findsOneWidget);
  });

  test('StreamController merges a live trace into the spawn card', () {
    final controller = home_stream.StreamController(
      chatService: ChatService(),
      onStateChanged: () {},
      getSettingsProvider: () => throw UnimplementedError(),
      getCurrentConversationId: () => 'conversation-1',
    );
    controller.setToolParts('message-1', const [
      ToolUIPart(
        id: 'call-1',
        toolName: 'spawn_subagent',
        arguments: <String, dynamic>{},
        loading: true,
      ),
    ]);

    controller.updateToolPartExtras(
      'message-1',
      'call-1',
      subagentTrace: const <String, dynamic>{
        'status': 'running',
        'running': 'file_read',
        'items': <Map<String, dynamic>>[],
      },
    );

    final part = controller.getToolParts('message-1')!.single;
    expect(part.subagentTrace?['running'], 'file_read');
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
