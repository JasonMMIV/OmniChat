import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/message_usage.dart';
import 'package:OmniChat/features/chat/widgets/message_usage_sheet.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

Future<void> _pumpSheet(WidgetTester tester, MessageUsage usage) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: MessageUsageSheet(usage: usage)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Go shows allowance, list price, and charged zero', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      const MessageUsage(
        costUsd: 0,
        listCostUsd: 0.00000695,
        allowanceUsd: 0.00000695,
        billingSource: 'go',
        inputTokens: 13,
        outputTokens: 10,
        reasoningTokens: 4,
        cacheReadTokens: 2,
        cacheWrite5mTokens: 1,
        cacheWrite1hTokens: 3,
      ),
    );

    expect(find.text('Usage & cost'), findsOneWidget);
    expect(find.text('Go allowance'), findsWidgets);
    expect(find.text(r'$0.00000695'), findsWidgets);
    expect(find.text('List price'), findsOneWidget);
    expect(find.text('Charged'), findsOneWidget);
    expect(find.text(r'$0'), findsOneWidget);
    expect(find.text('go'), findsOneWidget);
  });

  testWidgets('balance shows the charged amount', (tester) async {
    await _pumpSheet(
      tester,
      const MessageUsage(
        costUsd: 0.0041,
        listCostUsd: 0.0041,
        billingSource: 'balance',
      ),
    );

    expect(find.text('Charged'), findsWidgets);
    expect(find.text(r'$0.0041'), findsWidgets);
    expect(find.text('balance'), findsOneWidget);
  });

  testWidgets('free shows Free without implying a Go allowance', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      const MessageUsage(costUsd: 0, listCostUsd: 0, billingSource: 'free'),
    );

    expect(find.text('Free'), findsOneWidget);
    expect(find.text('Go allowance'), findsNothing);
    expect(find.text('free'), findsOneWidget);
  });
}
