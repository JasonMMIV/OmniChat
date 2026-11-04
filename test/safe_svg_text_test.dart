import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/shared/widgets/safe_svg_text.dart';

void main() {
  testWidgets('renders a safe inline SVG with currentColor', (tester) async {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24">'
        '<rect width="24" height="24" fill="currentColor"/></svg>';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SafeSvgText(svg: svg, currentColor: Colors.red),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    final picture = tester.widget<SvgPicture>(find.byType(SvgPicture));
    final loader = picture.bytesLoader as SvgStringLoader;
    expect(loader.theme?.currentColor, Colors.red);
  });

  testWidgets('falls back to source when parsing fails', (tester) async {
    const svg = '<svg xmlns="http://www.w3.org/2000/svg"><rect></svg>';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SafeSvgText(svg: svg)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(tester.takeException(), isNull);
    final source = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
        .join('\n');
    expect(source, contains('<svg'));
  });

  testWidgets('rejects active inline SVG content', (tester) async {
    const svg = '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SafeSvgText(svg: svg)),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(SvgPicture), findsNothing);
    expect(find.byIcon(Icons.broken_image), findsOneWidget);
  });

  testWidgets('rejects oversized inline SVG dimensions', (tester) async {
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="4097" height="24"/>';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SafeSvgText(svg: svg)),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(SvgPicture), findsNothing);
    expect(find.byIcon(Icons.broken_image), findsOneWidget);
  });
}
