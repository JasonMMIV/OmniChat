import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/shared/markdown/markdown_alert.dart';
import 'package:OmniChat/shared/markdown/markdown_alert_style.dart';
import 'package:OmniChat/shared/markdown/markdown_surface_scope.dart';

enum _BubbleStyle { solid, frosted, defaultAssistant }

MarkdownSurface _surfaceFor(ColorScheme cs, _BubbleStyle style) {
  final base = MarkdownSurface.fromColorScheme(cs);
  switch (style) {
    case _BubbleStyle.solid:
      return base;
    case _BubbleStyle.frosted:
      return base.copyWith(isTranslucent: true);
    case _BubbleStyle.defaultAssistant:
      return base.copyWith(hasWallpaper: true);
  }
}

double _contrastRatio(Color foreground, Color background) {
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  final lighter = math.max(a, b);
  final darker = math.min(a, b);
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  test('surface ink meets 4.5:1 across 4 backgrounds x 3 bubbles x light/dark', () {
    const lightBackgrounds = <Color>[Color(0xFFFFFFFF), Color(0xFFE8EEF7), Color(0xFFF6E7D7), Color(0xFFE7F6EC)];
    const darkBackgrounds = <Color>[Color(0xFF121212), Color(0xFF1E2A38), Color(0xFF2A1F2D), Color(0xFF1F2A22)];

    var cases = 0;
    for (final brightness in Brightness.values) {
      final cs = ColorScheme.fromSeed(seedColor: const Color(0xFF4C6FFF), brightness: brightness);
      // Production constructs MarkdownSurface with cs.onSurface explicitly; keep
      // the factory equivalent under test so a future normalization cannot
      // silently make this matrix validate different ink.
      expect(MarkdownSurface.fromColorScheme(cs).onSurface, cs.onSurface);
      final backgrounds = brightness == Brightness.light ? lightBackgrounds : darkBackgrounds;
      // Mirrors ChatMessageWidget: the frosted bubble is a 66% white/near-black
      // layer over the wallpaper, while the ink stays cs.onSurface for every
      // style. Only the effective background and shadow policy vary.
      final frostedBase = brightness == Brightness.light ? Colors.white : const Color(0xFF1C1C1E);
      for (final wallpaper in backgrounds) {
        for (final style in _BubbleStyle.values) {
          final surface = _surfaceFor(cs, style);
          final background = switch (style) {
            _BubbleStyle.solid => cs.surface,
            _BubbleStyle.frosted => Color.alphaBlend(frostedBase.withValues(alpha: 0.66), wallpaper),
            _BubbleStyle.defaultAssistant => wallpaper,
          };

          final ratio = _contrastRatio(surface.onSurface, background);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason:
                '${brightness.name}/$style over #${wallpaper.toARGB32().toRadixString(16)} '
                'body ink was ${ratio.toStringAsFixed(2)}:1',
          );

          final secondaryRatio = _contrastRatio(surface.onSurfaceVariant, background);
          expect(
            secondaryRatio,
            greaterThanOrEqualTo(3.0),
            reason:
                '${brightness.name}/$style over #${wallpaper.toARGB32().toRadixString(16)} '
                'secondary ink was ${secondaryRatio.toStringAsFixed(2)}:1',
          );

          final wantsShadow = style == _BubbleStyle.frosted || style == _BubbleStyle.defaultAssistant;
          expect(surface.bodyTextShadows.isNotEmpty, wantsShadow, reason: '${brightness.name}/$style shadow policy');
          cases++;
        }
      }
    }
    expect(cases, 24);
  });

  test('assistant wallpaper scrim keeps body ink at 4.5:1', () {
    const lightBackgrounds = <Color>[Color(0xFFFFFFFF), Color(0xFFE8EEF7), Color(0xFFF6E7D7), Color(0xFFE7F6EC)];
    const darkBackgrounds = <Color>[Color(0xFF121212), Color(0xFF1E2A38), Color(0xFF2A1F2D), Color(0xFF1F2A22)];

    var cases = 0;
    for (final brightness in Brightness.values) {
      final cs = ColorScheme.fromSeed(seedColor: const Color(0xFF4C6FFF), brightness: brightness);
      final scrim = assistantWallpaperScrimColor(cs);
      final backgrounds = brightness == Brightness.light ? lightBackgrounds : darkBackgrounds;
      for (final wallpaper in backgrounds) {
        final effective = Color.alphaBlend(scrim, wallpaper);
        final ratio = _contrastRatio(cs.onSurface, effective);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason:
              '${brightness.name} scrim over #${wallpaper.toARGB32().toRadixString(16)} was '
              '${ratio.toStringAsFixed(2)}:1',
        );
        cases++;
      }
    }
    expect(cases, 8);
  });

  test('alert titles meet 4.5:1 on their tinted cards', () {
    var cases = 0;
    for (final brightness in Brightness.values) {
      final cs = ColorScheme.fromSeed(seedColor: const Color(0xFF4C6FFF), brightness: brightness);
      for (final kind in MarkdownAlertKind.values) {
        final colors = markdownAlertColors(kind, cs);
        final background = Color.alphaBlend(colors.background(isDark: brightness == Brightness.dark), cs.surface);
        final ratio = _contrastRatio(colors.title, background);
        expect(ratio, greaterThanOrEqualTo(4.5), reason: '${brightness.name}/$kind was ${ratio.toStringAsFixed(2)}:1');
        cases++;
      }
    }
    expect(cases, 10);
  });
}
