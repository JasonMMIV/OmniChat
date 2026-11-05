import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/message_usage.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/chat/widgets/message_more_sheet.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

ChatMessage _message({required bool withUsage, bool emptyUsage = false}) {
  return ChatMessage(
    id: 'm1',
    role: 'assistant',
    content: 'hello',
    conversationId: 'c1',
    usageMetaJson: emptyUsage
        ? '{}'
        : withUsage
        ? jsonEncode(
            const MessageUsage(
              costUsd: 0.0041,
              billingSource: 'balance',
            ).toJson(),
          )
        : null,
  );
}

Future<MessageMoreAction?> _openMoreSheet(
  WidgetTester tester,
  ChatMessage message,
) async {
  MessageMoreAction? result;
  await tester.pumpWidget(
    ChangeNotifierProvider<SettingsProvider>.value(
      value: SettingsProvider(),
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showMessageMoreSheet(context, message);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('shows Usage only when the message has usage metadata', (
    tester,
  ) async {
    await _openMoreSheet(tester, _message(withUsage: true));
    expect(find.text('Usage & cost'), findsOneWidget);
  });

  testWidgets('returns the usage action', (tester) async {
    MessageMoreAction? result;
    final message = _message(withUsage: true);
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: SettingsProvider(),
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showMessageMoreSheet(context, message);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Usage & cost'));
    await tester.pumpAndSettle();

    expect(result, MessageMoreAction.usage);
  });

  testWidgets('hides Usage without usage metadata', (tester) async {
    await _openMoreSheet(tester, _message(withUsage: false));
    expect(find.text('Usage & cost'), findsNothing);
  });

  testWidgets('hides Usage for an empty usage map', (tester) async {
    await _openMoreSheet(tester, _message(withUsage: true, emptyUsage: true));
    expect(find.text('Usage & cost'), findsNothing);
  });

  testWidgets('desktop menu returns the usage action', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      MessageMoreAction? result;
      final message = _message(withUsage: true);
      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>.value(
          value: SettingsProvider(),
          child: MaterialApp(
            locale: const Locale('en'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () async {
                    result = await showMessageMoreSheet(context, message);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Usage & cost'));
      await tester.pumpAndSettle();

      expect(result, MessageMoreAction.usage);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
