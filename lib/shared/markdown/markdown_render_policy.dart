import 'package:flutter/foundation.dart';

/// Per-surface Markdown feature switches.
///
/// The assistant and AI Team use [full] (alerts, directives, safe HTML and
/// inline SVG). User-authored messages use [standard] so pasted `:::note`,
/// `> [!NOTE]`, raw HTML or SVG do not turn the user's own bubble into a card.
@immutable
class MarkdownRenderPolicy {
  const MarkdownRenderPolicy({
    this.alerts = true,
    this.directives = true,
    this.blockHtml = true,
    this.inlineHtml = true,
    this.inlineSvg = true,
  });

  /// GitHub-style `> [!NOTE]` alert cards.
  final bool alerts;

  /// `:::note` / `:::warning` directive cards.
  final bool directives;

  /// Block-level safe HTML (`<p>`, lists, tables, `<details>`, ...).
  final bool blockHtml;

  /// Inline safe HTML (`<b>`, `<span>`, `<a>`, ...).
  final bool inlineHtml;

  /// Inline raw `<svg>` rendering.
  final bool inlineSvg;

  static const MarkdownRenderPolicy full = MarkdownRenderPolicy();

  /// Standard Markdown only: bold/list/code/math/table/link stay enabled,
  /// while rich document syntax and raw HTML/SVG are rendered literally.
  static const MarkdownRenderPolicy standard = MarkdownRenderPolicy(
    alerts: false,
    directives: false,
    blockHtml: false,
    inlineHtml: false,
    inlineSvg: false,
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MarkdownRenderPolicy &&
        other.alerts == alerts &&
        other.directives == directives &&
        other.blockHtml == blockHtml &&
        other.inlineHtml == inlineHtml &&
        other.inlineSvg == inlineSvg;
  }

  @override
  int get hashCode => Object.hash(alerts, directives, blockHtml, inlineHtml, inlineSvg);
}
