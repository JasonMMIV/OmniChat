import 'package:flutter/material.dart';

import 'markdown_alert.dart';

/// Colors for one legacy GitHub alert card.
///
/// Kept separate from the parser so the contrast matrix can validate the
/// title/background pair without building a widget tree.
class MarkdownAlertColors {
  const MarkdownAlertColors({required this.accent, required this.title});

  final Color accent;
  final Color title;

  Color background({required bool isDark}) {
    return accent.withOpacity(isDark ? 0.16 : 0.10);
  }
}

MarkdownAlertColors markdownAlertColors(MarkdownAlertKind kind, ColorScheme cs) {
  final accent = switch (kind) {
    MarkdownAlertKind.note => cs.primary,
    MarkdownAlertKind.tip => cs.tertiary,
    MarkdownAlertKind.important => cs.secondary,
    MarkdownAlertKind.warning => Color.lerp(cs.tertiary, cs.error, 0.55)!,
    MarkdownAlertKind.caution => cs.error,
  };
  // Accent-on-accent-tint can fall below 4.5:1 in light themes. Pulling the
  // title 55% toward the paired ink keeps it readable while the border/icon
  // and tint retain the alert's semantic color.
  final title = Color.lerp(accent, cs.onSurface, 0.55)!;
  return MarkdownAlertColors(accent: accent, title: title);
}
