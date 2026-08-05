import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';
import 'package:xml/xml.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../utils/unicode_sanitizer.dart';

/// Error raised by the restricted workspace extraction entry point.
///
/// The message is safe to return to the LLM: it never contains absolute
/// filesystem paths or parser stack traces.
class DocumentExtractionException implements Exception {
  const DocumentExtractionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Result of the restricted workspace text extraction.
class DocumentExtractionResult {
  const DocumentExtractionResult({
    required this.format,
    required this.text,
    required this.truncated,
    this.notice,
  });

  /// Resolved format: `pdf`, `docx` or `pptx`.
  final String format;

  /// Extracted text, already sanitized, bounded by the output byte cap.
  final String text;

  /// True when extraction stopped because the output byte cap was reached.
  final bool truncated;

  /// Optional plain-language note about the document (e.g. no text found).
  final String? notice;
}

class DocumentTextExtractor {
  static Future<String> extract({required String path, required String mime}) async {
    try {
      // Remap old iOS sandbox path if needed
      final fixedPath = SandboxPathResolver.fix(path);
      if (mime == 'application/pdf') {
        // All platforms: use Syncfusion for PDF text extraction
        try {
          final file = File(fixedPath);
          final bytes = await file.readAsBytes();
          final document = PdfDocument(inputBytes: bytes);
          final extractor = PdfTextExtractor(document);
          final text = UnicodeSanitizer.sanitize(extractor.extractText());
          document.dispose();
          if (text.trim().isNotEmpty) return text;
          return '[PDF] Unable to extract text from file.';
        } catch (e) {
          return '[[Failed to read PDF: $e]]';
        }
      }
      if (mime == 'application/msword') {
        return '[[DOC format (.doc) not supported for text extraction]]';
      }
      if (mime == 'application/vnd.ms-excel') {
        return '[[XLS format (.xls) not supported for text extraction]]';
      }
      if (mime == 'application/vnd.ms-powerpoint') {
        return '[[PPT format (.ppt) not supported for text extraction]]';
      }
      if (mime == 'application/vnd.openxmlformats-officedocument.wordprocessingml.document') {
        return await _extractDocx(path);
      }
      if (mime ==
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet') {
        return await _extractXlsx(path);
      }
      // Fallback: read as text
      final file = File(fixedPath);
      final bytes = await file.readAsBytes();
      return UnicodeSanitizer.sanitize(utf8.decode(bytes, allowMalformed: true));
    } catch (e) {
      return '[[Failed to read file: $e]]';
    }
  }

  static Future<String> _extractDocx(String path) async {
    try {
      final input = File(SandboxPathResolver.fix(path)).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(input);
      final docXml = archive.findFile('word/document.xml');
      if (docXml == null) return '[DOCX] document.xml not found';
      final xml = XmlDocument.parse(utf8.decode(docXml.content as List<int>));
      final buffer = StringBuffer();
      for (final line in _docxBlockLines(xml)) {
        buffer.writeln(line);
      }
      return UnicodeSanitizer.sanitize(buffer.toString());
    } catch (e) {
      return '[[Failed to parse DOCX: $e]]';
    }
  }

  /// Extract readable text from an XLSX workbook attached to a chat message.
  ///
  /// Mirrors [_extractDocx]: no workspace boundary checks here because the
  /// file was already selected/uploaded by the user, and (like the legacy
  /// attachment extractors) no input-size cap is applied.
  static Future<String> _extractXlsx(String path) async {
    try {
      final input = File(SandboxPathResolver.fix(path)).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(input);
      final workbook = archive.findFile('xl/workbook.xml');
      if (workbook == null) return '[XLSX] workbook.xml not found';
      final rels = archive.findFile('xl/_rels/workbook.xml.rels');
      if (rels == null) return '[XLSX] workbook rels not found';

      final List<String> sharedStrings;
      final shared = archive.findFile('xl/sharedStrings.xml');
      if (shared == null) {
        sharedStrings = const [];
      } else {
        sharedStrings = _xlsxSharedStrings(
          XmlDocument.parse(utf8.decode(shared.content as List<int>)),
        );
      }
      final sheetRefs = _workbookSheets(
        XmlDocument.parse(utf8.decode(workbook.content as List<int>)),
      );
      final targetByRelId = _worksheetTargets(
        XmlDocument.parse(utf8.decode(rels.content as List<int>)),
      );

      final buffer = StringBuffer();
      var sheetNumber = 0;
      for (final ref in sheetRefs) {
        final target = targetByRelId[ref.relId];
        if (target == null || !target.endsWith('.xml')) continue;
        final sheetPath = _resolveXlsxSheetPath(target);
        if (sheetPath == null) continue;
        final entry = archive.findFile(sheetPath);
        if (entry == null) continue;
        final sheetXml = XmlDocument.parse(
          utf8.decode(entry.content as List<int>),
        );
        final lines = _sheetTableLines(sheetXml, sharedStrings).toList();
        if (lines.isEmpty) continue;
        sheetNumber += 1;
        buffer.writeln('--- Sheet $sheetNumber (${ref.name}) ---');
        for (final line in lines) {
          buffer.writeln(line);
        }
      }
      final text = buffer.toString();
      if (text.trim().isEmpty) {
        return '[XLSX] No readable cell text found.';
      }
      return UnicodeSanitizer.sanitize(text);
    } catch (e) {
      return '[[Failed to parse XLSX: $e]]';
    }
  }

  // ============================================================================
  // Restricted Workspace Extraction (file_extract_text tool)
  // ============================================================================

  /// Maximum number of ZIP entries accepted inside a DOCX/PPTX container.
  static const int maxArchiveEntries = 10000;

  /// Maximum size of a single OOXML XML part parsed with the XML DOM.
  static const int maxXmlPartBytes = 4 * 1024 * 1024;

  /// Maximum size of the XLSX shared string table part.
  ///
  /// Real-world workbooks frequently exceed the general XML part cap here, and
  /// the container is already fully decompressed in memory by the time this
  /// check runs, so this part may grow up to the workspace input limit.
  static const int maxXlsxSharedStringsBytes = 16 * 1024 * 1024;

  /// Maximum number of text runs kept when extracting a single PPTX slide.
  static const int maxSlideRuns = 5000;

  /// Maximum characters kept for one cell when rendering Markdown tables.
  static const int maxTableCellChars = 200;

  /// Maximum columns rendered for one Markdown table.
  static const int maxTableColumns = 50;

  /// Extract text from a PDF, DOCX, or PPTX file that has already been
  /// resolved and verified by [FileToolService.resolveSafePath].
  ///
  /// This entry point never accepts a raw LLM path and never widens the
  /// workspace boundary. It returns text only, bounded by [maxOutputBytes].
  static Future<DocumentExtractionResult> extractWorkspaceText({
    required String safePath,
    required String format,
    required int maxInputBytes,
    required int maxOutputBytes,
  }) async {
    final file = File(safePath);
    if (!await file.exists()) {
      throw const DocumentExtractionException('File not found.');
    }
    final length = await file.length();
    if (length > maxInputBytes) {
      throw const DocumentExtractionException(
        'The file is too large to extract.',
      );
    }

    final resolved = format == 'auto'
        ? await _detectFormat(file, length)
        : format.toLowerCase();
    switch (resolved) {
      case 'pdf':
        return await _extractPdfWorkspace(
          file,
          maxOutputBytes: maxOutputBytes,
        );
      case 'docx':
        return _extractDocxWorkspace(file, maxOutputBytes: maxOutputBytes);
      case 'pptx':
        return _extractPptxWorkspace(file, maxOutputBytes: maxOutputBytes);
      case 'xlsx':
        return _extractXlsxWorkspace(file, maxOutputBytes: maxOutputBytes);
      default:
        throw const DocumentExtractionException(
          'Unsupported format. Only PDF, DOCX, PPTX, and XLSX are supported.',
        );
    }
  }

  /// Detect the document format from the file signature first, then from the
  /// ZIP layout (DOCX vs PPTX) as a tiebreaker.
  static Future<String> _detectFormat(File file, int length) async {
    final handle = await file.open();
    late final List<int> head;
    try {
      head = await handle.read(8);
    } finally {
      await handle.close();
    }
    if (_isPdfSignature(head)) return 'pdf';
    if (!_isZipSignature(head)) {
      throw const DocumentExtractionException(
        'Unsupported file format. Only PDF, DOCX, PPTX, and XLSX are supported.',
      );
    }
    final name = file.path.toLowerCase();
    if (name.endsWith('.docx')) return 'docx';
    if (name.endsWith('.pptx')) return 'pptx';
    if (name.endsWith('.xlsx')) return 'xlsx';
    final kind = _zipKindByContent(file);
    if (kind == null) {
      throw const DocumentExtractionException(
        'Unsupported file format. The ZIP container is not a DOCX, PPTX, or XLSX file.',
      );
    }
    return kind;
  }

  static bool _isPdfSignature(List<int> head) {
    return head.length >= 5 &&
        head[0] == 0x25 &&
        head[1] == 0x50 &&
        head[2] == 0x44 &&
        head[3] == 0x46;
  }

  static bool _isZipSignature(List<int> head) {
    return head.length >= 4 &&
        head[0] == 0x50 &&
        head[1] == 0x4b &&
        (head[2] == 0x03 || head[2] == 0x05 || head[2] == 0x07);
  }

  static String? _zipKindByContent(File file) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
    } catch (_) {
      return null;
    }
    if (archive.findFile('word/document.xml') != null) return 'docx';
    if (archive.findFile('ppt/presentation.xml') != null) return 'pptx';
    if (archive.findFile('xl/workbook.xml') != null) return 'xlsx';
    return null;
  }

  // --------------------------------------------------------------------------
  // PDF
  // --------------------------------------------------------------------------

  static Future<DocumentExtractionResult> _extractPdfWorkspace(
    File file, {
    required int maxOutputBytes,
  }) async {
    final bytes = await file.readAsBytes();
    if (!_isPdfSignature(bytes)) {
      throw const DocumentExtractionException('The file is not a valid PDF.');
    }
    PdfDocument? document;
    try {
      document = PdfDocument(inputBytes: bytes);
      final extractor = PdfTextExtractor(document);
      final pageCount = document.pages.count;
      final buffer = StringBuffer();
      var byteCount = 0;
      var truncated = false;
      var foundText = false;
      for (var i = 0; i < pageCount; i++) {
        final pageText = UnicodeSanitizer.sanitize(
          extractor.extractText(startPageIndex: i, endPageIndex: i),
        );
        final hasPageText = pageText.trim().isNotEmpty;
        if (hasPageText) foundText = true;
        final marker = '--- Page ${i + 1} ---\n';
        final markerBytes = utf8.encode(marker).length;
        if (byteCount + markerBytes > maxOutputBytes) {
          truncated = true;
          break;
        }
        buffer.write(marker);
        byteCount += markerBytes;
        if (hasPageText) {
          final block = '${pageText.trimRight()}\n';
          final blockBytes = utf8.encode(block).length;
          if (byteCount + blockBytes > maxOutputBytes) {
            truncated = true;
            break;
          }
          buffer.write(block);
          byteCount += blockBytes;
        }
      }
      final text = buffer.toString();
      if (!foundText) {
        return DocumentExtractionResult(
          format: 'pdf',
          text: '',
          truncated: truncated,
          notice:
              'The PDF contains no extractable text (possibly scanned images).',
        );
      }
      return DocumentExtractionResult(
        format: 'pdf',
        text: text,
        truncated: truncated,
      );
    } catch (_) {
      throw const DocumentExtractionException(
        'The PDF could not be parsed.',
      );
    } finally {
      // Always release the native PDF document, even on failure.
      document?.dispose();
    }
  }

  // --------------------------------------------------------------------------
  // DOCX
  // --------------------------------------------------------------------------

  static DocumentExtractionResult _extractDocxWorkspace(
    File file, {
    required int maxOutputBytes,
  }) {
    final bytes = file.readAsBytesSync();
    if (!_isZipSignature(bytes)) {
      throw const DocumentExtractionException(
        'The file is not a valid DOCX (ZIP) file.',
      );
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const DocumentExtractionException(
        'The DOCX file is malformed or corrupt.',
      );
    }
    _checkArchiveLimits(archive);
    final docXml = archive.findFile('word/document.xml');
    if (docXml == null) {
      throw const DocumentExtractionException(
        'The DOCX file is missing word/document.xml.',
      );
    }
    final xmlBytes = _readEntryBounded(docXml, 'word/document.xml');
    final XmlDocument xml;
    try {
      xml = XmlDocument.parse(utf8.decode(xmlBytes));
    } catch (_) {
      throw const DocumentExtractionException(
        'The DOCX document.xml could not be parsed.',
      );
    }
    final buffer = StringBuffer();
    var byteCount = 0;
    var truncated = false;
    for (final line in _docxBlockLines(xml)) {
      final block = line.isEmpty ? '\n' : '${line.trimRight()}\n';
      final blockBytes = utf8.encode(block).length;
      if (byteCount + blockBytes > maxOutputBytes) {
        truncated = true;
        break;
      }
      buffer.write(block);
      byteCount += blockBytes;
    }
    return DocumentExtractionResult(
      format: 'docx',
      text: UnicodeSanitizer.sanitize(buffer.toString()),
      truncated: truncated,
    );
  }

  /// Yield DOCX text lines in document order, converting `<w:tbl>` elements to
  /// Markdown table lines. Paragraphs living inside tables are skipped because
  /// the table renderer already consumes them, while paragraphs nested in
  /// other containers (`w:sdt` content controls, `w:txbxContent` text boxes)
  /// are preserved.
  static Iterable<String> _docxBlockLines(XmlDocument xml) sync* {
    for (final element in xml.descendants.whereType<XmlElement>()) {
      final local = element.name.local;
      if (local == 'tbl') {
        final rows = <List<String>>[];
        for (final tr in element.findElements('w:tr')) {
          final cells = <String>[];
          for (final tc in tr.findElements('w:tc')) {
            final buffer = StringBuffer();
            for (final t in tc.findAllElements('w:t')) {
              buffer.write(t.innerText);
            }
            cells.add(buffer.toString().trim());
          }
          if (cells.isNotEmpty) rows.add(cells);
        }
        yield* _tableToMarkdown(rows);
        continue;
      }
      if (local != 'p') continue;
      if (_hasAncestorWithLocal(element, 'tbl')) continue;
      final texts = element.findAllElements('w:t');
      if (texts.isEmpty) {
        yield '';
        continue;
      }
      final line = StringBuffer();
      for (final t in texts) {
        line.write(t.innerText);
      }
      yield line.toString().trimRight();
    }
  }

  // --------------------------------------------------------------------------
  // PPTX
  // --------------------------------------------------------------------------

  static DocumentExtractionResult _extractPptxWorkspace(
    File file, {
    required int maxOutputBytes,
  }) {
    final bytes = file.readAsBytesSync();
    if (!_isZipSignature(bytes)) {
      throw const DocumentExtractionException(
        'The file is not a valid PPTX (ZIP) file.',
      );
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const DocumentExtractionException(
        'The PPTX file is malformed or corrupt.',
      );
    }
    _checkArchiveLimits(archive);

    final presentation = archive.findFile('ppt/presentation.xml');
    if (presentation == null) {
      throw const DocumentExtractionException(
        'The PPTX file is missing ppt/presentation.xml.',
      );
    }
    final rels = archive.findFile('ppt/_rels/presentation.xml.rels');
    if (rels == null) {
      throw const DocumentExtractionException(
        'The PPTX file is missing its presentation relationships.',
      );
    }

    final List<String> slideRelIds;
    try {
      slideRelIds = _slideRelationshipIds(
        XmlDocument.parse(utf8.decode(_readEntryBounded(
          presentation,
          'ppt/presentation.xml',
        ))),
      );
    } catch (_) {
      throw const DocumentExtractionException(
        'The PPTX presentation.xml could not be parsed.',
      );
    }
    if (slideRelIds.isEmpty) {
      throw const DocumentExtractionException(
        'The PPTX file contains no slides.',
      );
    }
    final Map<String, String> targetByRelId;
    try {
      targetByRelId = _relationshipTargets(
        XmlDocument.parse(
          utf8.decode(_readEntryBounded(rels, 'presentation rels')),
        ),
      );
    } catch (_) {
      throw const DocumentExtractionException(
        'The PPTX presentation relationships could not be parsed.',
      );
    }
    if (targetByRelId.isEmpty) {
      throw const DocumentExtractionException(
        'The PPTX presentation relationships contain no slide entries.',
      );
    }

    final buffer = StringBuffer();
    var byteCount = 0;
    var truncated = false;
    var foundText = false;
    var slideNumber = 0;
    for (final relId in slideRelIds) {
      final target = targetByRelId[relId];
      if (target == null || !target.endsWith('.xml')) continue;
      if (target.contains('..')) continue;
      final slidePath = target.startsWith('/')
          ? target.substring(1)
          : 'ppt/$target';
      final entry = archive.findFile(slidePath);
      if (entry == null) continue;
      slideNumber += 1;
      final XmlDocument slideXml;
      try {
        slideXml = XmlDocument.parse(
          utf8.decode(_readEntryBounded(entry, slidePath)),
        );
      } catch (_) {
        // Skip malformed slides instead of failing the whole extraction.
        continue;
      }
      final marker = '--- Slide $slideNumber ---\n';
      final markerBytes = utf8.encode(marker).length;
      if (byteCount + markerBytes > maxOutputBytes) {
        truncated = true;
        break;
      }
      buffer.write(marker);
      byteCount += markerBytes;

      final runCounter = <int>[0];
      for (final line in _pptxBlockLines(slideXml, runCounter, maxSlideRuns)) {
        if (line.isEmpty) continue;
        foundText = true;
        final block = '${line.trimRight()}\n';
        final blockBytes = utf8.encode(block).length;
        if (byteCount + blockBytes > maxOutputBytes) {
          truncated = true;
          break;
        }
        buffer.write(block);
        byteCount += blockBytes;
      }
      if (truncated) break;
    }

    final text = buffer.toString();
    if (!foundText) {
      return DocumentExtractionResult(
        format: 'pptx',
        text: '',
        truncated: truncated,
        notice: 'The presentation contains no visible slide text.',
      );
    }
    return DocumentExtractionResult(
      format: 'pptx',
      text: UnicodeSanitizer.sanitize(text),
      truncated: truncated,
    );
  }

  /// Yield PPTX text lines in document order, converting `<a:tbl>` elements to
  /// Markdown table lines and skipping paragraphs that live inside tables.
  ///
  /// [runCounter] is mutated to enforce [maxRuns] per slide, mirroring the
  /// original text-run cap.
  static Iterable<String> _pptxBlockLines(
    XmlDocument slideXml,
    List<int> runCounter,
    int maxRuns,
  ) sync* {
    for (final element in slideXml.descendants.whereType<XmlElement>()) {
      if (runCounter[0] >= maxRuns) break;
      final local = element.name.local;
      if (local == 'tbl') {
        final rows = <List<String>>[];
        for (final tr in element.findElements('a:tr')) {
          final cells = <String>[];
          for (final tc in tr.findElements('a:tc')) {
            final buffer = StringBuffer();
            for (final t in tc.findAllElements('a:t')) {
              buffer.write(t.innerText);
            }
            cells.add(buffer.toString().trim());
          }
          if (cells.isNotEmpty) rows.add(cells);
        }
        yield* _tableToMarkdown(rows);
        continue;
      }
      if (local != 'p') continue;
      if (_hasAncestorWithLocal(element, 'tbl')) continue;
      final line = StringBuffer();
      for (final t in element.findAllElements('a:t')) {
        line.write(t.innerText);
        runCounter[0] += 1;
        if (runCounter[0] >= maxRuns) break;
      }
      final text = line.toString().trimRight();
      if (text.isNotEmpty) yield text;
    }
  }

  static bool _hasAncestorWithLocal(XmlElement element, String localName) {
    for (final ancestor in element.ancestors.whereType<XmlElement>()) {
      if (ancestor.name.local == localName) return true;
    }
    return false;
  }

  /// Render collected table rows as Markdown table lines, padding sparse rows
  /// and truncating oversized cells.
  static List<String> _tableToMarkdown(List<List<String>> rows) {
    if (rows.isEmpty) return const <String>[];
    var maxCols = 0;
    for (final row in rows) {
      maxCols = math.max(maxCols, row.length);
    }
    maxCols = math.min(maxCols, maxTableColumns);
    final lines = <String>[];
    for (var i = 0; i < rows.length; i++) {
      final cells = <String>[];
      for (var c = 0; c < maxCols; c++) {
        final raw = c < rows[i].length ? rows[i][c] : '';
        cells.add(_markdownCell(raw));
      }
      lines.add('| ${cells.join(' | ')} |');
      if (i == 0) {
        lines.add('|${List<String>.filled(maxCols, '---').join('|')}|');
      }
    }
    return lines;
  }

  static String _markdownCell(String text) {
    var value = text.replaceAll('|', r'\|').replaceAll('\n', ' ').trim();
    if (value.length > maxTableCellChars) {
      value = '${value.substring(0, maxTableCellChars)}…';
    }
    return value;
  }

  /// Read `p:sldId` relationship ids in document order from `p:sldIdLst`.
  static List<String> _slideRelationshipIds(XmlDocument presentation) {
    final ids = <String>[];
    for (final sldIdLst in presentation.findAllElements('p:sldIdLst')) {
      for (final sldId in sldIdLst.findElements('p:sldId')) {
        final relId = sldId.getAttribute('r:id');
        if (relId != null && relId.isNotEmpty) ids.add(relId);
      }
    }
    return ids;
  }

  /// Map relationship `Id` values to their `Target` paths.
  static Map<String, String> _relationshipTargets(XmlDocument rels) {
    final targets = <String, String>{};
    for (final relationship in rels.findAllElements('Relationship')) {
      final id = relationship.getAttribute('Id');
      final target = relationship.getAttribute('Target');
      if (id != null && id.isNotEmpty && target != null && target.isNotEmpty) {
        targets[id] = target;
      }
    }
    return targets;
  }

  // --------------------------------------------------------------------------
  // XLSX
  // --------------------------------------------------------------------------

  static DocumentExtractionResult _extractXlsxWorkspace(
    File file, {
    required int maxOutputBytes,
  }) {
    final bytes = file.readAsBytesSync();
    if (!_isZipSignature(bytes)) {
      throw const DocumentExtractionException(
        'The file is not a valid XLSX (ZIP) file.',
      );
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const DocumentExtractionException(
        'The XLSX file is malformed or corrupt.',
      );
    }
    _checkArchiveLimits(archive);

    final workbook = archive.findFile('xl/workbook.xml');
    if (workbook == null) {
      throw const DocumentExtractionException(
        'The XLSX file is missing xl/workbook.xml.',
      );
    }
    final rels = archive.findFile('xl/_rels/workbook.xml.rels');
    if (rels == null) {
      throw const DocumentExtractionException(
        'The XLSX file is missing its workbook relationships.',
      );
    }

    final List<_XlsxSheetRef> sheetRefs;
    try {
      sheetRefs = _workbookSheets(
        XmlDocument.parse(
          utf8.decode(_readEntryBounded(workbook, 'xl/workbook.xml')),
        ),
      );
    } catch (_) {
      throw const DocumentExtractionException(
        'The XLSX workbook.xml could not be parsed.',
      );
    }
    if (sheetRefs.isEmpty) {
      throw const DocumentExtractionException(
        'The XLSX file contains no worksheets.',
      );
    }

    final Map<String, String> targetByRelId;
    try {
      targetByRelId = _worksheetTargets(
        XmlDocument.parse(
          utf8.decode(_readEntryBounded(rels, 'workbook rels')),
        ),
      );
    } catch (_) {
      throw const DocumentExtractionException(
        'The XLSX workbook relationships could not be parsed.',
      );
    }

    // sharedStrings.xml is optional in valid workbooks (e.g. numeric-only
    // files); treat a missing part as an empty shared string table.
    final List<String> sharedStrings;
    final shared = archive.findFile('xl/sharedStrings.xml');
    if (shared == null) {
      sharedStrings = const [];
    } else {
      try {
        sharedStrings = _xlsxSharedStrings(
          XmlDocument.parse(
            utf8.decode(
              _readEntryBounded(
                shared,
                'xl/sharedStrings.xml',
                maxBytes: maxXlsxSharedStringsBytes,
              ),
            ),
          ),
        );
      } catch (_) {
        throw const DocumentExtractionException(
          'The XLSX sharedStrings.xml could not be parsed.',
        );
      }
    }

    final buffer = StringBuffer();
    var byteCount = 0;
    var truncated = false;
    var foundText = false;
    // Numbers only sheets that actually produced text, like the PPTX slide
    // numbering; empty worksheets are skipped without consuming a number.
    var sheetNumber = 0;
    for (final ref in sheetRefs) {
      final target = targetByRelId[ref.relId];
      if (target == null || !target.endsWith('.xml')) continue;
      final sheetPath = _resolveXlsxSheetPath(target);
      if (sheetPath == null) continue;
      final entry = archive.findFile(sheetPath);
      if (entry == null) continue;
      final XmlDocument sheetXml;
      try {
        sheetXml = XmlDocument.parse(
          utf8.decode(_readEntryBounded(entry, sheetPath)),
        );
      } catch (_) {
        // Skip malformed worksheets instead of failing the whole extraction.
        continue;
      }

      var markerWritten = false;
      for (final line in _sheetTableLines(sheetXml, sharedStrings)) {
        if (!markerWritten) {
          final nextNumber = sheetNumber + 1;
          final marker = '--- Sheet $nextNumber (${ref.name}) ---\n';
          final markerBytes = utf8.encode(marker).length;
          if (byteCount + markerBytes > maxOutputBytes) {
            truncated = true;
            break;
          }
          buffer.write(marker);
          byteCount += markerBytes;
          sheetNumber = nextNumber;
          markerWritten = true;
        }
        final block = '$line\n';
        final blockBytes = utf8.encode(block).length;
        if (byteCount + blockBytes > maxOutputBytes) {
          truncated = true;
          break;
        }
        buffer.write(block);
        byteCount += blockBytes;
        foundText = true;
      }
      if (truncated) break;
    }

    final text = buffer.toString();
    if (!foundText) {
      return DocumentExtractionResult(
        format: 'xlsx',
        text: '',
        truncated: truncated,
        notice: 'The workbook contains no cell text or values.',
      );
    }
    return DocumentExtractionResult(
      format: 'xlsx',
      text: UnicodeSanitizer.sanitize(text),
      truncated: truncated,
    );
  }

  /// Read `<sheet>` elements in document order from `xl/workbook.xml`.
  static List<_XlsxSheetRef> _workbookSheets(XmlDocument workbook) {
    final sheets = <_XlsxSheetRef>[];
    for (final sheet in workbook.findAllElements('sheet')) {
      final name = _attributeLocal(sheet, 'name');
      final relId = _attributeLocal(sheet, 'id');
      if (relId.isEmpty) continue;
      sheets.add(_XlsxSheetRef(name: name, relId: relId));
    }
    return sheets;
  }

  /// Map worksheet relationship ids to their target paths.
  static Map<String, String> _worksheetTargets(XmlDocument rels) {
    final targets = <String, String>{};
    for (final relationship in rels.findAllElements('Relationship')) {
      final id = _attributeLocal(relationship, 'Id');
      final target = _attributeLocal(relationship, 'Target');
      final type = _attributeLocal(relationship, 'Type');
      if (id.isEmpty || target.isEmpty) continue;
      // Only worksheets carry cell data; ignore chartsheets/macrosheets.
      if (type.isNotEmpty && !type.contains('/worksheet')) continue;
      targets[id] = target;
    }
    return targets;
  }

  /// Parse the shared string table into an indexed list of strings.
  static List<String> _xlsxSharedStrings(XmlDocument shared) {
    final strings = <String>[];
    for (final si in shared.findAllElements('si')) {
      strings.add(_richText(si));
    }
    return strings;
  }

  /// Concatenate `t` text in document order, excluding phonetic runs (`rPh`).
  static String _richText(XmlElement parent) {
    final buffer = StringBuffer();
    for (final t in parent.findElements('t')) {
      buffer.write(t.innerText);
    }
    for (final r in parent.findElements('r')) {
      for (final t in r.findElements('t')) {
        buffer.write(t.innerText);
      }
    }
    return buffer.toString();
  }

  /// Yield one Markdown table line per worksheet row that has at least one
  /// non-empty cell. Column positions are preserved from cell references so
  /// sparse rows render as `| a |  | b |` instead of collapsing.
  static Iterable<String> _sheetTableLines(
    XmlDocument sheetXml,
    List<String> sharedStrings,
  ) sync* {
    final rows = <List<String>>[];
    for (final row in sheetXml.findAllElements('row')) {
      final cells = <String>[];
      var position = 0;
      for (final cell in row.findElements('c')) {
        final ref = _attributeLocal(cell, 'r');
        final index = _cellColumnIndex(ref, position);
        final text = _cellText(cell, sharedStrings);
        while (cells.length < index) {
          cells.add('');
        }
        cells.add(text);
        position = index + 1;
      }
      if (cells.every((c) => c.isEmpty)) continue;
      rows.add(cells);
    }
    yield* _tableToMarkdown(rows);
  }

  /// Zero-based column index parsed from a cell reference like `C4`; falls
  /// back to the positional index when the reference is missing.
  static int _cellColumnIndex(String ref, int positional) {
    var letters = '';
    for (final rune in ref.runes) {
      final ch = String.fromCharCode(rune);
      final code = ch.codeUnitAt(0);
      if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122)) {
        letters += ch.toUpperCase();
      } else {
        break;
      }
    }
    if (letters.isEmpty) return positional;
    var column = 0;
    for (final ch in letters.split('')) {
      column = column * 26 + (ch.codeUnitAt(0) - 64);
    }
    return column - 1;
  }

  /// Extract the value of a single `<c>` cell.
  static String _cellText(XmlElement cell, List<String> sharedStrings) {
    final type = _attributeLocal(cell, 't');
    if (type == 'inlineStr') {
      final isElements = cell.findElements('is');
      if (isElements.isEmpty) return '';
      return _richText(isElements.first);
    }
    if (type == 's') {
      final v = _firstChildText(cell, 'v');
      if (v == null) return '';
      final index = int.tryParse(v.trim());
      if (index == null || index < 0 || index >= sharedStrings.length) {
        return '';
      }
      return sharedStrings[index];
    }
    if (type == 'b') {
      final v = _firstChildText(cell, 'v')?.trim() ?? '';
      if (v == '1') return 'TRUE';
      if (v == '0') return 'FALSE';
      return v;
    }
    // Numbers (no 't' or 'n'), formula string results ('str'), ISO dates
    // ('d'), and error values ('e') all carry their text in <v>.
    return _firstChildText(cell, 'v')?.trim() ?? '';
  }

  static String? _firstChildText(XmlElement parent, String name) {
    for (final child in parent.findElements(name)) {
      return child.innerText;
    }
    return null;
  }

  /// Read an attribute by its local name, ignoring the namespace prefix.
  static String _attributeLocal(XmlElement element, String localName) {
    for (final attribute in element.attributes) {
      if (attribute.name.local == localName) return attribute.value;
    }
    return '';
  }

  /// Resolve a workbook-relationship target to an archive path under `xl/`.
  static String? _resolveXlsxSheetPath(String target) {
    if (target.contains('..')) return null;
    var path = target;
    if (path.startsWith('/')) path = path.substring(1);
    path = path.replaceAll('\\', '/');
    if (path.startsWith('xl/')) return path;
    return 'xl/$path';
  }

  // --------------------------------------------------------------------------
  // Shared bounds
  // --------------------------------------------------------------------------

  static void _checkArchiveLimits(Archive archive) {
    if (archive.files.length > maxArchiveEntries) {
      throw const DocumentExtractionException(
        'The archive contains too many entries.',
      );
    }
  }

  /// Return the decompressed bytes of an archive entry only when it is within
  /// the XML part size limit. Never writes the entry to disk.
  static List<int> _readEntryBounded(
    ArchiveFile entry,
    String label, {
    int maxBytes = maxXmlPartBytes,
  }) {
    if (entry.size > maxBytes) {
      throw DocumentExtractionException(
        'The $label part is too large to extract.',
      );
    }
    return entry.content;
  }
}

/// One `<sheet>` entry from `xl/workbook.xml`.
class _XlsxSheetRef {
  const _XlsxSheetRef({required this.name, required this.relId});

  final String name;
  final String relId;
}
