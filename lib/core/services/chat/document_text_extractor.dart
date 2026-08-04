import 'dart:convert';
import 'dart:io';

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
      if (mime == 'application/vnd.openxmlformats-officedocument.wordprocessingml.document') {
        return await _extractDocx(path);
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
      for (final p in xml.findAllElements('w:p')) {
        final texts = p.findAllElements('w:t');
        if (texts.isEmpty) {
          buffer.writeln();
          continue;
        }
        for (final t in texts) {
          buffer.write(t.innerText);
        }
        buffer.writeln();
      }
      return UnicodeSanitizer.sanitize(buffer.toString());
    } catch (e) {
      return '[[Failed to parse DOCX: $e]]';
    }
  }

  // ============================================================================
  // Restricted Workspace Extraction (file_extract_text tool)
  // ============================================================================

  /// Maximum number of ZIP entries accepted inside a DOCX/PPTX container.
  static const int maxArchiveEntries = 10000;

  /// Maximum size of a single OOXML XML part parsed with the XML DOM.
  static const int maxXmlPartBytes = 4 * 1024 * 1024;

  /// Maximum number of text runs kept when extracting a single PPTX slide.
  static const int maxSlideRuns = 5000;

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
      default:
        throw const DocumentExtractionException(
          'Unsupported format. Only PDF, DOCX, and PPTX are supported.',
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
        'Unsupported file format. Only PDF, DOCX, and PPTX are supported.',
      );
    }
    final name = file.path.toLowerCase();
    if (name.endsWith('.docx')) return 'docx';
    if (name.endsWith('.pptx')) return 'pptx';
    final kind = _zipKindByContent(file);
    if (kind == null) {
      throw const DocumentExtractionException(
        'Unsupported file format. The ZIP container is not a DOCX or PPTX file.',
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
    for (final p in xml.findAllElements('w:p')) {
      final texts = p.findAllElements('w:t');
      final line = StringBuffer();
      for (final t in texts) {
        line.write(t.innerText);
      }
      if (line.isEmpty) {
        if (byteCount + 1 > maxOutputBytes) {
          truncated = true;
          break;
        }
        buffer.writeln();
        byteCount += 1;
        continue;
      }
      final block = '${line.toString().trimRight()}\n';
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

      var runsInSlide = 0;
      for (final paragraph in slideXml.findAllElements('a:p')) {
        final line = StringBuffer();
        for (final run in paragraph.findAllElements('a:r')) {
          for (final t in run.findAllElements('a:t')) {
            line.write(t.innerText);
            runsInSlide += 1;
            if (runsInSlide >= maxSlideRuns) break;
          }
          if (runsInSlide >= maxSlideRuns) break;
        }
        if (line.isEmpty) continue;
        foundText = true;
        final block = '${line.toString().trimRight()}\n';
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
  static List<int> _readEntryBounded(ArchiveFile entry, String label) {
    if (entry.size > maxXmlPartBytes) {
      throw DocumentExtractionException(
        'The $label part is too large to extract.',
      );
    }
    return entry.content;
  }
}
