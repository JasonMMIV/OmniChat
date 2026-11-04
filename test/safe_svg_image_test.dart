import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/shared/widgets/safe_svg_image.dart';

void main() {
  test('detects SVG sources without treating ordinary images as SVG', () {
    expect(isSvgSource('https://example.com/a.svg'), isTrue);
    expect(isSvgSource('https://example.com/a.svg?x=1'), isTrue);
    expect(isSvgSource('data:image/svg+xml;base64,PHN2Zy8+'), isTrue);
    expect(isSvgSource('file:///tmp/a.SVG'), isTrue);
    expect(isSvgSource('https://example.com/a.png'), isFalse);
    expect(isSvgSource('https://example.com/svg'), isFalse);
  });

  test('rejects active or external-reference SVG features', () {
    expect(isSafeSvgText('<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>'), isTrue);
    expect(isSafeSvgText('<svg><defs><linearGradient id="g"/></defs><rect fill="url(#g)"/></svg>'), isTrue);
    expect(isSafeSvgText('<svg><rect fill="url(\'#g\')"/><rect fill="url( \"#g\" )"/></svg>'), isTrue);
    expect(isSafeSvgText('<svg><script>alert(1)</script></svg>'), isFalse);
    expect(isSafeSvgText('<svg><foreignObject/></svg>'), isFalse);
    expect(isSafeSvgText('<svg onload="alert(1)"/>'), isFalse);
    expect(isSafeSvgText('<svg><image href="https://evil.test/x.png"/></svg>'), isFalse);
    expect(isSafeSvgText('<svg><rect fill="url(https://evil.test/x)"/></svg>'), isFalse);
    expect(isSafeSvgText('<svg><rect fill="url(https://evil.test/x"/></svg>'), isFalse);
    // Root stroke-width must not be mistaken for the width attribute.
    expect(isSafeSvgText('<svg stroke-width="5000"><rect/></svg>'), isTrue);
    // Tag-like text in comments must not skew the element/depth count or
    // trigger the active-content checks.
    expect(isSafeSvgText('<svg><!-- <g><g><g> --><rect/></svg>'), isTrue);
    expect(isSafeSvgText('<svg><!-- <script> --><rect/></svg>'), isTrue);
  });

  test('rejects oversized root dimensions, viewBox, elements, and depth', () {
    expect(isSafeSvgText('<svg width="4097" height="10"/>'), isFalse);
    expect(isSafeSvgText('<svg viewBox="0 0 5000 5000"/>'), isFalse);
    expect(isSafeSvgText('<svg>${List.filled(5001, '<rect/>').join()}</svg>'), isFalse);
    final deep = '<svg>${List.filled(65, '<g>').join()}${List.filled(65, '</g>').join()}</svg>';
    expect(isSafeSvgText(deep), isFalse);
  });

  testWidgets('renders a base64 data SVG', (tester) async {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
        '<rect width="10" height="10" fill="red"/></svg>';
    final source = 'data:image/svg+xml;base64,${base64Encode(utf8.encode(svg))}';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SafeSvgImage(source: source)),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  testWidgets('does not render an active SVG payload', (tester) async {
    const svg = '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>';
    final source = 'data:image/svg+xml;base64,${base64Encode(utf8.encode(svg))}';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SafeSvgImage(source: source)),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(SvgPicture), findsNothing);
    expect(find.byIcon(Icons.broken_image), findsOneWidget);
  });

  testWidgets('uses the custom error builder for rejected SVG', (tester) async {
    const svg = '<svg><script>alert(1)</script></svg>';
    final source = 'data:image/svg+xml;base64,${base64Encode(utf8.encode(svg))}';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SafeSvgImage(source: source, errorBuilder: (_) => const Text('bad svg')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('bad svg'), findsOneWidget);
  });

  testWidgets('shows a broken image for malformed data', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SafeSvgImage(source: 'data:image/svg+xml,')),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.broken_image), findsOneWidget);
  });
}
