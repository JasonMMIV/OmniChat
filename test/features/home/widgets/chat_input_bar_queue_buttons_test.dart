// Composer Queue / Send now widget tests
// (docs/anybuff_queue_sendnow_import_plan.md §3.2 / §6.1
// `chat_input_bar_queue_buttons_test.dart`).
//
// Pins: idle renders neither button; running + text renders both; running +
// empty renders neither; Enter queues while running (F8); Enter sends while
// idle; Ctrl/Cmd+Enter steers pure text; slash commands fall back to queue.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/chat_input_data.dart';
import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/home/widgets/chat_input_bar.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<void> pumpBar(
    WidgetTester tester, {
    required bool loading,
    ValueChanged<ChatInputData>? onSend,
    ValueChanged<ChatInputData>? onQueue,
    ValueChanged<String>? onSendNow,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ChangeNotifierProvider(create: (_) => AssistantProvider()),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ChatInputBar(
              loading: loading,
              onSend: onSend,
              onQueue: onQueue,
              onSendNow: onSendNow,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder queueButton() => find.byIcon(Lucide.ListPlus);
  Finder sendNowButton() => find.byIcon(Lucide.Zap);

  testWidgets('idle composer shows neither queue nor send now', (tester) async {
    await pumpBar(tester, loading: false);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();

    expect(queueButton(), findsNothing);
    expect(sendNowButton(), findsNothing);
  });

  testWidgets('running composer with text shows [Queue][Send now]', (
    tester,
  ) async {
    await pumpBar(tester, loading: true);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();

    expect(queueButton(), findsOneWidget);
    expect(sendNowButton(), findsOneWidget);
  });

  testWidgets('running composer with empty input shows neither', (
    tester,
  ) async {
    await pumpBar(tester, loading: true);
    expect(queueButton(), findsNothing);
    expect(sendNowButton(), findsNothing);

    // Clearing the text hides the buttons again.
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(queueButton(), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(queueButton(), findsNothing);
    expect(sendNowButton(), findsNothing);
  });

  testWidgets('Enter while running enqueues instead of sending (F8)', (
    tester,
  ) async {
    ChatInputData? sent;
    ChatInputData? queued;
    await pumpBar(
      tester,
      loading: true,
      onSend: (data) => sent = data,
      onQueue: (data) => queued = data,
    );

    await tester.enterText(find.byType(TextField), 'queued text');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(sent, isNull);
    expect(queued, isNotNull);
    expect(queued!.text, 'queued text');
    // The composer clears after enqueueing.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text ?? '',
      isEmpty,
    );
  });

  testWidgets('Enter while idle keeps the normal send path', (tester) async {
    ChatInputData? sent;
    ChatInputData? queued;
    await pumpBar(
      tester,
      loading: false,
      onSend: (data) => sent = data,
      onQueue: (data) => queued = data,
    );

    await tester.enterText(find.byType(TextField), 'normal send');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(queued, isNull);
    expect(sent, isNotNull);
    expect(sent!.text, 'normal send');
  });

  testWidgets('Ctrl+Enter while running steers pure text', (tester) async {
    ChatInputData? queued;
    String? steered;
    await pumpBar(
      tester,
      loading: true,
      onQueue: (data) => queued = data,
      onSendNow: (text) => steered = text,
    );

    await tester.enterText(find.byType(TextField), 'steer me');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(steered, 'steer me');
    expect(queued, isNull);
  });

  testWidgets('Ctrl+Enter falls back to the queue for slash commands', (
    tester,
  ) async {
    ChatInputData? queued;
    String? steered;
    await pumpBar(
      tester,
      loading: true,
      onQueue: (data) => queued = data,
      onSendNow: (text) => steered = text,
    );

    await tester.enterText(find.byType(TextField), '/skill foo');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(steered, isNull);
    expect(queued, isNotNull);
    expect(queued!.text, '/skill foo');
  });
}
