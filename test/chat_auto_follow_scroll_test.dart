import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/features/home/controllers/scroll_controller.dart';

/// Builds a tall list whose final item can be resized between frames, which is
/// the shape that used to leave the viewport parked past the end of the list.
Widget _harness({
  required ChatAutoFollowScrollController controller,
  required double tailHeight,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ListView.builder(
        controller: controller,
        // Keep the tail item built so maxScrollExtent is measured, not
        // extrapolated from the built children.
        cacheExtent: 4000,
        itemCount: 2,
        itemBuilder: (context, index) {
          if (index == 0) {
            return const SizedBox(height: 1200);
          }
          return SizedBox(height: tailHeight);
        },
      ),
    ),
  );
}

void main() {
  group('ChatAutoFollowScrollController', () {
    testWidgets('keeps the tail pinned while the content grows', (
      tester,
    ) async {
      final controller = ChatAutoFollowScrollController();
      controller.shouldFollowBottom = (_) => true;
      addTearDown(controller.dispose);

      var tailHeight = 600.0;
      late StateSetter setState;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setter) {
            setState = setter;
            return _harness(controller: controller, tailHeight: tailHeight);
          },
        ),
      );
      await tester.pump();

      final position = controller.position;
      controller.jumpTo(position.maxScrollExtent);
      await tester.pump();
      final initialMax = position.maxScrollExtent;
      expect(initialMax, greaterThan(0));
      expect(position.pixels, initialMax);

      setState(() => tailHeight = 900);
      await tester.pump();

      expect(position.maxScrollExtent, initialMax + 300);
      expect(position.pixels, position.maxScrollExtent);
    });

    testWidgets('pulls the offset back when the tail shrinks below it', (
      tester,
    ) async {
      final controller = ChatAutoFollowScrollController();
      controller.shouldFollowBottom = (_) => true;
      addTearDown(controller.dispose);

      var tailHeight = 600.0;
      late StateSetter setState;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setter) {
            setState = setter;
            return _harness(controller: controller, tailHeight: tailHeight);
          },
        ),
      );
      await tester.pump();

      final position = controller.position;
      controller.jumpTo(position.maxScrollExtent);
      await tester.pump();
      expect(position.pixels, position.maxScrollExtent);

      setState(() => tailHeight = 100);
      await tester.pump();

      // The shrink moved the end of the list above the current offset; the pin
      // has to bring it back or the viewport paints empty space.
      expect(position.pixels, position.maxScrollExtent);
      expect(position.extentAfter, 0);
    });

    testWidgets(
      'never leaves the offset past the end when the tail shrinks mid-animation',
      (tester) async {
        final controller = ChatAutoFollowScrollController();
        controller.shouldFollowBottom = (_) => true;
        addTearDown(controller.dispose);

        var tailHeight = 600.0;
        late StateSetter setState;
        await tester.pumpWidget(
          StatefulBuilder(
            builder: (context, setter) {
              setState = setter;
              return _harness(controller: controller, tailHeight: tailHeight);
            },
          ),
        );
        await tester.pump();

        final position = controller.position;
        // Drive the list toward the bottom the way the old streaming path did.
        unawaited(
          controller.animateTo(
            position.maxScrollExtent,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));

        // The reply finishes: the tail collapses while the animation is still
        // in flight, so the animation target is now past the end of the list.
        setState(() => tailHeight = 100);
        for (var frame = 0; frame < 30; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            position.pixels,
            lessThanOrEqualTo(position.maxScrollExtent + 0.5),
            reason: 'offset went past the end on frame $frame',
          );
        }
        await tester.pumpAndSettle();

        expect(position.pixels, position.maxScrollExtent);
        expect(position.extentAfter, 0);
      },
    );

    testWidgets('does not move the offset while auto-follow is off', (
      tester,
    ) async {
      final controller = ChatAutoFollowScrollController();
      controller.shouldFollowBottom = (_) => false;
      addTearDown(controller.dispose);

      var tailHeight = 600.0;
      late StateSetter setState;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setter) {
            setState = setter;
            return _harness(controller: controller, tailHeight: tailHeight);
          },
        ),
      );
      await tester.pump();

      final position = controller.position;
      controller.jumpTo(0);
      await tester.pump();

      setState(() => tailHeight = 1800);
      await tester.pump();

      // A reader who scrolled up must stay where they are.
      expect(position.pixels, 0);
      expect(position.extentAfter, greaterThan(0));
    });
  });

  group('ChatScrollController post-generation hold', () {
    late ChatAutoFollowScrollController autoFollow;
    late ChatScrollController scrollCtrl;
    late StateSetter setState;
    late double tailHeight;

    Future<void> pumpHarness(WidgetTester tester) async {
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setter) {
            setState = setter;
            return _harness(controller: autoFollow, tailHeight: tailHeight);
          },
        ),
      );
      await tester.pump();
    }

    setUp(() {
      tailHeight = 600;
      autoFollow = ChatAutoFollowScrollController();
      scrollCtrl = ChatScrollController(
        scrollController: autoFollow,
        onStateChanged: () {},
        getAutoScrollEnabled: () => true,
        getAutoScrollIdleSeconds: () => 1,
      );
    });

    tearDown(() {
      scrollCtrl.dispose();
      autoFollow.dispose();
    });

    testWidgets('keeps the tail visible while the finished reply shrinks', (
      tester,
    ) async {
      await pumpHarness(tester);
      // Opening a conversation parks the list at the tail before streaming.
      autoFollow.jumpTo(autoFollow.position.maxScrollExtent);
      scrollCtrl.setAutoStickToBottom(true);
      await tester.pump();

      // Stream a few chunks: the pin, not an animation, keeps up with growth.
      for (var chunk = 0; chunk < 4; chunk++) {
        setState(() => tailHeight += 300);
        scrollCtrl.autoScrollToBottomIfNeeded(streaming: true);
        await tester.pump();
      }
      final position = autoFollow.position;
      expect(position.pixels, position.maxScrollExtent);

      // The reply finishes: thinking and tool cards fold, so the tail loses
      // most of its height in the frame right after the pin window opens.
      scrollCtrl.stickToBottomAfterGeneration();
      setState(() => tailHeight = 200);
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          position.pixels,
          lessThanOrEqualTo(position.maxScrollExtent + 0.5),
          reason: 'offset went past the end on frame $frame',
        );
      }

      expect(position.pixels, position.maxScrollExtent);
      expect(position.extentAfter, 0);
    });

    testWidgets('holds the layout pin for the settle window and then releases', (
      tester,
    ) async {
      await pumpHarness(tester);
      autoFollow.jumpTo(autoFollow.position.maxScrollExtent);
      await tester.pump();

      scrollCtrl.stickToBottomAfterGeneration();
      expect(autoFollow.hasActiveLayoutPositioningRequest, isTrue);

      await tester.pump(const Duration(milliseconds: 300));
      expect(autoFollow.hasActiveLayoutPositioningRequest, isTrue);

      await tester.pump(const Duration(milliseconds: 300));
      expect(autoFollow.hasActiveLayoutPositioningRequest, isFalse);
    });

    testWidgets('keeps pinning when a single frame grows past the snap band', (
      tester,
    ) async {
      await pumpHarness(tester);

      autoFollow.jumpTo(autoFollow.position.maxScrollExtent);
      await tester.pump();
      // Detached flag, but the reader is sitting on the tail.
      scrollCtrl.setAutoStickToBottom(false);
      expect(scrollCtrl.autoStickToBottom, isFalse);

      // One chunk taller than the 56 px snap band: the decision has to be
      // made against the pre-resize metrics, not the new max.
      setState(() => tailHeight += 400);
      await tester.pump();

      expect(autoFollow.position.pixels, autoFollow.position.maxScrollExtent);
    });

    testWidgets('a drag during the hold window releases it for good', (
      tester,
    ) async {
      await pumpHarness(tester);
      autoFollow.jumpTo(autoFollow.position.maxScrollExtent);
      scrollCtrl.setAutoStickToBottom(true);
      await tester.pump();
      expect(autoFollow.position.extentAfter, 0);

      scrollCtrl.stickToBottomAfterGeneration();
      expect(autoFollow.hasActiveLayoutPositioningRequest, isTrue);

      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pump();
      expect(autoFollow.hasActiveLayoutPositioningRequest, isFalse);

      // Well past the settle window, the user-scroll idle timer and the nav
      // button timer: the pin must not come back on its own.
      await tester.pump(const Duration(milliseconds: 2500));
      expect(autoFollow.position.pixels, lessThan(autoFollow.position.maxScrollExtent));
      expect(autoFollow.position.extentAfter, greaterThan(0));
    });

    testWidgets('does not pull back a reader who scrolled up', (tester) async {
      await pumpHarness(tester);

      // Reader detached from the tail and scrolled back to the top.
      scrollCtrl.setAutoStickToBottom(false);
      autoFollow.jumpTo(0);
      await tester.pump();
      expect(scrollCtrl.autoStickToBottom, isFalse);

      scrollCtrl.stickToBottomAfterGeneration();
      expect(autoFollow.hasActiveLayoutPositioningRequest, isFalse);

      setState(() => tailHeight = 1800);
      await tester.pump();
      expect(autoFollow.position.pixels, 0);
      expect(autoFollow.position.extentAfter, greaterThan(0));
    });
  });
}
