import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/conversation.dart';
import 'package:OmniChat/features/chat/widgets/message_export_sheet.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

Conversation _conversation(String id, String title) {
  return Conversation(id: id, title: title);
}

ChatMessage _message(
  String id,
  String conversationId,
  String role,
  String content,
) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    conversationId: conversationId,
  );
}

Future<void> _openExportSheet(
  WidgetTester tester,
  List<ChatExportBundle> bundles,
) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () =>
                  showConversationsExportSheet(context, bundles: bundles),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('multi-conversation export offers one format for every chat', (
    tester,
  ) async {
    final first = _conversation('c1', 'First chat');
    final second = _conversation('c2', 'Second chat');
    await _openExportSheet(tester, [
      ChatExportBundle(
        conversation: first,
        messages: [_message('m1', 'c1', 'user', 'hi')],
      ),
      ChatExportBundle(
        conversation: second,
        messages: [_message('m2', 'c2', 'assistant', 'hello')],
      ),
    ]);

    expect(find.text('Export 2 conversations'), findsOneWidget);
    expect(find.text('Markdown'), findsOneWidget);
    expect(find.text('Text'), findsOneWidget);
    expect(find.text('Image'), findsOneWidget);
    // Batch exports save one file per conversation, so segmented images are
    // intentionally not offered here.
    expect(find.text('Segmented image'), findsNothing);
  });

  testWidgets('single conversation uses the regular export sheet', (
    tester,
  ) async {
    final first = _conversation('c1', 'First chat');
    await _openExportSheet(tester, [
      ChatExportBundle(
        conversation: first,
        messages: [_message('m1', 'c1', 'user', 'hi')],
      ),
    ]);

    expect(find.text('Batch Markdown'), findsOneWidget);
    expect(find.text('Segmented image'), findsOneWidget);
  });
}
