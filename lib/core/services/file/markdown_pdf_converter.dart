import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Converts a subset of Markdown into PDF bytes using the bundled Syncfusion
/// PDF engine.
///
/// No new dependencies are required: the app already depends on
/// `syncfusion_flutter_pdf` (used for PDF text extraction), and its standard
/// CJK fonts ([PdfCjkFontFamily]) render Chinese text without bundling font
/// files.
///
/// Supported subset: ATX headings, paragraphs, bold / italic / inline code,
/// ordered & unordered lists, GFM-style pipe tables, fenced code blocks,
/// block quotes, horizontal rules, `[text](url)` / `![alt](url)` links, and
/// per-page page numbers. Images are not embedded.
class MarkdownPdfConverter {
  MarkdownPdfConverter._();

  /// Hard cap on the generated PDF size. Generated reports are normally a few
  /// hundred KB; this only guards against pathological input.
  static const int maxPdfBytes = 8 * 1024 * 1024;

  /// Maximum cell text length kept when rendering tables.
  static const int maxCellLength = 300;

  /// Maximum number of table columns rendered (wider tables are truncated).
  static const int maxTableColumns = 12;

  /// Maximum table rows rendered (taller tables are truncated).
  static const int maxTableRows = 500;

  static const double _margin = 45;
  static const double _lineSpacing = 1.6;
  static const double _bodySize = 10.5;
  static const double _codeSize = 9.5;
  static const double _tableSize = 9;

  /// Characters that only exist in Traditional Chinese. Used to pick the CJK
  /// standard font so traditional text does not rely on viewer substitution.
  static const String _traditionalOnlyChars =
      '這是說話們為與沒來時國會東車長學書見鳥魚風龍點麵應農曆臺灣廣東博物館這裡那裡他們什麼東西這些那些讓請謝謝對不起問題答案工作機會時間公司學校醫院電腦手機電話號碼裏麵給個愛還是比較專業開發系統測試報告檔案資料數據程式碼網頁應用程式語言環境設定選擇確認取消儲存感謝歡迎參考資訊網際網路國際運輸歷史書籍音樂電影電視節目的確應該知道覺得認為希望了解說明解釋簡單容易困難重要成功失敗開始結束繼續暫停停止開啟關閉新增刪除修改查詢顯示隱藏載入儲存輸出輸入';

  /// Convert a Markdown string to PDF bytes.
  static List<int> convert(String markdown) {
    final renderer = _PdfRenderer();
    return renderer.render(markdown);
  }
}

/// One inline styled run produced by [_parseInline].
class _InlineRun {
  const _InlineRun(this.text, this.style);

  final String text;
  final PdfFontStyle style;
}

/// One parsed Markdown block.
class _MdBlock {
  const _MdBlock(this.type, this.text, [this.level = 0, this.rows]);

  /// `heading`, `paragraph`, `listItem`, `orderedItem`, `code`, `quote`,
  /// `table`, or `hr`.
  final String type;
  final String text;
  final int level;

  /// Table rows (type == 'table').
  final List<List<String>>? rows;
}

class _PdfRenderer {
  final PdfDocument _document = PdfDocument();
  final Map<String, PdfCjkStandardFont> _fontCache = <String, PdfCjkStandardFont>{};

  PdfCjkFontFamily _family = PdfCjkFontFamily.sinoTypeSongLight;
  PdfPage? _page;
  PdfGraphics? _graphics;
  double _y = 0;
  double _pageWidth = 0;
  double _pageHeight = 0;

  double get _bodySize => MarkdownPdfConverter._bodySize;
  double get _lineSpacing => MarkdownPdfConverter._lineSpacing;
  double get _codeSize => MarkdownPdfConverter._codeSize;
  double get _tableSize => MarkdownPdfConverter._tableSize;
  double get _margin => MarkdownPdfConverter._margin;
  double get _left => _margin;
  double get _right => _pageWidth - _margin;
  double get _bottom => _pageHeight - _margin;

  List<int> render(String markdown) {
    final text = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    _family = _containsTraditional(text)
        ? PdfCjkFontFamily.monotypeSungLight
        : PdfCjkFontFamily.sinoTypeSongLight;
    _newPage();

    for (final block in _parseBlocks(text)) {
      switch (block.type) {
        case 'heading':
          final sizes = <double>[20, 16, 14, 12.5, 11.5, 11.5];
          final size = sizes[math.min(block.level, 6) - 1];
          _ensureSpace(size * _lineSpacing + 14);
          _y += 10;
          _drawInline(block.text, size, PdfFontStyle.bold);
          _y += 6;
          break;
        case 'paragraph':
          _ensureSpace(_bodySize * _lineSpacing);
          _drawInline(block.text, _bodySize, PdfFontStyle.regular);
          _y += 6;
          break;
        case 'quote':
          _ensureSpace(_bodySize * _lineSpacing);
          _drawQuote(block.text);
          _y += 6;
          break;
        case 'listItem':
          _ensureSpace(_bodySize * _lineSpacing);
          final indent = math.min(block.level, 6) * 14.0;
          _drawInline('• ${block.text}', _bodySize, PdfFontStyle.regular, indent: indent);
          _y += 3;
          break;
        case 'orderedItem':
          _ensureSpace(_bodySize * _lineSpacing);
          final indent = math.min(block.level, 6) * 14.0;
          _drawInline(block.text, _bodySize, PdfFontStyle.regular, indent: indent);
          _y += 3;
          break;
        case 'code':
          _drawCodeBlock(block.text);
          break;
        case 'table':
          _drawTable(block.rows ?? const <List<String>>[]);
          break;
        case 'hr':
          _drawHr();
          break;
      }
    }

    _drawPageNumbers();
    return _document.saveSync();
  }

  void _newPage() {
    _page = _document.pages.add();
    _graphics = _page!.graphics;
    final size = _page!.getClientSize();
    _pageWidth = size.width;
    _pageHeight = size.height;
    _y = _margin;
  }

  void _ensureSpace(double needed) {
    if (_y + needed > _bottom) _newPage();
  }

  PdfCjkStandardFont _font(double size, PdfFontStyle style) {
    final key = '$size|${style.index}|$_family';
    return _fontCache.putIfAbsent(key, () {
      return PdfCjkStandardFont(_family, size, style: style);
    });
  }

  /// Draw a plain paragraph with a left accent bar (block quotes).
  void _drawQuote(String text) {
    final font = _font(_bodySize, PdfFontStyle.italic);
    final barWidth = 3.0;
    final bar = PdfSolidBrush(PdfColor(170, 170, 170));
    final startY = _y;
    _drawRuns(
      _parseInline(text, defaultStyle: PdfFontStyle.italic),
      font,
      indent: 12,
    );
    _graphics!.drawRectangle(
      brush: bar,
      bounds: Rect.fromLTWH(_left, startY, barWidth, _y - startY),
    );
  }

  void _drawHr() {
    _ensureSpace(_lineSpacing);
    _y += 6;
    _graphics!.drawLine(
      PdfPen(PdfColor(180, 180, 180), width: 1),
      Offset(_left, _y),
      Offset(_right, _y),
    );
    _y += 10;
  }

  void _drawCodeBlock(String content) {
    final font = _font(_codeSize, PdfFontStyle.regular);
    final lineHeight = _codeSize * 1.5;
    final background = PdfSolidBrush(PdfColor(244, 244, 246));
    final lines = content.split('\n');
    final blockHeight = math.max(1, lines.length) * lineHeight + 8;
    _ensureSpace(blockHeight);
    final blockTop = _y;
    _graphics!.drawRectangle(
      brush: background,
      bounds: Rect.fromLTWH(_left - 4, blockTop, _right - _left + 8, blockHeight),
    );
    _y += 4;
    for (final line in lines) {
      if (_y + lineHeight > _bottom) {
        // Very long code blocks continue on a new page without the tint.
        _newPage();
      }
      _drawRuns(<_InlineRun>[_InlineRun(line, PdfFontStyle.regular)], font);
    }
    _y += 6;
  }

  void _drawTable(List<List<String>> rows) {
    if (rows.isEmpty) return;
    var colCount = 0;
    for (final row in rows) {
      colCount = math.max(colCount, row.length);
    }
    if (colCount == 0) return;
    colCount = math.min(colCount, MarkdownPdfConverter.maxTableColumns);
    final cappedRows = rows.take(MarkdownPdfConverter.maxTableRows).toList();

    final grid = PdfGrid();
    grid.style = PdfGridStyle(
      cellPadding: PdfPaddings(left: 4, right: 4, top: 3, bottom: 3),
      font: _font(_tableSize, PdfFontStyle.regular),
    );
    grid.columns.add(count: colCount);
    grid.headers.add(1);
    for (var c = 0; c < colCount; c++) {
      grid.headers[0].cells[c].value = c < cappedRows.first.length
          ? _truncate(cappedRows.first[c])
          : '';
    }
    grid.headers[0].style = PdfGridRowStyle(
      font: _font(_tableSize, PdfFontStyle.bold),
      backgroundBrush: PdfSolidBrush(PdfColor(230, 232, 238)),
    );
    for (var r = 1; r < cappedRows.length; r++) {
      final row = grid.rows.add();
      for (var c = 0; c < colCount; c++) {
        row.cells[c].value = c < cappedRows[r].length
            ? _truncate(cappedRows[r][c])
            : '';
      }
    }

    final result = grid.draw(
      page: _page,
      bounds: Rect.fromLTWH(_left, _y, _right - _left, 0),
      format: PdfLayoutFormat(
        layoutType: PdfLayoutType.paginate,
        breakType: PdfLayoutBreakType.fitElement,
      ),
    );
    _y = (result?.bounds.bottom ?? _y) + 12;
    if (rows.length > MarkdownPdfConverter.maxTableRows) {
      _drawInline(
        '[Note: table truncated beyond ${MarkdownPdfConverter.maxTableRows} rows.]',
        _tableSize,
        PdfFontStyle.italic,
      );
      _y += 6;
    }
  }

  String _truncate(String value) {
    final v = value.replaceAll('|', r'\|').trim();
    if (v.length <= MarkdownPdfConverter.maxCellLength) return v;
    return '${v.substring(0, MarkdownPdfConverter.maxCellLength)}…';
  }

  /// Draw inline-styled runs with manual word wrapping.
  void _drawInline(
    String text,
    double size,
    PdfFontStyle defaultStyle, {
    double indent = 0,
  }) {
    final runs = _parseInline(text, defaultStyle: defaultStyle);
    _drawRuns(runs, _font(size, defaultStyle), indent: indent);
  }

  void _drawRuns(
    List<_InlineRun> runs,
    PdfFont defaultFont, {
    double indent = 0,
  }) {
    var x = _left + indent;
    for (final run in runs) {
      if (run.text == '\n') {
        x = _left + indent;
        _advanceLine(defaultFont);
        continue;
      }
      var remaining = run.text;
      final font = _font(defaultFont.size, run.style);
      final lineHeight = font.size * _lineSpacing;
      while (remaining.isNotEmpty) {
        final available = _right - x;
        final width = font.measureString(remaining).width;
        if (width <= available) {
          _graphics!.drawString(
            remaining,
            font,
            bounds: Rect.fromLTWH(x, _y, width, lineHeight),
          );
          x += width;
          remaining = '';
        } else {
          final fit = _longestFit(font, remaining, available);
          if (fit <= 0) {
            // A single glyph is wider than the line; draw it and move on.
            final ch = String.fromCharCode(remaining.runes.first);
            final w = font.measureString(ch).width;
            _graphics!.drawString(
              ch,
              font,
              bounds: Rect.fromLTWH(x, _y, w, lineHeight),
            );
            x += w;
            remaining = remaining.substring(ch.length);
            continue;
          }
          final part = remaining.substring(0, fit);
          final w = font.measureString(part).width;
          _graphics!.drawString(
            part,
            font,
            bounds: Rect.fromLTWH(x, _y, w, lineHeight),
          );
          x += w;
          remaining = remaining.substring(fit);
          x = _left + indent;
          _advanceLine(defaultFont);
          _ensureSpace(lineHeight);
        }
      }
    }
    // Move past the final line so callers' trailing spacing does not overlap
    // the last drawn line. This advance never forces a page break: the next
    // block handler runs _ensureSpace before drawing, which would otherwise
    // leave a trailing blank page when content ends near the bottom margin.
    _y += defaultFont.size * _lineSpacing;
  }

  /// Advance [_y] to the top of the next line (pure bookkeeping; page-break
  /// decisions are left to [_ensureSpace] at draw sites).
  void _advanceLine(PdfFont font) {
    _y += font.size * _lineSpacing;
  }

  /// Longest prefix of [text] that fits within [maxWidth], without splitting
  /// a UTF-16 surrogate pair (emoji) at the cut.
  int _longestFit(PdfFont font, String text, double maxWidth) {
    var low = 1;
    var high = text.length;
    var best = 0;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final width = font.measureString(text.substring(0, mid)).width;
      if (width <= maxWidth) {
        best = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    // If the prefix ends at a low surrogate, back off one unit so a surrogate
    // pair is never split mid-emoji.
    if (best > 0 &&
        best < text.length &&
        text.codeUnitAt(best) >= 0xdc00 &&
        text.codeUnitAt(best) <= 0xdfff) {
      best -= 1;
    }
    return best;
  }

  void _drawPageNumbers() {
    final pageCount = _document.pages.count;
    for (var i = 0; i < pageCount; i++) {
      final page = _document.pages[i];
      final size = page.getClientSize();
      page.graphics.drawString(
        '第 ${i + 1} 頁 / 共 $pageCount 頁',
        _font(9, PdfFontStyle.regular),
        bounds: Rect.fromLTWH(
          _margin,
          size.height - 28,
          size.width - 2 * _margin,
          16,
        ),
        format: PdfStringFormat(
          alignment: PdfTextAlignment.right,
          lineAlignment: PdfVerticalAlignment.middle,
        ),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Markdown parsing helpers
// ---------------------------------------------------------------------------

final RegExp _inlineTokenRe = RegExp(
  r'(\*\*[^*]+?\*\*|__[^_]+?__|\*[^*]+?\*|`[^`]+?`|!\[[^\]]*\]\([^)]*\)|\[[^\]]*\]\([^)]*\))',
);

final RegExp _headingRe = RegExp(r'^#{1,6}\s+(.*)$');
final RegExp _hrRe = RegExp(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$');
final RegExp _quoteRe = RegExp(r'^\s*>\s?(.*)$');
final RegExp _unorderedRe = RegExp(r'^(\s*)[-*+]\s+(.*)$');
final RegExp _orderedRe = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$');
final RegExp _tableSeparatorRe = RegExp(r'^\s*\|?[\s:|-]+\|?\s*$');

/// Parse the supported Markdown subset into blocks.
List<_MdBlock> _parseBlocks(String text) {
  final lines = text.split('\n');
  final blocks = <_MdBlock>[];
  var i = 0;

  while (i < lines.length) {
    final raw = lines[i];
    final line = raw.trimRight();

    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    // Fenced code block.
    if (line.trimLeft().startsWith('```')) {
      final buffer = <String>[];
      i++;
      while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
        buffer.add(lines[i]);
        i++;
      }
      i++; // skip the closing fence (or EOF)
      blocks.add(_MdBlock('code', buffer.join('\n')));
      continue;
    }

    // Horizontal rule.
    if (_hrRe.hasMatch(line)) {
      blocks.add(const _MdBlock('hr', ''));
      i++;
      continue;
    }

    // Table: consecutive lines starting with '|'.
    if (line.startsWith('|')) {
      final tableLines = <String>[];
      while (i < lines.length && lines[i].trim().startsWith('|')) {
        tableLines.add(lines[i]);
        i++;
      }
      final rows = <List<String>>[];
      for (final tableLine in tableLines) {
        if (_tableSeparatorRe.hasMatch(tableLine) &&
            tableLine.contains('-')) {
          continue;
        }
        var inner = tableLine.trim();
        if (inner.startsWith('|')) inner = inner.substring(1);
        if (inner.endsWith('|')) inner = inner.substring(0, inner.length - 1);
        final cells = inner
            .split('|')
            .map((c) => c.trim().replaceAll(r'\|', '|'))
            .toList();
        if (cells.isNotEmpty) rows.add(cells);
      }
      blocks.add(_MdBlock('table', '', 0, rows));
      continue;
    }

    // Heading.
    final heading = _headingRe.firstMatch(line);
    if (heading != null) {
      var title = heading.group(1)!.trim();
      title = title.replaceFirst(RegExp(r'\s+#+\s*$'), '');
      blocks.add(_MdBlock('heading', title, line.indexOf('#') + 1));
      i++;
      continue;
    }

    // Block quote: accumulate consecutive '>' lines.
    if (_quoteRe.hasMatch(line)) {
      final buffer = <String>[];
      while (i < lines.length && _quoteRe.hasMatch(lines[i])) {
        buffer.add(_quoteRe.firstMatch(lines[i])!.group(1)!.trim());
        i++;
      }
      blocks.add(_MdBlock('quote', buffer.join(' ')));
      continue;
    }

    // Unordered list item.
    final unordered = _unorderedRe.firstMatch(line);
    if (unordered != null) {
      final level = unordered.group(1)!.length ~/ 2;
      final content = _stripMarkup(unordered.group(2)!);
      blocks.add(_MdBlock('listItem', content, level));
      i++;
      continue;
    }

    // Ordered list item.
    final ordered = _orderedRe.firstMatch(line);
    if (ordered != null) {
      final level = ordered.group(1)!.length ~/ 2;
      final number = ordered.group(2)!;
      final content = _stripMarkup(ordered.group(3)!);
      blocks.add(_MdBlock('orderedItem', '$number. $content', level));
      i++;
      continue;
    }

    // Paragraph: accumulate until a blank line or another block starts.
    final buffer = <String>[line.trim()];
    i++;
    while (i < lines.length) {
      final next = lines[i].trim();
      if (next.isEmpty) break;
      if (next.startsWith('```') ||
          next.startsWith('#') ||
          next.startsWith('|') ||
          _hrRe.hasMatch(next) ||
          _quoteRe.hasMatch(next) ||
          _unorderedRe.hasMatch(next) ||
          _orderedRe.hasMatch(next)) {
        break;
      }
      buffer.add(next);
      i++;
    }
    blocks.add(_MdBlock('paragraph', buffer.join(' ')));
  }

  return blocks;
}

/// Strip Markdown emphasis markers that remain after block-level splitting.
String _stripMarkup(String text) {
  return text
      .replaceAll(RegExp(r'(\*\*|__)'), '')
      .replaceAll(RegExp(r'(?<!\*)\*(?!\*)'), '')
      .trim();
}

/// Split a text into styled runs for inline drawing.
List<_InlineRun> _parseInline(String text, {PdfFontStyle defaultStyle = PdfFontStyle.regular}) {
  final runs = <_InlineRun>[];
  var cursor = 0;
  for (final match in _inlineTokenRe.allMatches(text)) {
    if (match.start > cursor) {
      runs.add(_InlineRun(text.substring(cursor, match.start), defaultStyle));
    }
    final token = match.group(1)!;
    if (token.startsWith('**') || token.startsWith('__')) {
      runs.add(_InlineRun(token.substring(2, token.length - 2), PdfFontStyle.bold));
    } else if (token.startsWith('*')) {
      runs.add(_InlineRun(token.substring(1, token.length - 1), PdfFontStyle.italic));
    } else if (token.startsWith('`')) {
      runs.add(_InlineRun(token.substring(1, token.length - 1), defaultStyle));
    } else if (token.startsWith('![')) {
      final inner = token.substring(2, token.indexOf(']('));
      if (inner.isNotEmpty) runs.add(_InlineRun(inner, defaultStyle));
    } else {
      final inner = token.substring(1, token.indexOf(']('));
      runs.add(_InlineRun(inner, defaultStyle));
    }
    cursor = match.end;
  }
  if (cursor < text.length) {
    runs.add(_InlineRun(text.substring(cursor), defaultStyle));
  }
  return runs;
}

/// Best-effort Traditional Chinese detection to pick the CJK standard font.
bool _containsTraditional(String text) {
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    if (MarkdownPdfConverter._traditionalOnlyChars.contains(ch)) return true;
  }
  return false;
}
