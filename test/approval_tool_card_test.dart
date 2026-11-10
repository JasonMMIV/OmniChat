// P1-1 (2026-11-10): the approval card must show progress and hide its
// buttons while an approved tool is executing. Without this the paused card
// stays visually identical for the whole (possibly multi-minute) shell run and
// invites repeated taps, which re-executes the command.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/approval.dart';
import 'package:OmniChat/features/chat/widgets/chat_message_widget.dart'
    show ToolUIPart;
import 'package:OmniChat/features/chat/widgets/cowork_tool_cards.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

const Map<String, dynamic> _arguments = <String, dynamic>{
  'command': 'dart analyze lib/features/chat/widgets/cowork_tool_cards.dart',
};

Future<void> _pumpCard(WidgetTester tester, {required bool executing}) async {
  final content = buildApprovalPendingContent(
    toolName: 'shell_run',
    arguments: _arguments,
  );
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: ApprovalToolCard(
          part: ToolUIPart(
            id: 'call-1',
            toolName: 'shell_run',
            arguments: _arguments,
            content: content,
          ),
          approval: parseApprovalContent(content)!,
          canResume: true,
          executing: executing,
          onApprove: (_) async {},
          onDeny: () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('pending card offers the decision buttons', (tester) async {
    await _pumpCard(tester, executing: false);

    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Always allow'), findsOneWidget);
    expect(find.text('Deny'), findsOneWidget);
    expect(find.text('Approved'), findsNothing);
    expect(find.text('Approved — running…'), findsNothing);
  });

  testWidgets('executing card hides the buttons and shows progress', (
    tester,
  ) async {
    await _pumpCard(tester, executing: true);

    expect(find.text('Approved'), findsOneWidget);
    expect(find.text('Running shell_run…'), findsOneWidget);
    expect(find.text('Approved — running…'), findsOneWidget);
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Always allow'), findsNothing);
    expect(find.text('Deny'), findsNothing);
  });
}
