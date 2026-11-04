import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/atom-one-dark-reasonable.dart';
import 'package:flutter_highlight/themes/github.dart';

/// Builds a code-highlight token palette from the app [ColorScheme].
///
/// The proven GitHub/Atom One Dark maps are used as the base (so uncommon
/// token classes keep sensible styling), while the semantic classes are
/// re-tinted with Material color-scheme tokens. That keeps code blocks in
/// step with light/dark themes and custom wallpapers without inventing a new
/// syntax palette from scratch.
class MarkdownCodePalette {
  const MarkdownCodePalette._();

  static final Map<String, Map<String, TextStyle>> _themedCache =
      <String, Map<String, TextStyle>>{};
  static const int _themedCacheMaxEntries = 8;

  static Map<String, TextStyle> themeFor(
    ColorScheme cs, {
    required bool isDark,
  }) {
    final key = _signature(cs, isDark);
    final cached = _themedCache[key];
    if (cached != null) return cached;

    final theme = Map<String, TextStyle>.unmodifiable(
      _buildTheme(cs, isDark: isDark),
    );
    _themedCache[key] = theme;
    while (_themedCache.length > _themedCacheMaxEntries) {
      _themedCache.remove(_themedCache.keys.first);
    }
    return theme;
  }

  static String _signature(ColorScheme cs, bool isDark) {
    return '${isDark ? 1 : 0}|${cs.primary.toARGB32()}|'
        '${cs.secondary.toARGB32()}|${cs.tertiary.toARGB32()}|'
        '${cs.surface.toARGB32()}|${cs.onSurface.toARGB32()}|'
        '${cs.onSurfaceVariant.toARGB32()}|${cs.error.toARGB32()}';
  }

  static Map<String, TextStyle> _buildTheme(
    ColorScheme cs, {
    required bool isDark,
  }) {
    final Map<String, TextStyle> base =
        isDark ? atomOneDarkReasonableTheme : githubTheme;
    final palette = Map<String, TextStyle>.from(base);

    TextStyle merge(String className, TextStyle style) {
      return (base[className] ?? const TextStyle()).merge(style);
    }

    palette['root'] = (base['root'] ?? const TextStyle()).copyWith(
      backgroundColor: Colors.transparent,
      color: cs.onSurface,
    );
    palette['keyword'] = merge('keyword', TextStyle(color: cs.primary));
    palette['string'] = merge('string', TextStyle(color: cs.tertiary));
    palette['number'] = merge('number', TextStyle(color: cs.secondary));
    palette['literal'] = merge('literal', TextStyle(color: cs.secondary));
    palette['comment'] = merge(
      'comment',
      TextStyle(color: cs.onSurfaceVariant, fontStyle: FontStyle.italic),
    );
    palette['quote'] = merge(
      'quote',
      TextStyle(color: cs.onSurfaceVariant, fontStyle: FontStyle.italic),
    );
    palette['title'] = merge(
      'title',
      TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
    );
    palette['section'] = merge(
      'section',
      TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
    );
    palette['attr'] = merge('attr', TextStyle(color: cs.tertiary));
    palette['attribute'] = merge('attribute', TextStyle(color: cs.tertiary));
    palette['variable'] = merge('variable', TextStyle(color: cs.tertiary));
    palette['type'] = merge('type', TextStyle(color: cs.primary));
    palette['built_in'] = merge('built_in', TextStyle(color: cs.primary));
    palette['tag'] = merge('tag', TextStyle(color: cs.error));
    palette['meta'] = merge('meta', TextStyle(color: cs.onSurfaceVariant));
    palette['link'] = merge(
      'link',
      TextStyle(color: cs.primary, decoration: TextDecoration.underline),
    );
    palette['symbol'] = merge('symbol', TextStyle(color: cs.secondary));
    palette['bullet'] = merge('bullet', TextStyle(color: cs.primary));
    palette['code'] = merge('code', TextStyle(color: cs.tertiary));
    palette['emphasis'] = merge(
      'emphasis',
      const TextStyle(fontStyle: FontStyle.italic),
    );
    palette['strong'] = merge(
      'strong',
      const TextStyle(fontWeight: FontWeight.bold),
    );
    palette['addition'] = merge('addition', TextStyle(color: cs.tertiary));
    palette['deletion'] = merge('deletion', TextStyle(color: cs.error));
    return palette;
  }
}
