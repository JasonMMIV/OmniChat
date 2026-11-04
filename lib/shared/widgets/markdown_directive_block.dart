import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart' show GptMarkdownConfig;

import '../markdown/markdown_directive.dart';
import 'markdown_callout_card.dart';

/// Legacy block renderer for `:::note`-style directive cards.
///
/// Closed directives are always recognized. An unclosed directive also
/// matches to EOF and renders as a partial card, so the card does not snap
/// back to literal `:::note` text when streaming finishes.
class DirectiveBlockMd extends BlockMd {
  // Markdown indented code starts at four spaces; only allow up to three so
  // `    :::note` stays code instead of becoming a card.
  static const String _header = r'^ {0,3}:::[ \t]*[A-Za-z][\w-]*[ \t]*(?:title="[^"]*")?[ \t]*\n';
  static const String _closedPattern = _header + r'(?:[\s\S]*?\n)? {0,3}:::[ \t]*$';
  static const String _openPattern = _header + r'[\s\S]*$';

  @override
  String get expString => _closedPattern;

  @override
  RegExp get exp => RegExp('$_closedPattern|$_openPattern', multiLine: true, dotAll: true, caseSensitive: false);

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    // Mirror the alert path (bare WidgetSpan) instead of BlockMd's
    // Row/Flexible wrapper, so alert and directive cards share the same
    // width and margins.
    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: build(context, text, config),
    );
  }

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final directive = parseMarkdownDirective(text);
    if (directive == null) {
      return config.getRich(TextSpan(text: text, style: config.style));
    }

    // Unknown directives keep their children but do not get a card or a
    // synthetic title.
    if (directive.kind == null) {
      if (directive.body.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: config.getRich(TextSpan(children: MarkdownComponent.generate(context, directive.body, config, true))),
      );
    }

    return MarkdownCalloutCard(kind: directive.kind!, title: directive.title, body: directive.body, config: config);
  }
}
