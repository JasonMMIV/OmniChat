import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/features/home/widgets/scroll_nav_buttons.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';

void main() {
  testWidgets('renders five buttons with the mini-map in the middle', (
    tester,
  ) async {
    var opened = 0;
    final miniMapKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScrollNavButtonsPanel(
            visible: true,
            miniMapKey: miniMapKey,
            miniMapTooltip: 'Minimap',
            onOpenMiniMap: () => opened++,
            onScrollToTop: () {},
            onPreviousMessage: () {},
            onNextMessage: () {},
            onScrollToBottom: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final icons = tester
        .widgetList<Icon>(find.byType(Icon))
        .map((icon) => icon.icon)
        .toList();
    expect(icons, [
      Lucide.ChevronsUp,
      Lucide.ChevronUp,
      Lucide.TableOfContents,
      Lucide.ChevronDown,
      Lucide.ChevronsDown,
    ]);

    expect(find.byKey(miniMapKey), findsOneWidget);
    expect(find.byTooltip('Minimap'), findsOneWidget);

    await tester.tap(find.byKey(miniMapKey));
    expect(opened, 1);
  });
}
