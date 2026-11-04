import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart' show GptMarkdownConfig;

import '../markdown/markdown_inline_style.dart';
import '../markdown/markdown_surface_scope.dart';

/// Renders the safe inline HTML subset on the legacy pipeline.
///
/// Supported: `<b>/<strong>`, `<i>/<em>`, `<u>`, `<s>/<del>`, `<mark>`,
/// `<code>`, `<kbd>`, `<sub>`, `<sup>`, `<span style="...">`,
/// `<font color="...">` and `<br>`. Span styles accept only a small safe CSS
/// subset (see [applyInlineCssStyle]). Block HTML (p/table/pre/...) is
/// intentionally not handled here.
class InlineHtmlMd extends InlineMd {
  @override
  RegExp get exp => RegExp(
    r'<(?<tag>b|strong|i|em|u|s|del|mark|code|kbd|sub|sup|span|font)\b(?<attrs>[^>]*)>'
    r'(?<inner>[\s\S]*?)</'
    r'(?<close>b|strong|i|em|u|s|del|mark|code|kbd|sub|sup|span|font)\s*>'
    r'|<br\s*/?>',
    caseSensitive: false,
    dotAll: true,
  );

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final whole = text.trim();
    if (RegExp(r'^<br\b', caseSensitive: false).hasMatch(whole)) {
      return const TextSpan(text: '\n');
    }

    final match = exp.firstMatch(text);
    if (match == null) return TextSpan(text: text, style: config.style);
    final tag = match.namedGroup('tag')?.toLowerCase();
    final close = match.namedGroup('close')?.toLowerCase();
    if (tag == null || close == null || !_sameTag(tag, close)) {
      return TextSpan(text: text, style: config.style);
    }

    final inner = match.namedGroup('inner') ?? '';
    final attrs = match.namedGroup('attrs') ?? '';
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mdSurface = MarkdownSurfaceScope.of(context);
    final base = config.style ?? const TextStyle();
    final baseSize = base.fontSize ?? 15.5;

    if (tag == 'sub' || tag == 'sup') {
      final small = base.copyWith(fontSize: baseSize * 0.72, height: 1.0);
      return WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: Transform.translate(
          offset: Offset(0, tag == 'sub' ? 3 : -3),
          child: Text.rich(
            TextSpan(
              style: small,
              children: MarkdownComponent.generate(context, inner, config.copyWith(style: small), false),
            ),
            textDirection: config.textDirection,
          ),
        ),
      );
    }

    late final TextStyle style;
    switch (tag) {
      case 'b':
      case 'strong':
        style = base.copyWith(fontWeight: FontWeight.w700);
      case 'i':
      case 'em':
        style = base.copyWith(fontStyle: FontStyle.italic);
      case 'u':
        style = base.copyWith(decoration: TextDecoration.underline);
      case 's':
      case 'del':
        style = base.copyWith(decoration: TextDecoration.lineThrough);
      case 'mark':
        style = base.copyWith(
          backgroundColor: Color.alphaBlend(cs.primary.withOpacity(isDark ? 0.32 : 0.20), mdSurface.surface),
          color: mdSurface.onSurface,
        );
      case 'code':
      case 'kbd':
        style = base.copyWith(
          fontFamily: 'monospace',
          fontSize: baseSize * 0.90,
          backgroundColor: Color.alphaBlend(cs.primary.withOpacity(isDark ? 0.16 : 0.08), mdSurface.surface),
          color: mdSurface.onSurface,
        );
      case 'span':
        style = _respectSurfaceInk(
          applyInlineCssStyle(base, _attribute(attrs, 'style'), surface: mdSurface.surface, ink: mdSurface.onSurface) ??
              base,
          mdSurface,
        );
      case 'font':
        style = _respectSurfaceInk(
          applyFontColor(base, _attribute(attrs, 'color'), surface: mdSurface.surface, ink: mdSurface.onSurface) ??
              base,
          mdSurface,
        );
      default:
        return TextSpan(text: text, style: config.style);
    }

    // Code/kbd content is literal: do not re-parse tags or markdown inside it.
    if (tag == 'code' || tag == 'kbd') {
      return TextSpan(text: inner, style: style);
    }

    return TextSpan(
      style: style,
      children: MarkdownComponent.generate(context, inner, config.copyWith(style: style), false),
    );
  }

  static bool _sameTag(String open, String close) {
    if (open == close) return true;
    return (open == 'b' && close == 'strong') ||
        (open == 'strong' && close == 'b') ||
        (open == 'i' && close == 'em') ||
        (open == 'em' && close == 'i') ||
        (open == 's' && close == 'del') ||
        (open == 'del' && close == 's');
  }

  static TextStyle _respectSurfaceInk(TextStyle style, MarkdownSurface surface) {
    // The clamp above is measured against the opaque block surface. Over a
    // frosted bubble or wallpaper the effective backdrop is different, so
    // fall back to the paired ink that the surface contract already validated.
    if (surface.wantsBodyTextShadow && style.color != null) {
      return style.copyWith(color: surface.onSurface);
    }
    return style;
  }

  static String? _attribute(String attrs, String name) {
    final match = RegExp(
      '(?:^|\\s)${RegExp.escape(name)}\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))',
      caseSensitive: false,
    ).firstMatch(attrs);
    return match?.group(1) ?? match?.group(2) ?? match?.group(3);
  }
}

/// Drops active/unsupported raw HTML blocks (script/iframe/img/...).
///
/// This is a display-level drop, not a sanitizer for a browser DOM: content is
/// never executed. The pattern has no backreferences so it stays safe when
/// gpt_markdown joins component patterns into one alternation.
class DangerousHtmlMd extends InlineMd {
  @override
  RegExp get exp => RegExp(
    r'<(?:script|iframe|object|embed|form|input|meta|link|base|style)\b'
    r'[^>]*>[\s\S]*?</'
    r'(?:script|iframe|object|embed|form|input|meta|link|base|style)\s*>'
    r'|<(?:img|input|meta|link|base)\b[^>]*/?>',
    caseSensitive: false,
    dotAll: true,
  );

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    return const TextSpan(text: '');
  }
}
