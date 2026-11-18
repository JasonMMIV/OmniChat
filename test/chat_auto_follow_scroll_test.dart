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
      controller.shouldAutoFollow = () => true;
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
      controller.shouldAutoFollow = () => true;
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
        controller.shouldAutoFollow = () => true;
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
      controller.shouldAutoFollow = () => false;
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
}
