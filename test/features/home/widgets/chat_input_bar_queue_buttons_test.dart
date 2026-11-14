// Composer Queue / Send now widget tests
// (docs/anybuff_queue_sendnow_import_plan.md §3.2 / §6.1
// `chat_input_bar_queue_buttons_test.dart`).
//
// Pins: idle renders neither button; running + text renders [Send now][Queue]
// (send now gray disc with primary glyph, queue filled circle) with 8 px gaps;
// running + empty
// renders neither; Enter queues while running (F8); Enter sends while idle;
// Ctrl/Cmd+Enter steers pure text; slash commands fall back to queue.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/chat_input_data.dart';
import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/home/widgets/chat_input_bar.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<void> pumpBar(
    WidgetTester tester, {
    required bool loading,
    Brightness brightness = Brightness.light,
    bool sendNowTeamBlocked = false,
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
          theme: ThemeData(brightness: brightness),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ChatInputBar(
              loading: loading,
              sendNowTeamBlocked: sendNowTeamBlocked,
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

  Finder queueButton() => find.byKey(const ValueKey('composer-queue-button'));
  Finder sendNowButton() =>
      find.byKey(const ValueKey('composer-send-now-button'));

  testWidgets('idle composer shows neither queue nor send now', (tester) async {
    await pumpBar(tester, loading: false);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();

    expect(queueButton(), findsNothing);
    expect(sendNowButton(), findsNothing);
  });

  testWidgets('running composer with text shows [Send now][Queue]', (
    tester,
  ) async {
    await pumpBar(tester, loading: true);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    // Let the AnimatedSwitcher scale settle before measuring rects.
    await tester.pump(const Duration(milliseconds: 300));

    expect(queueButton(), findsOneWidget);
    expect(sendNowButton(), findsOneWidget);

    // Send now leads; queue sits against stop as the recoverable buffer.
    final q = tester.getRect(queueButton());
    final s = tester.getRect(sendNowButton());
    expect(s.left, lessThan(q.left));
  });

  testWidgets('queue cluster keeps the 8 px gaps used by the bar', (
    tester,
  ) async {
    await pumpBar(tester, loading: true);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final cluster = tester.getRect(find.byKey(const ValueKey('queue-cluster')));
    final stop = tester.getRect(
      find
          .ancestor(
            of: find.byKey(const ValueKey('stop')),
            matching: find.byType(InkWell),
          )
          .first,
    );

    // Leading 8 px + 32 (send now) + 8 + 32 (queue).
    expect(cluster.width, 80, reason: 'cluster=$cluster stop=$stop');
    expect(stop.left - cluster.right, 8, reason: 'cluster=$cluster stop=$stop');
  });

  testWidgets('composer action buttons keep the 32×32 footprint', (
    tester,
  ) async {
    await pumpBar(tester, loading: true);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();

    expect(tester.getSize(queueButton()), const Size(32, 32));
    expect(tester.getSize(sendNowButton()), const Size(32, 32));
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'queue paints the filled circle, send now the gray disc (${brightness.name})',
      (tester) async {
        await pumpBar(
          tester,
          loading: true,
          brightness: brightness,
          onSendNow: (_) {},
        );
        await tester.enterText(find.byType(TextField), 'hello');
        await tester.pump();

        final context = tester.element(find.byType(ChatInputBar));
        final primary = Theme.of(context).colorScheme.primary;
        final isDark = brightness == Brightness.dark;

        final queueMaterial = tester.widget<Material>(
          find
              .descendant(of: queueButton(), matching: find.byType(Material))
              .first,
        );
        expect(queueMaterial.color, primary);

        final sendMaterial = tester.widget<Material>(
          find
              .descendant(of: sendNowButton(), matching: find.byType(Material))
              .first,
        );
        expect(
          sendMaterial.color,
          isDark
              ? Colors.white.withValues(alpha: 0.13)
              : Colors.black.withValues(alpha: 0.07),
        );
        // The accelerator no longer carries a ring.
        final side = (sendMaterial.shape as CircleBorder).side;
        expect(side, BorderSide.none);
      },
    );
  }

  for (final (brightness, expected) in <(Brightness, Color)>[
    (Brightness.light, const Color(0xFFB04A50)),
    (Brightness.dark, const Color(0xFFA8454C)),
  ]) {
    testWidgets(
      'running composer paints the stop button muted red (${brightness.name})',
      (tester) async {
        await pumpBar(tester, loading: true, brightness: brightness);
        await tester.enterText(find.byType(TextField), 'hello');
        await tester.pump();

        final stopIcon = find.byKey(const ValueKey('stop'));
        expect(stopIcon, findsOneWidget);
        final material = tester.widget<Material>(
          find.ancestor(of: stopIcon, matching: find.byType(Material)).first,
        );
        expect(material.color, expected);
      },
    );
  }

  testWidgets('send now is inert when the steer gate blocks it', (
    tester,
  ) async {
    String? steered;
    await pumpBar(
      tester,
      loading: true,
      sendNowTeamBlocked: true,
      onSendNow: (text) => steered = text,
    );
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();

    final inkWell = tester.widget<InkWell>(
      find.descendant(of: sendNowButton(), matching: find.byType(InkWell)),
    );
    expect(inkWell.onTap, isNull);
    expect(steered, isNull);
  });

  testWidgets('send now keeps its gray disc when the gate blocks it', (
    tester,
  ) async {
    await pumpBar(tester, loading: true, sendNowTeamBlocked: true);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();

    final sendMaterial = tester.widget<Material>(
      find
          .descendant(of: sendNowButton(), matching: find.byType(Material))
          .first,
    );
    // Blocking mutes the glyph only; the disc itself stays unchanged.
    expect(sendMaterial.color, Colors.black.withValues(alpha: 0.07));
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
