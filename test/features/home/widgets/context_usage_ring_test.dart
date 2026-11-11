// ContextUsageRing / ContextUsageMenuHeader widget tests
// (docs/context_usage_ring_plan.md v2).
//
// Pins: no from-zero flash on rebuild, animated updates, clamping, the
// 70%/90% color bands, the header's show/hide + over-budget badge rules, and
// the empty-ring fallback while the window is unknown.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/features/home/services/context_usage_service.dart';
import 'package:OmniChat/features/home/widgets/context_usage_ring.dart';

Widget wrapWidget(Widget child) {
  return MaterialApp(home: Scaffold(body: Center(child: child)));
}

double displayedRatio(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byType(ContextUsageRing),
      matching: find.byType(CustomPaint),
    ),
  );
  return (paint.painter as ContextUsageRingPainter).ratio;
}

void main() {
  testWidgets('first paint shows the target ratio (no from-zero animation)',
      (tester) async {
    await tester.pumpWidget(wrapWidget(const ContextUsageRing(ratio: 0.2)));
    expect(displayedRatio(tester), closeTo(0.2, 0.0001));
  });

  testWidgets('ratio updates animate from the displayed value, not zero',
      (tester) async {
    await tester.pumpWidget(wrapWidget(const ContextUsageRing(ratio: 0.2)));
    await tester.pumpAndSettle();

    // Same position + type → State is preserved → didUpdateWidget animates
    // from 0.2 to 0.9 instead of restarting from zero.
    await tester.pumpWidget(wrapWidget(const ContextUsageRing(ratio: 0.9)));
    await tester.pump(const Duration(milliseconds: 100));
    final mid = displayedRatio(tester);
    expect(mid, greaterThan(0.2));
    expect(mid, lessThan(0.9));

    await tester.pumpAndSettle();
    expect(displayedRatio(tester), closeTo(0.9, 0.0001));
  });

  testWidgets('ratio is clamped to 0..1', (tester) async {
    await tester.pumpWidget(wrapWidget(const ContextUsageRing(ratio: 1.5)));
    expect(displayedRatio(tester), 1.0);
  });

  testWidgets('color bands switch at 70% / 90%', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) {
          ctx = context;
          return const SizedBox.shrink();
        },
      ),
    ));
    final cs = Theme.of(ctx).colorScheme;
    expect(contextUsageColorForRatio(ctx, 0.699), cs.primary);
    expect(contextUsageColorForRatio(ctx, 0.70), Colors.orange.shade600);
    expect(contextUsageColorForRatio(ctx, 0.899), Colors.orange.shade600);
    expect(contextUsageColorForRatio(ctx, 0.90), cs.error);
  });

  testWidgets('header hides entirely when there is no snapshot',
      (tester) async {
    final notifier = ValueNotifier<ContextUsageSnapshot?>(null);
    await tester.pumpWidget(wrapWidget(
      ContextUsageMenuHeader(listenable: notifier, padding: EdgeInsets.zero),
    ));
    expect(find.textContaining('Token'), findsNothing);
  });

  testWidgets('header shows used / ... without a percentage while unknown',
      (tester) async {
    final notifier = ValueNotifier<ContextUsageSnapshot?>(
      const ContextUsageSnapshot(
        usedTokens: 6600,
        maxTokens: null,
        measured: true,
        estimated: true,
      ),
    );
    await tester.pumpWidget(wrapWidget(
      ContextUsageMenuHeader(listenable: notifier, padding: EdgeInsets.zero),
    ));
    expect(find.text('6.6k / ... Token'), findsOneWidget);
    expect(find.text('≈'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('header gives the usage label the full remaining width',
      (tester) async {
    final notifier = ValueNotifier<ContextUsageSnapshot?>(
      const ContextUsageSnapshot(
        usedTokens: 6600,
        maxTokens: 512000,
        measured: true,
        estimated: false,
      ),
    );
    await tester.pumpWidget(wrapWidget(
      SizedBox(
        width: 240,
        child: ContextUsageMenuHeader(listenable: notifier),
      ),
    ));
    await tester.pump();

    final textFinder = find.text('6.6k / 512.0k Token');
    expect(textFinder, findsOneWidget);
    expect(find.text('1%'), findsOneWidget);
    // The label must own all remaining width; a Spacer flex sibling would
    // split it in half and ellipsize the denominator on narrow menus.
    expect(
      find.ancestor(of: textFinder, matching: find.byType(Expanded)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ContextUsageMenuHeader),
        matching: find.byType(Spacer),
      ),
      findsNothing,
    );
    notifier.dispose();
  });

  testWidgets('header shows used/max + percent, hides ≈ when measured',
      (tester) async {
    final notifier = ValueNotifier<ContextUsageSnapshot?>(
      const ContextUsageSnapshot(
        usedTokens: 12345,
        maxTokens: 200000,
        measured: true,
        estimated: false,
      ),
    );
    await tester.pumpWidget(wrapWidget(
      ContextUsageMenuHeader(listenable: notifier, padding: EdgeInsets.zero),
    ));
    expect(find.text('12.3k / 200.0k Token'), findsOneWidget);
    expect(find.text('6%'), findsOneWidget);
    expect(find.text('≈'), findsNothing);
  });

  testWidgets('header shows ≈ and the over-budget percentage', (tester) async {
    final notifier = ValueNotifier<ContextUsageSnapshot?>(
      const ContextUsageSnapshot(
        usedTokens: 250000,
        maxTokens: 200000,
        measured: true,
        estimated: true,
      ),
    );
    await tester.pumpWidget(wrapWidget(
      ContextUsageMenuHeader(listenable: notifier, padding: EdgeInsets.zero),
    ));
    expect(find.text('250.0k / 200.0k Token'), findsOneWidget);
    expect(find.text('125%'), findsOneWidget);
    expect(find.text('≈'), findsOneWidget);
  });

  testWidgets('header updates live when the notifier changes', (tester) async {
    final notifier = ValueNotifier<ContextUsageSnapshot?>(null);
    await tester.pumpWidget(wrapWidget(
      ContextUsageMenuHeader(listenable: notifier, padding: EdgeInsets.zero),
    ));
    expect(find.textContaining('Token'), findsNothing);

    notifier.value = const ContextUsageSnapshot(
      usedTokens: 12345,
      maxTokens: 200000,
      measured: true,
      estimated: false,
    );
    await tester.pumpAndSettle();
    expect(find.text('12.3k / 200.0k Token'), findsOneWidget);
  });

  testWidgets('context button keeps an empty ring for null/unknown usage',
      (tester) async {
    final notifier = ValueNotifier<ContextUsageSnapshot?>(null);
    await tester.pumpWidget(wrapWidget(
      ContextUsageButtonIcon(
        usage: notifier,
        loading: false,
        color: Colors.black,
      ),
    ));
    expect(find.byType(ContextUsageRing), findsOneWidget);
    expect(displayedRatio(tester), 0.0);

    notifier.value = const ContextUsageSnapshot(
      usedTokens: 6600,
      maxTokens: null,
      measured: true,
      estimated: false,
    );
    await tester.pumpAndSettle();
    expect(find.byType(ContextUsageRing), findsOneWidget);
    expect(displayedRatio(tester), 0.0);
  });
}
