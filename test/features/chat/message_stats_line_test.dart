import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/message_usage.dart';
import 'package:OmniChat/features/chat/widgets/message_stats_line.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

ChatMessage _message({int? totalTokens = 23, MessageUsage? usage}) {
  return ChatMessage(
    id: 'm1',
    role: 'assistant',
    content: 'hello',
    conversationId: 'c1',
    totalTokens: totalTokens,
    usageMetaJson: usage == null ? null : jsonEncode(usage.toJson()),
  );
}

Future<void> _pump(WidgetTester tester, ChatMessage message) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: MessageStatsLine(message: message)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the existing stats line without usage', (tester) async {
    await _pump(tester, _message());
    expect(find.text('23 tokens · 5 字'), findsOneWidget);
  });

  testWidgets('appends the cost and opens the usage sheet', (tester) async {
    await _pump(
      tester,
      _message(
        usage: const MessageUsage(costUsd: 0.0041, billingSource: 'balance'),
      ),
    );

    expect(find.text(r'23 tokens · 5 字 · $0.0041'), findsOneWidget);
    await tester.tap(find.text(r'23 tokens · 5 字 · $0.0041'));
    await tester.pumpAndSettle();
    expect(find.text('Usage & cost'), findsOneWidget);
  });

  testWidgets('Go shows the allowance instead of a zero charge', (
    tester,
  ) async {
    await _pump(
      tester,
      _message(
        usage: const MessageUsage(
          costUsd: 0,
          allowanceUsd: 0.00000695,
          billingSource: 'go',
        ),
      ),
    );

    expect(
      find.text(r'23 tokens · 5 字 · Go allowance $0.00000695'),
      findsOneWidget,
    );
  });
}
