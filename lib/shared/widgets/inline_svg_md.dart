import 'package:flutter/material.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart' show GptMarkdownConfig;
import 'package:gpt_markdown/gpt_markdown.dart';

import '../markdown/markdown_surface_scope.dart';
import 'safe_svg_text.dart';

/// Renders raw inline `<svg>...</svg>` in the legacy Markdown pipeline.
///
/// The SVG is never fetched or written to disk; [SafeSvgText] applies the
/// shared active-content and structural limits before handing it to
/// `SvgPicture.string`.
class InlineSvgMd extends InlineMd {
  @override
  RegExp get exp => RegExp(r'<svg\b[^>]*/>|<svg\b[\s\S]*?</svg\s*>', caseSensitive: false, dotAll: true);

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text);
    if (match == null) return TextSpan(text: text, style: config.style);

    final baseStyle = config.style ?? DefaultTextStyle.of(context).style;
    final fontSize = baseStyle.fontSize ?? 15.5;
    final currentColor = baseStyle.color ?? MarkdownSurfaceScope.of(context).onSurface;
    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: SafeSvgText(
        svg: match.group(0) ?? '',
        height: fontSize * 1.5,
        currentColor: currentColor,
        fontSize: fontSize,
      ),
    );
  }
}
