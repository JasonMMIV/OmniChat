import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/shared/widgets/hover_reveal.dart';

double _actionsOpacity(WidgetTester tester) {
  return tester
      .widget<AnimatedOpacity>(find.descendant(
        of: find.byKey(const ValueKey('actions')),
        matching: find.byType(AnimatedOpacity),
      ))
      .opacity;
}

void main() {
  testWidgets('keyboard focus inside the action buttons reveals them', (
    tester,
  ) async {
    final actionNode = FocusNode();
    final outsideNode = FocusNode();
    addTearDown(actionNode.dispose);
    addTearDown(outsideNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              HoverReveal(
                child: RevealableActions(
                  key: const ValueKey('actions'),
                  child: TextButton(
                    focusNode: actionNode,
                    onPressed: () {},
                    child: const Text('Copy'),
                  ),
                ),
              ),
              TextButton(
                focusNode: outsideNode,
                onPressed: () {},
                child: const Text('Outside'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_actionsOpacity(tester), 0);

    actionNode.requestFocus();
    // Focus is applied on the next frame, then the reveal's setState needs
    // one more frame to rebuild.
    await tester.pumpAndSettle();
    expect(_actionsOpacity(tester), 1);

    outsideNode.requestFocus();
    await tester.pumpAndSettle();
    expect(_actionsOpacity(tester), 0);
  });

  testWidgets('a touch tap reveals the actions and hides them again', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: HoverReveal(
              child: SizedBox(
                width: 240,
                height: 120,
                child: RevealableActions(
                  key: ValueKey('actions'),
                  child: Text('Actions'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_actionsOpacity(tester), 0);

    await tester.tapAt(tester.getCenter(find.byType(HoverReveal)));
    await tester.pump();
    expect(_actionsOpacity(tester), 1);

    await tester.pump(const Duration(seconds: 4));
    expect(_actionsOpacity(tester), 0);
  });

  testWidgets('tapping outside hides a touch-revealed toolbar', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: HoverReveal(
              child: SizedBox(
                width: 240,
                height: 120,
                child: RevealableActions(
                  key: ValueKey('actions'),
                  child: Text('Actions'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final center = tester.getCenter(find.byType(HoverReveal));
    await tester.tapAt(center);
    await tester.pump();
    expect(_actionsOpacity(tester), 1);

    // Tapping inside the block keeps the reveal (and restarts the timer).
    await tester.tapAt(center + const Offset(20, 0));
    await tester.pump();
    expect(_actionsOpacity(tester), 1);

    // Tapping outside dismisses it immediately instead of waiting 3 seconds.
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(_actionsOpacity(tester), 0);

    // The cancelled auto-hide timer must not fire again afterwards.
    await tester.pump(const Duration(seconds: 4));
    expect(_actionsOpacity(tester), 0);
  });

  testWidgets('accessible navigation does not pin the actions open', (
    tester,
  ) async {
    // Android reports accessibleNavigation=true for any running accessibility
    // service, not only screen readers, so it must not force the toolbar open.
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(accessibleNavigation: true),
            child: const Scaffold(
              body: Center(
                child: HoverReveal(
                  child: SizedBox(
                    width: 240,
                    height: 120,
                    child: RevealableActions(
                      key: ValueKey('actions'),
                      child: Text('Actions'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_actionsOpacity(tester), 0);

    await tester.tapAt(tester.getCenter(find.byType(HoverReveal)));
    await tester.pump();
    expect(_actionsOpacity(tester), 1);

    await tester.pump(const Duration(seconds: 4));
    expect(_actionsOpacity(tester), 0);
  });

  testWidgets('hidden actions stay reachable when a screen reader is running', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    Future<void> pumpWith({required bool accessibleNavigation}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(accessibleNavigation: accessibleNavigation),
              child: const Scaffold(
                body: Center(
                  child: HoverReveal(
                    child: RevealableActions(
                      key: ValueKey('actions'),
                      child: TextButton(onPressed: _noop, child: Text('Copy')),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await pumpWith(accessibleNavigation: false);
    expect(_actionsOpacity(tester), 0);
    expect(find.bySemanticsLabel('Copy'), findsNothing);

    await pumpWith(accessibleNavigation: true);
    expect(_actionsOpacity(tester), 0);
    expect(find.bySemanticsLabel('Copy'), findsOneWidget);

    semantics.dispose();
  });
}

void _noop() {}
