import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/features/home/widgets/mini_map_popover.dart';

ChatMessage _message(String id, String role, String content) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    conversationId: 'c1',
  );
}

Widget _host({
  required GlobalKey anchorKey,
  required List<ChatMessage> messages,
  required ValueChanged<String?> onResult,
  TextScaler textScaler = TextScaler.noScaling,
  FocusNode? focusNode,
}) {
  return MaterialApp(
    builder: (context, child) {
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      );
    },
    home: Scaffold(
      body: Stack(
        children: [
          if (focusNode != null)
            Positioned(
              left: 12,
              top: 12,
              width: 200,
              child: TextField(focusNode: focusNode),
            ),
          Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 12, bottom: 100),
              child: Builder(
                builder: (context) {
                  return ElevatedButton(
                    key: anchorKey,
                    onPressed: () async {
                      final result = await showMiniMapPopover(
                        context,
                        anchorKey: anchorKey,
                        messages: messages,
                      );
                      onResult(result);
                    },
                    child: const Text('open'),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('opens, renders pairs, and closes from the barrier', (
    tester,
  ) async {
    final anchorKey = GlobalKey();
    String? result;

    await tester.pumpWidget(
      _host(
        anchorKey: anchorKey,
        messages: [
          _message('u1', 'user', 'Hello there'),
          _message('a1', 'assistant', 'General Kenobi'),
        ],
        onResult: (value) => result = value,
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Hello there'), findsOneWidget);
    expect(find.text('General Kenobi'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('Hello there'), findsNothing);
    expect(result, isNull);
  });

  testWidgets('anchors above the button and returns the selected message id', (
    tester,
  ) async {
    final anchorKey = GlobalKey();
    String? result;

    await tester.pumpWidget(
      _host(
        anchorKey: anchorKey,
        messages: [
          _message('u1', 'user', 'Hello there'),
          _message('a1', 'assistant', 'General Kenobi'),
        ],
        onResult: (value) => result = value,
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final panelRect = tester.getRect(
      find.byKey(const ValueKey('mini-map-popover')),
    );
    final anchorRect = tester.getRect(find.byKey(anchorKey));
    expect(panelRect.right, closeTo(anchorRect.right, 0.5));
    expect(panelRect.bottom, closeTo(anchorRect.top - 6, 0.5));

    await tester.tap(find.text('Hello there'));
    await tester.pumpAndSettle();

    expect(find.text('Hello there'), findsNothing);
    expect(result, 'u1');
  });

  testWidgets('system back closes the popover but keeps the page', (
    tester,
  ) async {
    final anchorKey = GlobalKey();
    String? result;

    await tester.pumpWidget(
      _host(
        anchorKey: anchorKey,
        messages: [
          _message('u1', 'user', 'Hello there'),
          _message('a1', 'assistant', 'General Kenobi'),
        ],
        onResult: (value) => result = value,
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Hello there'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('open'), findsOneWidget);
    expect(find.text('Hello there'), findsNothing);
    expect(result, isNull);
  });

  testWidgets('caps the panel height on a long conversation', (tester) async {
    final anchorKey = GlobalKey();
    final messages = <ChatMessage>[];
    for (var i = 0; i < 30; i++) {
      messages.add(_message('u$i', 'user', 'Question $i'));
      messages.add(_message('a$i', 'assistant', 'Answer $i'));
    }

    await tester.pumpWidget(
      _host(anchorKey: anchorKey, messages: messages, onResult: (_) {}),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final panelRect = tester.getRect(
      find.byKey(const ValueKey('mini-map-popover')),
    );
    expect(panelRect.height, greaterThan(0));
    expect(panelRect.height, lessThanOrEqualTo(270));

    await tester.drag(
      find.byKey(const ValueKey('mini-map-list')),
      const Offset(0, -5000),
    );
    await tester.pumpAndSettle();
    expect(find.text('Question 29'), findsOneWidget);
  });

  testWidgets('holds the fixed row layout at a large text scale', (
    tester,
  ) async {
    final anchorKey = GlobalKey();

    await tester.pumpWidget(
      _host(
        anchorKey: anchorKey,
        messages: [
          _message('u1', 'user', 'Hello there'),
          _message('a1', 'assistant', 'General Kenobi'),
        ],
        onResult: (_) {},
        textScaler: const TextScaler.linear(2),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Hello there'), findsOneWidget);
  });

  testWidgets('holds the fixed row layout at a fractional text scale', (
    tester,
  ) async {
    final anchorKey = GlobalKey();

    await tester.pumpWidget(
      _host(
        anchorKey: anchorKey,
        messages: [
          _message('u1', 'user', 'Hello there'),
          _message('a1', 'assistant', 'General Kenobi'),
        ],
        onResult: (_) {},
        textScaler: const TextScaler.linear(1.3),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Hello there'), findsOneWidget);
  });

  testWidgets('double-tapping a row does not pop the host page', (
    tester,
  ) async {
    final anchorKey = GlobalKey();

    await tester.pumpWidget(
      _host(
        anchorKey: anchorKey,
        messages: [
          _message('u1', 'user', 'Hello there'),
          _message('a1', 'assistant', 'General Kenobi'),
        ],
        onResult: (_) {},
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final rowCenter = tester.getCenter(find.text('Hello there'));
    await tester.tapAt(rowCenter);
    await tester.tapAt(rowCenter);
    await tester.pumpAndSettle();

    expect(find.text('open'), findsOneWidget);
    expect(find.text('Hello there'), findsNothing);
  });

  testWidgets('keeps the composer focused when the popover opens', (
    tester,
  ) async {
    final anchorKey = GlobalKey();
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      _host(
        anchorKey: anchorKey,
        messages: [
          _message('u1', 'user', 'Hello there'),
          _message('a1', 'assistant', 'General Kenobi'),
        ],
        onResult: (_) {},
        focusNode: focusNode,
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(focusNode.hasFocus, isTrue);
  });
}
