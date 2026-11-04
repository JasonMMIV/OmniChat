import 'package:flutter/material.dart';

/// Applies a deliberately small CSS subset from inline HTML `style` attributes.
///
/// Supported: `color`, `background-color`, `font-weight`, `font-style`, and
/// `text-decoration` (`underline`, `line-through`, `overline`). Unknown
/// properties and values are ignored; no layout/positioning properties are
/// accepted.
TextStyle? applyInlineCssStyle(TextStyle base, String? declarations, {Color? surface, Color? ink}) {
  if (declarations == null || declarations.trim().isEmpty) return null;

  var style = base;
  var changed = false;

  for (final declaration in declarations.split(';')) {
    final colon = declaration.indexOf(':');
    if (colon <= 0) continue;
    final property = declaration.substring(0, colon).trim().toLowerCase();
    final rawValue = declaration.substring(colon + 1).trim();
    if (rawValue.isEmpty) continue;

    switch (property) {
      case 'color':
        final color = parseCssColor(rawValue);
        if (color != null && color.a > 0) {
          style = style.copyWith(
            color: _readableColor(color, surface: surface, ink: ink),
          );
          changed = true;
        }
      case 'background-color':
        final color = parseCssColor(rawValue);
        if (color != null && color.a > 0) {
          style = style.copyWith(backgroundColor: surface != null ? Color.alphaBlend(color, surface) : color);
          changed = true;
        }
      case 'font-weight':
        final weight = _parseFontWeight(rawValue);
        if (weight != null) {
          style = style.copyWith(fontWeight: weight);
          changed = true;
        }
      case 'font-style':
        final fontStyle = _parseFontStyle(rawValue);
        if (fontStyle != null) {
          style = style.copyWith(fontStyle: fontStyle);
          changed = true;
        }
      case 'text-decoration':
        final decoration = _parseTextDecoration(rawValue);
        if (decoration != null) {
          style = style.copyWith(decoration: decoration);
          changed = true;
        }
    }
  }

  return changed ? style : null;
}

/// Applies `<font color="...">`; other font attributes are intentionally
/// ignored.
TextStyle? applyFontColor(TextStyle base, String? value, {Color? surface, Color? ink}) {
  final color = parseCssColor(value);
  if (color == null || color.a == 0) return null;
  return base.copyWith(
    color: _readableColor(color, surface: surface, ink: ink),
  );
}

Color _readableColor(Color color, {Color? surface, Color? ink}) {
  if (surface == null) return color;
  final opaque = color.withValues(alpha: 1);
  if (_contrastRatio(opaque, surface) >= 4.5) return opaque;
  final target = ink ?? (surface.computeLuminance() > 0.5 ? Colors.black : Colors.white);
  for (var step = 1; step <= 10; step++) {
    final candidate = Color.lerp(opaque, target, step / 10)!;
    if (_contrastRatio(candidate, surface) >= 4.5) return candidate;
  }
  return target;
}

double _contrastRatio(Color foreground, Color background) {
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  final lighter = a > b ? a : b;
  final darker = a > b ? b : a;
  return (lighter + 0.05) / (darker + 0.05);
}

/// Parses common CSS color forms without accepting `url()`, `var()`, or
/// `expression()`.
Color? parseCssColor(String? raw) {
  final value = raw?.trim().toLowerCase();
  if (value == null || value.isEmpty) return null;

  const named = <String, int>{
    'black': 0xFF000000,
    'white': 0xFFFFFFFF,
    'red': 0xFFFF0000,
    'green': 0xFF008000,
    'blue': 0xFF0000FF,
    'yellow': 0xFFFFFF00,
    'orange': 0xFFFFA500,
    'purple': 0xFF800080,
    'pink': 0xFFFFC0CB,
    'gray': 0xFF808080,
    'grey': 0xFF808080,
    'transparent': 0x00000000,
  };
  final namedColor = named[value];
  if (namedColor != null) return Color(namedColor);

  if (value.startsWith('#')) {
    var hex = value.substring(1);
    if (hex.length == 3 || hex.length == 4) {
      hex = hex.split('').map((char) => '$char$char').join();
    }
    if (hex.length == 6) {
      final rgb = int.tryParse(hex, radix: 16);
      if (rgb == null) return null;
      return Color(0xFF000000 | rgb);
    }
    if (hex.length == 8) {
      final rgba = int.tryParse(hex, radix: 16);
      if (rgba == null) return null;
      final rgb = rgba >> 8;
      final alpha = rgba & 0xFF;
      return Color((alpha << 24) | rgb);
    }
    return null;
  }

  final rgb = RegExp(
    r'^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})(?:\s*,\s*([\d.]+))?\s*\)$',
  ).firstMatch(value);
  if (rgb == null) return null;
  final red = int.tryParse(rgb.group(1) ?? '');
  final green = int.tryParse(rgb.group(2) ?? '');
  final blue = int.tryParse(rgb.group(3) ?? '');
  if (red == null || green == null || blue == null) return null;
  if (red > 255 || green > 255 || blue > 255) return null;
  final alpha = rgb.group(4) == null ? 1.0 : double.tryParse(rgb.group(4)!);
  if (alpha == null || alpha < 0 || alpha > 1) return null;
  return Color.fromARGB((alpha * 255).round(), red, green, blue);
}

FontWeight? _parseFontWeight(String raw) {
  final value = raw.trim().toLowerCase();
  if (value == 'normal') return FontWeight.w400;
  if (value == 'bold' || value == 'bolder') return FontWeight.w700;
  if (value == 'lighter') return FontWeight.w300;
  final numeric = int.tryParse(value);
  if (numeric == null || numeric < 100 || numeric > 900) return null;
  final normalized = (numeric ~/ 100) * 100;
  return switch (normalized) {
    100 => FontWeight.w100,
    200 => FontWeight.w200,
    300 => FontWeight.w300,
    400 => FontWeight.w400,
    500 => FontWeight.w500,
    600 => FontWeight.w600,
    700 => FontWeight.w700,
    800 => FontWeight.w800,
    _ => FontWeight.w900,
  };
}

FontStyle? _parseFontStyle(String raw) {
  final value = raw.trim().toLowerCase();
  if (value == 'italic' || value == 'oblique') return FontStyle.italic;
  if (value == 'normal') return FontStyle.normal;
  return null;
}

TextDecoration? _parseTextDecoration(String raw) {
  final tokens = raw.toLowerCase().split(RegExp(r'\s+')).where((token) => token.isNotEmpty).toSet();
  if (tokens.contains('none')) return TextDecoration.none;
  final decorations = <TextDecoration>[
    if (tokens.contains('underline')) TextDecoration.underline,
    if (tokens.contains('line-through')) TextDecoration.lineThrough,
    if (tokens.contains('overline')) TextDecoration.overline,
  ];
  return decorations.isEmpty ? null : TextDecoration.combine(decorations);
}
