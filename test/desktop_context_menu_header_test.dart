// Desktop anchored menu header tests (docs/context_usage_ring_plan.md v2).
//
// The header renders above the items with a hairline divider, and the
// minMenuWidth override widens the menu so a wide header never overflows.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/desktop/desktop_context_menu.dart';
import 'package:OmniChat/features/home/services/context_usage_service.dart';
import 'package:OmniChat/features/home/widgets/context_usage_ring.dart';

Future<void> pumpAnchor(WidgetTester tester, GlobalKey anchorKey) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(key: anchorKey, width: 32, height: 32),
      ),
    ),
  ));
}

void main() {
  testWidgets(
      'anchored menu renders the header above the items and honors minMenuWidth',
      (tester) async {
    final anchorKey = GlobalKey();
    await pumpAnchor(tester, anchorKey);
    final scaffoldContext = tester.element(find.byType(Scaffold));

    unawaited(showDesktopAnchoredMenu(
      scaffoldContext,
      anchorKey: anchorKey,
      header: const Text('HEADER'),
      headerHeight: 40,
      minMenuWidth: 240,
      items: const [
        DesktopContextMenuItem(icon: Icons.copy, label: 'Item A'),
        DesktopContextMenuItem(label: 'Item B'),
      ],
    ));
    await tester.pumpAndSettle();

    expect(find.text('HEADER'), findsOneWidget);
    expect(find.text('Item A'), findsOneWidget);
    expect(find.text('Item B'), findsOneWidget);
    final constrained =
        tester.widgetList<ConstrainedBox>(find.byType(ConstrainedBox));
    expect(
      constrained.any((b) =>
          b.constraints.minWidth == 240 && b.constraints.maxWidth == 240),
      isTrue,
    );

    Navigator.of(scaffoldContext).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('anchored menu without a header keeps the item-only layout',
      (tester) async {
    final anchorKey = GlobalKey();
    await pumpAnchor(tester, anchorKey);
    final scaffoldContext = tester.element(find.byType(Scaffold));

    unawaited(showDesktopAnchoredMenu(
      scaffoldContext,
      anchorKey: anchorKey,
      items: const [
        DesktopContextMenuItem(icon: Icons.copy, label: 'Item A'),
        DesktopContextMenuItem(label: 'Item B'),
      ],
    ));
    await tester.pumpAndSettle();

    expect(find.text('HEADER'), findsNothing);
    expect(find.text('Item A'), findsOneWidget);
    expect(find.text('Item B'), findsOneWidget);

    Navigator.of(scaffoldContext).pop();
    await tester.pumpAndSettle();
  });

  testWidgets(
      'usage header renders used / ... without a percent while unknown',
      (tester) async {
    final anchorKey = GlobalKey();
    await pumpAnchor(tester, anchorKey);
    final scaffoldContext = tester.element(find.byType(Scaffold));
    final usage = ValueNotifier<ContextUsageSnapshot?>(
      const ContextUsageSnapshot(
        usedTokens: 6600,
        maxTokens: null,
        measured: true,
        estimated: false,
      ),
    );

    unawaited(showDesktopAnchoredMenu(
      scaffoldContext,
      anchorKey: anchorKey,
      header: ContextUsageMenuHeader(listenable: usage, showDivider: true),
      minMenuWidth: 240,
      items: const [
        DesktopContextMenuItem(icon: Icons.copy, label: 'Item A'),
      ],
    ));
    await tester.pumpAndSettle();

    expect(find.text('6.6k / ... Token'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    expect(find.text('Item A'), findsOneWidget);

    Navigator.of(scaffoldContext).pop();
    await tester.pumpAndSettle();
  });
}
