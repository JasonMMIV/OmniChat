// Web fetch HTML content extraction + text formatting (WEB_FETCH_PLAN.md
// §5.5–5.6).
//
// Extraction follows the Readability candidate-scoring skeleton with the
// Trafilatura-style escalation ladder: score candidates → merge qualifying
// siblings → fall back to the whole body when extraction pruned too much →
// fall back to plain body text when Markdown is still nearly empty.
//
// `comment` / `replies` / `community` / `discussion` class names are NEVER
// treated as boilerplate: forum pages live inside those containers.
//
// Pure Dart (no Flutter imports) so it can run inside `compute` and be tested
// without bindings.

import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:html2md/html2md.dart' as html2md;

class HtmlMetadata {
  const HtmlMetadata({
    this.title,
    this.description,
    this.siteName,
    this.language,
    this.publishedTime,
  });

  final String? title;
  final String? description;
  final String? siteName;
  final String? language;
  final String? publishedTime;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (title != null) 'title': title,
    if (description != null) 'description': description,
    if (siteName != null) 'siteName': siteName,
    if (language != null) 'language': language,
    if (publishedTime != null) 'publishedTime': publishedTime,
  };
}

class HtmlExtractionResult {
  const HtmlExtractionResult({
    required this.markdown,
    required this.metadata,
    this.errorCode,
    this.errorMessage,
  });

  final String markdown;
  final HtmlMetadata metadata;

  /// `selector_not_found` / `no_readable_content` when extraction failed.
  final String? errorCode;
  final String? errorMessage;

  bool get ok => errorCode == null;
}

class HtmlExtractor {
  HtmlExtractor._();

  /// Hard cap for DOM parsing. Larger documents use the plain-text fallback
  /// instead of building a huge tree (Android low-memory safety).
  static const int maxParserInputChars = 1024 * 1024;

  static const int minReadableChars = 250;

  static const Set<String> _dropTags = <String>{
    'script',
    'style',
    'noscript',
    'template',
    'svg',
    'iframe',
    'canvas',
    'object',
    'embed',
    'nav',
    'aside',
    'footer',
    'header',
  };

  /// Class/id substrings that mark boilerplate. Deliberately excludes
  /// `comment`, `comments`, `replies`, `community` and `discussion`.
  static const List<String> _negativePatterns = <String>[
    'sidebar',
    'footer',
    'nav',
    'menu',
    'breadcrumb',
    'share',
    'social',
    'promo',
    'sponsor',
    'related',
    'widget',
    'ad',
    'ads',
    'advert',
    'cookie',
    'popup',
    'modal',
    'overlay',
    'toolbar',
    'masthead',
    'pagination',
    'pager',
  ];

  static const Set<String> _candidateTags = <String>{
    'article',
    'main',
    'section',
    'div',
  };

  static const Set<String> _blockTags = <String>{
    'address',
    'article',
    'aside',
    'blockquote',
    'dd',
    'div',
    'dl',
    'dt',
    'fieldset',
    'figcaption',
    'figure',
    'footer',
    'form',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'header',
    'hr',
    'li',
    'main',
    'nav',
    'ol',
    'p',
    'pre',
    'section',
    'table',
    'tbody',
    'td',
    'tfoot',
    'th',
    'thead',
    'tr',
    'ul',
  };

  /// Extracts the main content as Markdown and reads page metadata.
  static HtmlExtractionResult extract(String html, {String? selector}) {
    final metadata = readMetadata(html);

    // Too large for the DOM: degrade to plain text (never crash / OOM).
    if (html.length > maxParserInputChars) {
      final text = normalizePlainText(_stripTagsAsText(html));
      return HtmlExtractionResult(
        markdown: text,
        metadata: metadata,
        errorCode: text.isEmpty ? 'no_readable_content' : null,
        errorMessage: text.isEmpty
            ? 'The page contained no readable text.'
            : null,
      );
    }

    final document = html_parser.parse(html);
    final body = document.body ?? document.documentElement;
    if (body == null) {
      return HtmlExtractionResult(
        markdown: '',
        metadata: metadata,
        errorCode: 'no_readable_content',
        errorMessage: 'The page contained no readable text.',
      );
    }

    _prune(document, body);

    dom.Element root = body;
    if ((selector ?? '').trim().isNotEmpty) {
      final rawSelector = selector!.trim();
      dom.Element? selected;
      try {
        selected = document.querySelector(rawSelector);
      } on FormatException catch (e) {
        return HtmlExtractionResult(
          markdown: '',
          metadata: metadata,
          errorCode: 'invalid_arguments',
          errorMessage: 'Invalid CSS selector: ${e.message}',
        );
      } on ArgumentError catch (e) {
        return HtmlExtractionResult(
          markdown: '',
          metadata: metadata,
          errorCode: 'invalid_arguments',
          errorMessage: 'Invalid CSS selector: $e',
        );
      }
      if (selected == null) {
        return HtmlExtractionResult(
          markdown: '',
          metadata: metadata,
          errorCode: 'selector_not_found',
          errorMessage: 'The CSS selector matched no element on this page.',
        );
      }
      root = selected;
    }

    final rootTextLength = _textLength(root);
    final scores = _scoreCandidates(root);

    dom.Element? best;
    double bestScore = 0;
    for (final entry in scores.entries) {
      final element = entry.key;
      if (_textLength(element) < minReadableChars) continue;
      if (entry.value > bestScore) {
        best = element;
        bestScore = entry.value;
      }
    }

    best ??= root;

    if (best != root) {
      _mergeSiblings(best, scores, bestScore);
    }

    // Safety valve: extraction must not throw away most of the page (a
    // product / forum page whose content sits outside the winning candidate
    // keeps the whole body instead).
    if (rootTextLength > 0 &&
        _textLength(best) < rootTextLength / 5 &&
        best != root) {
      best = root;
    }

    var markdown = _toMarkdown(best);
    if (markdown.length < minReadableChars) {
      final fallback = normalizePlainText(_textWithBreaks(root));
      if (fallback.isNotEmpty) markdown = fallback;
    }
    if (markdown.isEmpty && best != root) {
      markdown = normalizePlainText(_textWithBreaks(root));
    }
    if (markdown.isEmpty && (metadata.description ?? '').trim().isNotEmpty) {
      markdown =
          '> Only the page description was available.\n\n${metadata.description!.trim()}';
    }

    if (markdown.isEmpty) {
      return HtmlExtractionResult(
        markdown: '',
        metadata: metadata,
        errorCode: 'no_readable_content',
        errorMessage: 'The page contained no readable text.',
      );
    }
    return HtmlExtractionResult(markdown: markdown, metadata: metadata);
  }

  /// Reads title / description / site name / language / published time.
  static HtmlMetadata readMetadata(String html) {
    String? title;
    String? description;
    String? siteName;
    String? language;
    String? publishedTime;

    final titleMatch = RegExp(
      r'<title[^>]*>([\s\S]*?)</title>',
      caseSensitive: false,
    ).firstMatch(html);
    if (titleMatch != null) title = _cleanText(titleMatch.group(1));

    final ogTitle = RegExp(
      r"""<meta[^>]+(?:property|name)\s*=\s*["']og:title["'][^>]*content\s*=\s*["']([^"']*)["']""",
      caseSensitive: false,
    ).firstMatch(html);
    final ogTitleReversed = RegExp(
      r"""<meta[^>]+content\s*=\s*["']([^"']*)["'][^>]*(?:property|name)\s*=\s*["']og:title["']""",
      caseSensitive: false,
    ).firstMatch(html);
    title ??= _cleanText(ogTitle?.group(1) ?? ogTitleReversed?.group(1));

    description = _metaContent(html, 'description');
    description ??= _metaContent(html, 'og:description');
    siteName = _metaContent(html, 'og:site_name');
    publishedTime = _jsonLdDate(html);

    final langMatch = RegExp(
      r"""<html[^>]+lang\s*=\s*["']([^"']+)""",
      caseSensitive: false,
    ).firstMatch(html);
    language = _cleanText(langMatch?.group(1));

    publishedTime ??= _metaContent(html, 'article:published_time');
    publishedTime ??= _firstMatch(
      RegExp(
        r"""<time[^>]+datetime\s*=\s*["']([^"']+)["']""",
        caseSensitive: false,
      ),
      html,
    );

    return HtmlMetadata(
      title: _emptyToNull(title),
      description: _emptyToNull(description),
      siteName: _emptyToNull(siteName),
      language: _emptyToNull(language),
      publishedTime: _emptyToNull(publishedTime),
    );
  }

  /// Strips YAML frontmatter from a Markdown document.
  static String stripFrontmatter(String markdown) {
    final text = markdown.replaceAll('\r\n', '\n');
    if (!text.startsWith('---\n')) return text;
    final end = text.indexOf('\n---', 4);
    if (end < 0) return text;
    final after = text.indexOf('\n', end + 4);
    return after < 0 ? '' : text.substring(after + 1).trimLeft();
  }

  /// Pretty-prints small JSON documents, minifies large ones.
  static String formatJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      final encoder = raw.length < 4096
          ? const JsonEncoder.withIndent('  ')
          : const JsonEncoder();
      return encoder.convert(decoded);
    } on FormatException {
      return normalizePlainText(raw);
    }
  }

  /// Normalizes line endings, trims trailing spaces and collapses runs of
  /// blank lines. Paragraph structure is preserved.
  static String normalizePlainText(String text) {
    var value = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = <String>[];
    for (final line in value.split('\n')) {
      lines.add(line.trimRight());
    }
    value = lines.join('\n');
    value = value.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return value.trim();
  }

  // --------------------------------------------------------------------------
  // Pruning
  // --------------------------------------------------------------------------

  static void _prune(dom.Document document, dom.Element body) {
    for (final comment in document.nodes.whereType<dom.Comment>().toList()) {
      comment.remove();
    }
    for (final tag in _dropTags) {
      for (final element in body.querySelectorAll(tag)) {
        element.remove();
      }
    }

    // Remove data URIs before parsing cost grows.
    for (final element in body.querySelectorAll('[src^="data:"]')) {
      element.attributes.remove('src');
    }

    final bodyText = _textLength(body);
    for (final form in body.querySelectorAll('form')) {
      if (bodyText == 0 || _textLength(form) < bodyText * 0.5) {
        form.remove();
      }
    }

    for (final element in body.querySelectorAll('*')) {
      if (element == body) continue;
      if (_protectedFromNegativePrune(element, bodyText)) continue;
      final haystack = '${element.id} ${element.className}'.toLowerCase();
      if (haystack.trim().isEmpty) continue;
      if (_matchesNegativePattern(haystack)) {
        element.remove();
      }
    }
  }

  /// Never let a generic negative class (e.g. `widget`, `sidebar`, `menu`)
  /// remove a page's real content container. Several publishers put those
  /// words on their main article wrapper (`<article class="... widget ...">`,
  /// `<section class="article-with-sidebar">`, `<section class="storyMenu">`).
  static bool _protectedFromNegativePrune(
    dom.Element element,
    int bodyTextLength,
  ) {
    final tag = element.localName;
    if (tag == 'article' || tag == 'main') return true;
    if (element.attributes['role'] == 'main') return true;
    if (element.querySelector('article, main, [role="main"]') != null) {
      return true;
    }
    if (bodyTextLength > 0 && _textLength(element) >= bodyTextLength * 0.35) {
      return true;
    }
    return false;
  }

  static bool _matchesNegativePattern(String haystack) {
    final tokens = haystack.split(RegExp(r'[^a-z0-9]+'));
    for (final pattern in _negativePatterns) {
      for (final token in tokens) {
        if (token.isEmpty) continue;
        if (token == pattern) return true;
        // `ad` / `ads` must not match `read`, `add`, `downloads`…
        if (pattern.length <= 2) continue;
        if (token.startsWith(pattern)) return true;
      }
    }
    return false;
  }

  // --------------------------------------------------------------------------
  // Scoring
  // --------------------------------------------------------------------------

  static Map<dom.Element, double> _scoreCandidates(dom.Element root) {
    final candidates = <dom.Element>{
      if (_isCandidate(root)) root,
      ...root.querySelectorAll('article'),
      ...root.querySelectorAll('main'),
      ...root.querySelectorAll('[role="main"]'),
      ...root.querySelectorAll('section'),
      ...root.querySelectorAll('div'),
    };

    final propagated = <dom.Element, double>{};
    for (final element in candidates) {
      final score = _baseScore(element);
      var ancestor = element.parent;
      for (var depth = 1; depth <= 5 && ancestor != null; depth++) {
        propagated[ancestor] = (propagated[ancestor] ?? 0) + score * depth;
        ancestor = ancestor.parent;
      }
      propagated[element] = (propagated[element] ?? 0) + score;
    }

    final finalScores = <dom.Element, double>{};
    propagated.forEach((element, score) {
      final density = _linkDensity(element);
      finalScores[element] = score * (1 - density);
    });

    // Only candidate nodes compete for the top spot.
    finalScores.removeWhere((element, _) => !candidates.contains(element));
    return finalScores;
  }

  static bool _isCandidate(dom.Element element) =>
      _candidateTags.contains(element.localName) ||
      element.attributes['role'] == 'main';

  static double _baseScore(dom.Element element) {
    final text = element.text;
    final commas = ','.allMatches(text).length;
    final lengthComponent = (_textLength(element) / 100).floor().clamp(0, 3);
    return 1 +
        commas +
        lengthComponent +
        _tagWeight(element.localName ?? '');
  }

  static double _tagWeight(String tag) {
    switch (tag) {
      case 'div':
        return 5;
      case 'pre':
      case 'td':
      case 'blockquote':
        return 3;
      case 'address':
      case 'ol':
      case 'ul':
      case 'dl':
      case 'dd':
      case 'dt':
      case 'li':
      case 'form':
        return -3;
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
      case 'th':
        return -5;
      default:
        return 0;
    }
  }

  static double _linkDensity(dom.Element element) {
    final total = _textLength(element);
    if (total == 0) return 0;
    var linkLength = 0;
    for (final link in element.querySelectorAll('a')) {
      linkLength += _textLength(link);
    }
    return linkLength / total;
  }

  static void _mergeSiblings(
    dom.Element best,
    Map<dom.Element, double> scores,
    double bestScore,
  ) {
    final parent = best.parent;
    if (parent == null) return;
    final threshold = bestScore * 0.2 < 10 ? 10.0 : bestScore * 0.2;
    final siblings = parent.children
        .where((element) => element != best)
        .where((element) => scores[element] != null)
        .where((element) => scores[element]! >= threshold)
        .where((element) => _linkDensity(element) < 0.25)
        .where((element) {
          final length = _textLength(element);
          if (length > 80) return true;
          return length > 0 && element.text.trimRight().endsWith('.');
        })
        .toList();

    for (final sibling in siblings) {
      best.append(sibling);
    }
  }

  // --------------------------------------------------------------------------
  // Rendering
  // --------------------------------------------------------------------------

  static String _toMarkdown(dom.Element element) {
    String markdown;
    try {
      markdown = html2md.convert(element.outerHtml);
    } catch (_) {
      markdown = _textWithBreaks(element);
    }
    markdown = markdown.replaceAll('\r\n', '\n').replaceAll('\n{3,}', '\n\n');
    return markdown.trim();
  }

  /// Plain-text fallback that keeps block boundaries as line breaks.
  static String _textWithBreaks(dom.Element root) {
    final buffer = StringBuffer();

    void walk(dom.Node node) {
      if (node is dom.Text) {
        buffer.write(node.text);
        return;
      }
      if (node is! dom.Element) return;
      if (_dropTags.contains(node.localName)) return;
      final isBlock = _blockTags.contains(node.localName);
      if (node.localName == 'br') {
        buffer.write('\n');
        return;
      }
      if (isBlock) buffer.write('\n');
      for (final child in node.nodes) {
        walk(child);
      }
      if (isBlock) buffer.write('\n');
    }

    walk(root);
    return buffer.toString();
  }

  /// Last-resort tag stripper used when the document is too large to parse.
  static String _stripTagsAsText(String html) {
    var text = html
        .replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ')
        .replaceAll(
          RegExp(
            r'<(script|style|noscript|template|svg|iframe)\b[^>]*>[\s\S]*?</\1>',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'</(p|div|li|tr|h[1-6]|section|article)>'), '\n')
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), ' ');
    text = _decodeBasicEntities(text);
    return normalizePlainText(text);
  }

  static String _decodeBasicEntities(String text) {
    final decoded = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    return decoded.replaceAllMapped(
      RegExp(r'&#(x?[0-9a-fA-F]+);', caseSensitive: false),
      (match) {
        final raw = match.group(1)!;
        final isHex = raw.startsWith('x') || raw.startsWith('X');
        final code = int.tryParse(
          isHex ? raw.substring(1) : raw,
          radix: isHex ? 16 : 10,
        );
        if (code == null || code < 0 || code > 0x10FFFF) {
          return match.group(0)!;
        }
        return String.fromCharCode(code);
      },
    );
  }

  static int _textLength(dom.Element element) => element.text.length;

  static String? _metaContent(String html, String name) {
    final escaped = RegExp.escape(name);
    final patterns = <RegExp>[
      RegExp(
        r"""<meta[^>]+(?:property|name)\s*=\s*["']""" +
            escaped +
            r"""["'][^>]*content\s*=\s*["']([^"']*)["']""",
        caseSensitive: false,
      ),
      RegExp(
        r"""<meta[^>]+content\s*=\s*["']([^"']*)["'][^>]*(?:property|name)\s*=\s*["']""" +
            escaped +
            r"""["']""",
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      if (match != null) {
        final value = _cleanText(match.group(1));
        if (value != null && value.isNotEmpty) return value;
      }
    }
    return null;
  }

  static String? _jsonLdDate(String html) {
    for (final match in RegExp(
      r"""<script[^>]+type\s*=\s*["']application/ld\+json["'][^>]*>([\s\S]*?)</script>""",
      caseSensitive: false,
    ).allMatches(html)) {
      final value = _firstMatch(
        RegExp(r'"datePublished"\s*:\s*"([^"]+)"'),
        match.group(1)!,
      );
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  static String? _firstMatch(RegExp pattern, String input) {
    final match = pattern.firstMatch(input);
    if (match == null) return null;
    return _cleanText(match.group(1));
  }

  static String? _cleanText(String? raw) {
    if (raw == null) return null;
    final value = _decodeBasicEntities(
      raw.replaceAll(RegExp(r'\s+'), ' '),
    ).trim();
    return value.isEmpty ? null : value;
  }

  static String? _emptyToNull(String? value) =>
      (value == null || value.trim().isEmpty) ? null : value;
}
