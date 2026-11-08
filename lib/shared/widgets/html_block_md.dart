import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart' show GptMarkdownConfig;
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../markdown/markdown_surface_scope.dart';

/// Renders a safe subset of common block-level HTML.
///
/// Supported: `<p>`, `<ul>`, `<ol>`, `<li>`, `<blockquote>`, `<pre>` and
/// `<hr>`. Attributes are ignored, nested lists are flattened, and active
/// content inside paragraphs/lists is handled by the inline HTML droppers.
class HtmlBlockMd extends BlockMd {
  @override
  RegExp get exp => RegExp(r'^(?:' + expString + r')$', dotAll: true, multiLine: true, caseSensitive: false);

  @override
  String get expString =>
      r'(?:<p\b[^>]*>[\s\S]*?</p>'
      r'|<blockquote\b[^>]*>[\s\S]*?</blockquote>'
      '|${_listPattern('ul', 6)}'
      '|${_listPattern('ol', 6)}'
      '|${_listPattern('div', 4)}'
      '|${_listPattern('section', 4)}'
      r'|<table\b[^>]*>[\s\S]*?</table>'
      r'|<pre\b[^>]*>[\s\S]*?</pre>'
      r'|<hr\s*/?>)';

  static String _listPattern(String tag, int depth) {
    final open = '<$tag\\b[^>]*>';
    final close = '</$tag\\s*>';
    if (depth <= 1) {
      return '$open(?:(?!<$tag\\b|</$tag>)[\\s\\S])*$close';
    }
    final nested = _listPattern(tag, depth - 1);
    return '$open(?:(?!<$tag\\b|</$tag>)[\\s\\S]|$nested)*$close';
  }

  @override
  Widget build(BuildContext context, String text, GptMarkdownConfig config) {
    final raw = text.trim();
    if (RegExp(r'^<p\b', caseSensitive: false).hasMatch(raw)) {
      return _paragraph(context, _inner(raw, 'p'), config);
    }
    if (RegExp(r'^<blockquote\b', caseSensitive: false).hasMatch(raw)) {
      return _blockquote(context, _inner(raw, 'blockquote'), config);
    }
    if (RegExp(r'^<ul\b', caseSensitive: false).hasMatch(raw)) {
      return _list(context, raw, config, ordered: false);
    }
    if (RegExp(r'^<ol\b', caseSensitive: false).hasMatch(raw)) {
      return _list(context, raw, config, ordered: true);
    }
    if (RegExp(r'^<div\b', caseSensitive: false).hasMatch(raw)) {
      return _container(context, _inner(raw, 'div'), config);
    }
    if (RegExp(r'^<section\b', caseSensitive: false).hasMatch(raw)) {
      return _container(context, _inner(raw, 'section'), config);
    }
    if (RegExp(r'^<table\b', caseSensitive: false).hasMatch(raw)) {
      return _table(context, raw, config);
    }
    if (RegExp(r'^<pre\b', caseSensitive: false).hasMatch(raw)) {
      return _pre(context, _inner(raw, 'pre'), config);
    }
    if (RegExp(r'^<hr\b', caseSensitive: false).hasMatch(raw)) {
      return const Divider(height: 18);
    }
    return config.getRich(TextSpan(text: text, style: config.style));
  }

  Widget _paragraph(BuildContext context, String source, GptMarkdownConfig config) {
    final surface = MarkdownSurfaceScope.of(context);
    final style = (config.style ?? const TextStyle()).copyWith(color: surface.onSurface);
    final inner = TextSpan(children: MarkdownComponent.generate(context, source, config.copyWith(style: style), false));
    return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: config.getRich(inner));
  }

  Widget _blockquote(BuildContext context, String source, GptMarkdownConfig config) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = MarkdownSurfaceScope.of(context);
    final style = (config.style ?? const TextStyle()).copyWith(color: surface.onSurface);
    final inner = TextSpan(children: MarkdownComponent.generate(context, source, config.copyWith(style: style), true));
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: isDark ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(color: cs.primary.withValues(alpha: isDark ? 0.90 : 0.80), width: 3),
        ),
      ),
      child: config.getRich(inner),
    );
  }

  Widget _list(BuildContext context, String raw, GptMarkdownConfig config, {required bool ordered}) {
    final tag = ordered ? 'ol' : 'ul';
    dom.Element? list;
    for (final node in html_parser.parseFragment(raw).nodes) {
      if (node is dom.Element && node.localName == tag) {
        list = node;
        break;
      }
    }
    final surface = MarkdownSurfaceScope.of(context);
    final style = (config.style ?? const TextStyle()).copyWith(color: surface.onSurface);
    if (list == null) return config.getRich(TextSpan(text: raw, style: style));

    final items = list.children.where((child) => child.localName == 'li').toList();
    final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsetsDirectional.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 26, child: Text(ordered ? '${start + i}.' : '•', style: style)),
                  Expanded(
                    child: config.getRich(
                      TextSpan(
                        children: MarkdownComponent.generate(
                          context,
                          items[i].innerHtml,
                          config.copyWith(style: style),
                          true,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _container(BuildContext context, String source, GptMarkdownConfig config) {
    final surface = MarkdownSurfaceScope.of(context);
    final style = (config.style ?? const TextStyle()).copyWith(color: surface.onSurface);
    return config.getRich(
      TextSpan(children: MarkdownComponent.generate(context, source, config.copyWith(style: style), true)),
    );
  }

  Widget _table(BuildContext context, String raw, GptMarkdownConfig config) {
    dom.Element? table;
    for (final node in html_parser.parseFragment(raw).nodes) {
      if (node is dom.Element && node.localName == 'table') {
        table = node;
        break;
      }
    }
    final surface = MarkdownSurfaceScope.of(context);
    final style = (config.style ?? const TextStyle()).copyWith(color: surface.onSurface);
    if (table == null) return config.getRich(TextSpan(text: raw, style: style));

    final rows = table.querySelectorAll('tr');
    if (rows.isEmpty) return config.getRich(TextSpan(text: raw, style: style));
    final cellsByRow = [
      for (final row in rows)
        row.children.where((child) => child.localName == 'td' || child.localName == 'th').toList(),
    ];
    final columns = cellsByRow.fold<int>(0, (max, cells) => math.max(max, cells.length));
    if (columns == 0) return config.getRich(TextSpan(text: raw, style: style));

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        border: TableBorder.all(
          color: surface.onSurface.withValues(
            alpha: Theme.of(context).brightness == Brightness.dark ? 0.16 : 0.22,
          ),
        ),
        children: [
          for (final cells in cellsByRow)
            TableRow(
              children: [
                for (var index = 0; index < columns; index++)
                  if (index < cells.length)
                    _tableCell(context, cells[index], config, style)
                  else
                    const Padding(padding: EdgeInsets.all(6), child: SizedBox.shrink()),
              ],
            ),
        ],
      ),
    );
  }

  Widget _tableCell(BuildContext context, dom.Element cell, GptMarkdownConfig config, TextStyle style) {
    final header = cell.localName == 'th';
    final cellStyle = header ? style.copyWith(fontWeight: FontWeight.w700) : style;
    return Padding(
      padding: const EdgeInsets.all(6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: config.getRich(
          TextSpan(
            children: MarkdownComponent.generate(context, cell.innerHtml, config.copyWith(style: cellStyle), false),
          ),
        ),
      ),
    );
  }

  Widget _pre(BuildContext context, String source, GptMarkdownConfig config) {
    final code = html_parser.parseFragment(source).text ?? '';
    final surface = MarkdownSurfaceScope.of(context);
    final style = (config.style ?? const TextStyle()).copyWith(
      color: surface.onSurface,
      fontFamily: 'monospace',
      fontSize: (config.style?.fontSize ?? 15.5) * 0.9,
    );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: surface.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.25)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: config.getRich(TextSpan(text: code, style: style)),
      ),
    );
  }

  static String _inner(String raw, String tag) {
    final match = RegExp('<$tag\\b[^>]*>([\\s\\S]*?)</$tag\\s*>', caseSensitive: false, dotAll: true).firstMatch(raw);
    return match?.group(1) ?? '';
  }
}
