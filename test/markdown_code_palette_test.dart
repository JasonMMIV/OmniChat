import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/shared/markdown/markdown_code_palette.dart';

void main() {
  test('light palette maps semantic tokens onto the ColorScheme', () {
    const cs = ColorScheme.light();
    final theme = MarkdownCodePalette.themeFor(cs, isDark: false);

    expect(theme['root']?.backgroundColor, Colors.transparent);
    expect(theme['root']?.color, cs.onSurface);
    expect(theme['keyword']?.color, cs.primary);
    expect(theme['string']?.color, cs.tertiary);
    expect(theme['number']?.color, cs.secondary);
    expect(theme['literal']?.color, cs.secondary);
    expect(theme['comment']?.color, cs.onSurfaceVariant);
    expect(theme['comment']?.fontStyle, FontStyle.italic);
    expect(theme['tag']?.color, cs.error);
    expect(theme['link']?.color, cs.primary);
    expect(theme['link']?.decoration, TextDecoration.underline);
  });

  test('themeFor is cached by color signature and read-only', () {
    const cs = ColorScheme.light();
    final a = MarkdownCodePalette.themeFor(cs, isDark: false);
    final b = MarkdownCodePalette.themeFor(cs, isDark: false);

    expect(identical(a, b), isTrue);
    expect(
      () => a['keyword'] = const TextStyle(),
      throwsUnsupportedError,
    );
  });

  test('dark palette keeps transparent root and paired ink', () {
    const cs = ColorScheme.dark();
    final theme = MarkdownCodePalette.themeFor(cs, isDark: true);

    expect(theme['root']?.backgroundColor, Colors.transparent);
    expect(theme['root']?.color, cs.onSurface);
    expect(theme['keyword']?.color, cs.primary);
    expect(theme['comment']?.color, cs.onSurfaceVariant);
  });
}
