import 'package:OmniChat/desktop/desktop_context_menu.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const String label = '顯示所在資料夾';

  List<DesktopContextMenuItem> buildItems() => const <DesktopContextMenuItem>[
    DesktopContextMenuItem(icon: Lucide.FolderOpen, label: label),
    DesktopContextMenuItem(icon: Lucide.ExternalLink, label: '外部開啟'),
    DesktopContextMenuItem(icon: Lucide.Download, label: '下載'),
  ];

  Future<void> openMenu(WidgetTester tester, double textScale) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDesktopContextMenuAt(
                  context,
                  globalPosition: const Offset(400, 300),
                  items: buildItems(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  // A single-line label occupies its full natural width; a wrapped label is
  // capped by the menu's text column and loses width on every line.
  double labelTextWidth(WidgetTester tester) =>
      tester.getSize(find.text(label)).width;

  testWidgets('menu keeps a long CJK label on one line at default text scale', (
    tester,
  ) async {
    await openMenu(tester, 1.0);
    expect(find.text(label), findsOneWidget);
    expect(labelTextWidth(tester), greaterThan(95));
  });

  testWidgets('menu width follows the system text scale (133%)', (tester) async {
    await openMenu(tester, 1.33);
    expect(find.text(label), findsOneWidget);
    // One line at 133% needs roughly 135px; the old estimate capped the menu
    // at 160px, leaving only ~108px for the label and wrapping it in two.
    expect(labelTextWidth(tester), greaterThan(120));
    final menuWidth = tester
        .getSize(
          find
              .ancestor(
                of: find.text(label),
                matching: find.byType(IntrinsicWidth),
              )
              .first,
        )
        .width;
    expect(menuWidth, greaterThan(160));
  });
}
