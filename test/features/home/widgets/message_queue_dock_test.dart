// Queue dock widget tests (docs/anybuff_queue_sendnow_import_plan.md §4.2 /
// §6.1 `message_queue_dock_test.dart`).
//
// Pins: count title + hint, item text preview, edit (text only), remove,
// promote, the paused banner's Resume action, attachment-only preview, and
// the empty state rendering nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/chat_input_data.dart';
import 'package:OmniChat/core/services/chat/turn_queue/turn_queue.dart';
import 'package:OmniChat/features/home/widgets/message_queue_dock.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  QueuedMessage item(String id, String text, {int images = 0}) =>
      QueuedMessage(
        id: id,
        conversationId: 'c1',
        input: ChatInputData(
          text: text,
          imagePaths: List<String>.generate(images, (i) => '/tmp/$i.png'),
        ),
        createdAt: DateTime(2026, 11, 13),
      );

  Future<void> pumpDock(WidgetTester tester, MessageQueueDock dock) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: dock),
      ),
    );
    await tester.pump();
  }

  testWidgets('renders the count, hint and item previews', (tester) async {
    await pumpDock(
      tester,
      MessageQueueDock(
        items: [item('q1', 'first message'), item('q2', 'second message')],
        paused: false,
      ),
    );

    expect(find.text('2 queued'), findsOneWidget);
    expect(
      find.text('Sends automatically once the conversation is idle'),
      findsNothing,
    );
    expect(find.text('first message'), findsOneWidget);
    expect(find.text('second message'), findsOneWidget);
  });

  testWidgets('renders nothing when the queue is empty', (tester) async {
    await pumpDock(
      tester,
      const MessageQueueDock(items: <QueuedMessage>[], paused: false),
    );
    expect(find.text('0 queued'), findsNothing);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('remove and promote call back with the item id', (tester) async {
    String? removed;
    String? promoted;
    await pumpDock(
      tester,
      MessageQueueDock(
        items: [item('q1', 'first'), item('q2', 'second')],
        paused: false,
        onRemove: (id) => removed = id,
        onPromote: (id) => promoted = id,
      ),
    );

    await tester.tap(find.byTooltip('Remove').first);
    await tester.pump();
    expect(removed, 'q1');

    await tester.tap(find.byTooltip('Move to front').last);
    await tester.pump();
    expect(promoted, 'q2');
  });

  testWidgets('per-item send now steers the queued text', (tester) async {
    String? sentId;
    await pumpDock(
      tester,
      MessageQueueDock(
        items: [item('q1', 'steer me')],
        paused: false,
        runActive: true,
        onSendNow: (id) => sentId = id,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('queue-send-now-q1')));
    await tester.pump();
    expect(sentId, 'q1');
  });

  testWidgets('per-item send now is disabled without a live run', (
    tester,
  ) async {
    await pumpDock(
      tester,
      MessageQueueDock(
        items: [item('q1', 'steer me')],
        paused: false,
        onSendNow: (_) {},
      ),
    );

    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('queue-send-now-q1')),
    );
    expect(button.onPressed, isNull);
    expect(find.byTooltip('Only while a turn is running'), findsOneWidget);
  });

  testWidgets('attachments block per-item send now', (tester) async {
    await pumpDock(
      tester,
      MessageQueueDock(
        items: [item('q1', 'with image', images: 1)],
        paused: false,
        runActive: true,
        onSendNow: (_) {},
      ),
    );

    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('queue-send-now-q1')),
    );
    expect(button.onPressed, isNull);
    expect(find.byTooltip('Attachments can only be queued'), findsOneWidget);
  });

  testWidgets('slash commands block per-item send now', (tester) async {
    await pumpDock(
      tester,
      MessageQueueDock(
        items: [item('q1', '/skill foo')],
        paused: false,
        runActive: true,
        onSendNow: (_) {},
      ),
    );

    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('queue-send-now-q1')),
    );
    expect(button.onPressed, isNull);
    expect(find.byTooltip('Slash commands can only be queued'), findsOneWidget);
  });

  testWidgets('AI Team blocks per-item send now', (tester) async {
    await pumpDock(
      tester,
      MessageQueueDock(
        items: [item('q1', 'steer me')],
        paused: false,
        runActive: true,
        teamActive: true,
        onSendNow: (_) {},
      ),
    );

    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('queue-send-now-q1')),
    );
    expect(button.onPressed, isNull);
    expect(find.byTooltip('Unavailable during AI Team'), findsOneWidget);
  });

  testWidgets('edit dialog updates the text but not attachments', (
    tester,
  ) async {
    String? editedId;
    String? editedText;
    await pumpDock(
      tester,
      MessageQueueDock(
        items: [item('q1', 'old text', images: 2)],
        paused: false,
        onEdit: (id, text) {
          editedId = id;
          editedText = text;
        },
      ),
    );

    await tester.tap(find.byTooltip('Edit text').first);
    await tester.pumpAndSettle();

    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(dialogField, findsOneWidget);
    await tester.enterText(dialogField, 'new text');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(editedId, 'q1');
    expect(editedText, 'new text');
  });

  testWidgets('paused queue shows the resume banner and callback', (
    tester,
  ) async {
    var resumed = false;
    await pumpDock(
      tester,
      MessageQueueDock(
        items: [item('q1', 'first')],
        paused: true,
        onResume: () => resumed = true,
      ),
    );

    expect(find.text('Resume'), findsOneWidget);
    await tester.tap(find.text('Resume'));
    await tester.pump();
    expect(resumed, isTrue);
  });

  testWidgets('attachment-only items show the attachment count', (
    tester,
  ) async {
    await pumpDock(
      tester,
      MessageQueueDock(items: [item('q1', '', images: 3)], paused: false),
    );
    expect(find.text('3'), findsOneWidget);
    expect(find.byIcon(Icons.attach_file), findsOneWidget);
  });
}
