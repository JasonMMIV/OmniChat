import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/shared/markdown/markdown_inline_style.dart';

void main() {
  const base = TextStyle(fontSize: 15, color: Color(0xFF111111));

  test('parses CSS colors', () {
    expect(parseCssColor('#f00'), const Color(0xFFFF0000));
    expect(parseCssColor('#ff0000'), const Color(0xFFFF0000));
    expect(parseCssColor('#ff000080'), const Color(0x80FF0000));
    expect(parseCssColor('rgb(255, 0, 0)'), const Color(0xFFFF0000));
    expect(parseCssColor('rgba(255, 0, 0, 0.5)'), const Color(0x80FF0000));
    expect(parseCssColor('red'), const Color(0xFFFF0000));
    expect(parseCssColor('transparent'), const Color(0x00000000));
    expect(parseCssColor('url(https://evil.test/x)'), isNull);
    expect(parseCssColor('var(--accent)'), isNull);
    expect(parseCssColor('#12345'), isNull);
  });

  test('applies only the safe CSS subset', () {
    final style = applyInlineCssStyle(
      base,
      'color: #00ff00; background-color: #0000ff; font-weight: 700; '
      'font-style: italic; text-decoration: underline line-through; '
      'position: fixed; background-image: url(https://evil.test/x)',
      surface: const Color(0xFF202020),
    );

    expect(style, isNotNull);
    expect(style!.color, const Color(0xFF00FF00));
    expect(style.backgroundColor, const Color(0xFF0000FF));
    expect(style.fontWeight, FontWeight.w700);
    expect(style.fontStyle, FontStyle.italic);
    expect(style.decoration, TextDecoration.combine(const [TextDecoration.underline, TextDecoration.lineThrough]));
  });

  test('composites translucent backgrounds and ignores invalid values', () {
    final style = applyInlineCssStyle(
      base,
      'background-color: rgba(255, 0, 0, 0.5); color: not-a-color; font-weight: 950',
      surface: const Color(0xFF000000),
    );

    expect(style, isNotNull);
    expect(style!.backgroundColor, const Color(0xFF800000));
    expect(style.color, base.color);
    expect(style.fontWeight, base.fontWeight);
  });

  test('applies font color only', () {
    expect(applyFontColor(base, '#123456')?.color, const Color(0xFF123456));
    expect(applyFontColor(base, 'javascript:alert(1)'), isNull);
    expect(applyFontColor(base, 'transparent'), isNull);
  });

  test('raises low-contrast text toward the paired ink', () {
    final style = applyInlineCssStyle(
      base,
      'color: #ffffff',
      surface: const Color(0xFFFFFFFF),
      ink: const Color(0xFF111111),
    );

    expect(style, isNotNull);
    expect(style!.color, isNot(const Color(0xFFFFFFFF)));
    final foreground = style.color!.computeLuminance();
    final background = const Color(0xFFFFFFFF).computeLuminance();
    final ratio = (math.max(foreground, background) + 0.05) / (math.min(foreground, background) + 0.05);
    expect(ratio, greaterThanOrEqualTo(4.5));
  });
}
