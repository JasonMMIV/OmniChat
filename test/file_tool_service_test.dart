import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/chat/document_text_extractor.dart';
import 'package:OmniChat/core/services/file/file_tool_service.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('omnichat_file_tools_');
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  test('rejects traversal and absolute paths', () {
    expect(
      () => FileToolService.resolveSafePath('../outside.txt', workspace.path),
      throwsA(isA<FileToolSecurityException>()),
    );
    expect(
      () => FileToolService.resolveSafePath(
        Directory.systemTemp.path,
        workspace.path,
      ),
      throwsA(isA<FileToolSecurityException>()),
    );
  });

  test('writes, reads, appends, and enforces byte limits', () async {
    final write = await FileToolService.execute('file_write', {
      'path': 'notes/hello.txt',
      'content': 'hello',
    }, workspace.path);
    expect(write.createdOrModifiedFilePath, isNotNull);
    expect(
      await File('${workspace.path}/notes/hello.txt').readAsString(),
      'hello',
    );

    final missingContent = await FileToolService.execute('file_write', {
      'path': 'notes/hello.txt',
    }, workspace.path);
    expect(missingContent.text, contains('content argument'));
    expect(
      await File('${workspace.path}/notes/hello.txt').readAsString(),
      'hello',
    );

    final append = await FileToolService.execute('file_append', {
      'path': 'notes/hello.txt',
      'content': ' world',
    }, workspace.path);
    expect(append.text, contains('Appended'));
    expect(
      await File('${workspace.path}/notes/hello.txt').readAsString(),
      'hello world',
    );

    final oversized = await FileToolService.execute('file_write', {
      'path': 'too-large.txt',
      'content': 'x' * (FileToolService.maxWriteBytes + 1),
    }, workspace.path);
    expect(oversized.text, contains('512 KB'));
    expect(File('${workspace.path}/too-large.txt').existsSync(), isFalse);
  });

  test('reads bounded segments and supports continuation offsets', () async {
    final file = File('${workspace.path}/large.txt');
    await file.writeAsBytes(
      utf8.encode('x' * (FileToolService.maxReadBytes + 10)),
    );

    final result = await FileToolService.execute('file_read', {
      'path': 'large.txt',
    }, workspace.path);
    expect(result.text, contains('has_more=true'));
    expect(result.text, contains('next_offset='));
    expect(
      utf8.encode(result.text).length,
      lessThan(FileToolService.defaultReadBytes + 200),
    );

    final capped = await FileToolService.execute('file_read', {
      'path': 'large.txt',
      'limit': FileToolService.maxReadBytes + 1,
    }, workspace.path);
    expect(capped.text, contains('limit capped'));
    expect(capped.text, contains('has_more=true'));

    final first = await FileToolService.execute('file_read', {
      'path': 'large.txt',
      'limit': 10,
    }, workspace.path);
    expect(first.text, contains('next_offset=10'));
    final second = await FileToolService.execute('file_read', {
      'path': 'large.txt',
      'offset': 10,
      'limit': 10,
    }, workspace.path);
    expect(second.text, contains('Read bytes 10-20'));
  });

  test('does not split a UTF-8 code point at a segment boundary', () async {
    final file = File('${workspace.path}/unicode.txt');
    await file.writeAsString('A😀B');

    // The emoji occupies bytes 1..4. Offset 2 is in the middle of it, so the
    // reader advances to the next complete code point instead of returning a
    // replacement character.
    final result = await FileToolService.execute('file_read', {
      'path': 'unicode.txt',
      'offset': 2,
      'limit': 10,
    }, workspace.path);
    expect(result.text, contains('\nB'));
    expect(result.text, isNot(contains('\uFFFD')));

    final tinyLimit = await FileToolService.execute('file_read', {
      'path': 'unicode.txt',
      'offset': 1,
      'limit': 1,
    }, workspace.path);
    expect(tinyLimit.text, contains('\n😀'));
    expect(tinyLimit.text, contains('next_offset=5'));
  });

  test('exposes edit and patch tools in the definition list', () {
    final names = FileToolService.getToolDefinitions()
        .map((definition) => definition['function']['name'])
        .toSet();
    expect(names, containsAll(<String>['file_edit', 'file_patch']));
  });

  test('edits exact text and rejects ambiguous matches', () async {
    final file = File('${workspace.path}/edit.txt');
    await file.writeAsString('one\ntwo\ntwo\n');

    final ambiguous = await FileToolService.execute('file_edit', {
      'path': 'edit.txt',
      'old_text': 'two',
      'new_text': 'TWO',
    }, workspace.path);
    expect(ambiguous.text, contains('matched 2 times'));
    expect(await file.readAsString(), 'one\ntwo\ntwo\n');

    final unique = await FileToolService.execute('file_edit', {
      'path': 'edit.txt',
      'old_text': 'one',
      'new_text': 'ONE',
    }, workspace.path);
    expect(unique.createdOrModifiedFilePath, isNotNull);
    expect(await file.readAsString(), 'ONE\ntwo\ntwo\n');

    final all = await FileToolService.execute('file_edit', {
      'path': 'edit.txt',
      'old_text': 'two',
      'new_text': 'TWO',
      'replace_all': true,
    }, workspace.path);
    expect(all.text, contains('Edited'));
    expect(await file.readAsString(), 'ONE\nTWO\nTWO\n');
  });

  test(
    'rejects oversized edit arguments before building a replacement',
    () async {
      final file = File('${workspace.path}/bounded-edit.txt');
      await file.writeAsString('unchanged');

      final result = await FileToolService.execute('file_edit', {
        'path': 'bounded-edit.txt',
        'old_text': 'unchanged',
        'new_text': 'x' * (FileToolService.maxWriteBytes + 1),
      }, workspace.path);
      expect(result.text, contains('edit text arguments'));
      expect(await file.readAsString(), 'unchanged');
    },
  );

  test('applies a single-file unified patch and preserves CRLF', () async {
    final file = File('${workspace.path}/patch.txt');
    await file.writeAsBytes(utf8.encode('one\r\ntwo\r\nthree\r\n'));
    const patch =
        '--- a/patch.txt\n'
        '+++ b/patch.txt\n'
        '@@ -1,3 +1,3 @@\n'
        ' one\n'
        '-two\n'
        '+TWO\n'
        ' three\n';

    final result = await FileToolService.execute('file_patch', {
      'path': 'patch.txt',
      'patch': patch,
    }, workspace.path);
    expect(result.createdOrModifiedFilePath, isNotNull);
    expect(await file.readAsString(), 'one\r\nTWO\r\nthree\r\n');
  });

  test('does not modify a file when patch context does not match', () async {
    final file = File('${workspace.path}/stale.txt');
    await file.writeAsString('one\ntwo\n');
    const patch =
        '@@ -1,2 +1,2 @@\n'
        ' wrong\n'
        '-two\n'
        '+TWO\n';

    final result = await FileToolService.execute('file_patch', {
      'path': 'stale.txt',
      'patch': patch,
    }, workspace.path);
    expect(result.text, contains('context did not match'));
    expect(await file.readAsString(), 'one\ntwo\n');
  });

  test('preserves unified patch newline metadata in both directions', () async {
    final addNewline = File('${workspace.path}/add-newline.txt');
    await addNewline.writeAsString('old');
    const addNewlinePatch =
        '@@ -1 +1 @@\n'
        '-old\n'
        '\\ No newline at end of file\n'
        '+new\n';
    await FileToolService.execute('file_patch', {
      'path': 'add-newline.txt',
      'patch': addNewlinePatch,
    }, workspace.path);
    expect(await addNewline.readAsString(), 'new\n');

    final removeNewline = File('${workspace.path}/remove-newline.txt');
    await removeNewline.writeAsString('old\n');
    const removeNewlinePatch =
        '@@ -1 +1 @@\n'
        '-old\n'
        '+new\n'
        '\\ No newline at end of file\n';
    await FileToolService.execute('file_patch', {
      'path': 'remove-newline.txt',
      'patch': removeNewlinePatch,
    }, workspace.path);
    expect(await removeNewline.readAsString(), 'new');

    final deleteFinal = File('${workspace.path}/delete-final.txt');
    await deleteFinal.writeAsString('first\nlast');
    const deleteFinalPatch =
        '@@ -2 +1,0 @@\n'
        '-last\n'
        '\\ No newline at end of file\n';
    final deleteFinalResult = await FileToolService.execute('file_patch', {
      'path': 'delete-final.txt',
      'patch': deleteFinalPatch,
    }, workspace.path);
    expect(
      deleteFinalResult.createdOrModifiedFilePath,
      isNotNull,
      reason: deleteFinalResult.text,
    );
    expect(await deleteFinal.readAsString(), 'first\n');
  });

  test('bounds directory listings without loading every entry', () async {
    for (var i = 0; i <= FileToolService.maxListedEntries; i++) {
      await File('${workspace.path}/entry_$i.txt').writeAsString('$i');
    }

    final result = await FileToolService.execute('file_list', {
      'path': '',
    }, workspace.path);
    expect(result.text, contains('listing truncated'));
  });

  test(
    'supports directory, copy, move, search, info, and delete operations',
    () async {
      await FileToolService.execute('file_mkdir', {
        'path': 'src',
      }, workspace.path);
      await FileToolService.execute('file_write', {
        'path': 'src/app.py',
        'content': 'print(1)',
      }, workspace.path);
      final listed = await FileToolService.execute('file_list', {
        'path': '',
      }, workspace.path);
      expect(listed.text, contains('src'));

      final info = await FileToolService.execute('file_info', {
        'path': 'src/app.py',
      }, workspace.path);
      expect(info.text, contains('app.py'));

      await FileToolService.execute('file_copy', {
        'source': 'src/app.py',
        'destination': 'copy.py',
      }, workspace.path);
      await FileToolService.execute('file_move', {
        'source': 'copy.py',
        'destination': 'moved.py',
      }, workspace.path);
      final search = await FileToolService.execute('file_search', {
        'pattern': '*.py',
      }, workspace.path);
      expect(search.text, contains('src${Platform.pathSeparator}app.py'));
      expect(search.text, contains('moved.py'));

      await FileToolService.execute('file_delete', {
        'path': 'moved.py',
      }, workspace.path);
      expect(File('${workspace.path}/moved.py').existsSync(), isFalse);
    },
  );

  test('blocks executable extensions', () async {
    final result = await FileToolService.execute('file_write', {
      'path': 'unsafe.exe',
      'content': 'not executable',
    }, workspace.path);
    expect(result.text, contains('blocked'));
  });

  test('rejects a symlink that resolves outside the workspace', () async {
    final outside = await Directory.systemTemp.createTemp(
      'omnichat_file_tools_outside_',
    );
    addTearDown(() async {
      if (await outside.exists()) await outside.delete(recursive: true);
    });
    await File('${outside.path}/secret.txt').writeAsString('secret');
    try {
      await Link('${workspace.path}/link').create(outside.path);
    } catch (_) {
      return; // Symlink creation may require elevated privileges on Windows.
    }

    expect(
      () => FileToolService.resolveSafePath('link/secret.txt', workspace.path),
      throwsA(isA<FileToolSecurityException>()),
    );
  });

  test('exposes file_extract_text in the definition list', () {
    final names = FileToolService.getToolDefinitions()
        .map((definition) => definition['function']['name'])
        .toSet();
    expect(names, contains('file_extract_text'));
  });

  test('extracts DOCX text with paragraphs, entities, and Markdown tables',
      () async {
    await File('${workspace.path}/doc.docx').writeAsBytes(_docxFixture());
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'doc.docx',
    }, workspace.path);
    expect(result.text, contains('Hello & welcome'));
    expect(result.text, contains('第二段 中文'));
    // <w:tbl> content is now rendered as a Markdown table.
    expect(result.text, contains('| Cell A1 |'));
    expect(result.text, contains('|---|'));
    expect(result.text, contains('format=docx'));
    expect(result.text, contains('has_more=false'));
  });

  test('extracts DOCX text nested in content controls and text boxes',
      () async {
    await File('${workspace.path}/sdt.docx').writeAsBytes(_docxSdtFixture());
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'sdt.docx',
    }, workspace.path);
    expect(result.text, contains('SDT paragraph'));
    expect(result.text, contains('Text box paragraph'));
    expect(result.text, contains('normal'));
  });

  test('extracts PPTX tables as Markdown tables', () async {
    await File('${workspace.path}/table.pptx').writeAsBytes(
      _pptxTableFixture(),
    );
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'table.pptx',
    }, workspace.path);
    expect(result.text, contains('--- Slide 1 ---'));
    expect(result.text, contains('| Name | Value |'));
    expect(result.text, contains('|---|---|'));
    expect(result.text, contains('| Alpha | 1 |'));
  });

  test('extracts PPTX text in relationship order, not filename order',
      () async {
    await File('${workspace.path}/deck.pptx').writeAsBytes(_pptxFixture());
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'deck.pptx',
    }, workspace.path);
    final text = result.text;
    expect(text, contains('--- Slide 1 ---'));
    expect(text, contains('--- Slide 3 ---'));
    // sldIdLst order is rId3 (slide2), rId1 (slide1), rId2 (slide10).
    expect(text.indexOf('Slide Two'), lessThan(text.indexOf('Slide One')));
    expect(text.indexOf('Slide One'), lessThan(text.indexOf('Slide Ten')));
    expect(text, contains('format=pptx'));
  });

  test('extracts PDF text with page markers', () async {
    final pdf = _pdfFixture(pages: 2);
    await File('${workspace.path}/doc.pdf').writeAsBytes(pdf);
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'doc.pdf',
    }, workspace.path);
    expect(result.text, contains('--- Page 1 ---'));
    expect(result.text, contains('--- Page 2 ---'));
    expect(result.text, contains('Hello Page 1'));
    expect(result.text, contains('Hello Page 2'));
  });

  test('reports when a PDF has no extractable text', () async {
    final blank = PdfDocument();
    blank.pages.add();
    final bytes = blank.saveSync();
    blank.dispose();
    await File('${workspace.path}/blank.pdf').writeAsBytes(bytes);
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'blank.pdf',
    }, workspace.path);
    expect(result.text, contains('no extractable text'));
  });

  test('auto-detects uppercase extensions', () async {
    await File('${workspace.path}/UPPER.DOCX').writeAsBytes(_docxFixture());
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'UPPER.DOCX',
    }, workspace.path);
    expect(result.text, contains('format=docx'));
    expect(result.text, contains('Hello & welcome'));
  });

  test('honors a format override', () async {
    await File('${workspace.path}/renamed.bin').writeAsBytes(_docxFixture());
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'renamed.bin',
      'format': 'docx',
    }, workspace.path);
    expect(result.text, contains('Hello & welcome'));
  });

  test('rejects absolute, traversal, and NUL paths for extraction', () async {
    final absolute = await FileToolService.execute('file_extract_text', {
      'path': Directory.systemTemp.path,
    }, workspace.path);
    expect(absolute.text, contains('Error'));
    final traversal = await FileToolService.execute('file_extract_text', {
      'path': '../outside.pdf',
    }, workspace.path);
    expect(traversal.text, contains('Error'));
    final nul = await FileToolService.execute('file_extract_text', {
      'path': 'bad\u0000.pdf',
    }, workspace.path);
    expect(nul.text, contains('Error'));
  });

  test('rejects directories and missing paths for extraction', () async {
    await Directory('${workspace.path}/dir').create();
    final dirResult = await FileToolService.execute('file_extract_text', {
      'path': 'dir',
    }, workspace.path);
    expect(dirResult.text, contains('not a regular file'));
    final missing = await FileToolService.execute('file_extract_text', {
      'path': 'missing.docx',
    }, workspace.path);
    expect(missing.text, contains('File not found'));
  });

  test('rejects unsupported formats and malformed files', () async {
    await File('${workspace.path}/notes.xlsx').writeAsBytes(utf8.encode('x'));
    final unsupported = await FileToolService.execute('file_extract_text', {
      'path': 'notes.xlsx',
    }, workspace.path);
    expect(unsupported.text, contains('Unsupported file format'));

    await File('${workspace.path}/bad.docx').writeAsBytes(
      utf8.encode('not a zip file'),
    );
    final badDocx = await FileToolService.execute('file_extract_text', {
      'path': 'bad.docx',
      'format': 'docx',
    }, workspace.path);
    expect(badDocx.text, contains('Error'));

    await File('${workspace.path}/doc.docx').writeAsBytes(_docxFixture());
    final badFormat = await FileToolService.execute('file_extract_text', {
      'path': 'doc.docx',
      'format': 'xls',
    }, workspace.path);
    expect(badFormat.text, contains('Unsupported format'));
  });

  test('extracts XLSX text in workbook sheet order as Markdown tables',
      () async {
    await File('${workspace.path}/book.xlsx').writeAsBytes(
      _xlsxFixture(sheetNames: ['Summary', 'Data']),
    );
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'book.xlsx',
    }, workspace.path);
    final text = result.text;
    expect(text, contains('format=xlsx'));
    expect(text, contains('has_more=false'));
    // workbook.xml <sheets> order is Summary then Data, not filename order.
    expect(
      text.indexOf('--- Sheet 1 (Summary) ---'),
      lessThan(text.indexOf('--- Sheet 2 (Data) ---')),
    );
    expect(text, contains('--- Sheet 1 (Summary) ---'));
    expect(text, contains('--- Sheet 2 (Data) ---'));
    // Single-cell sheets become one-column tables with a header separator.
    expect(text, contains('| 3.14 |'));
    expect(text, contains('|---|'));
    // The second row has four cells (A2..D2); D2 is empty but its column
    // position is preserved, so the header row is padded to four columns.
    expect(text, contains('| Hello Excel | 42 | Inline & more |  |'));
    expect(text, contains('|---|---|---|---|'));
    expect(text, contains('| 第二個 中文 | TRUE | 123 |  |'));
  });

  test('auto-detects XLSX from ZIP layout without a known extension',
      () async {
    await File('${workspace.path}/renamed.bin').writeAsBytes(
      _xlsxFixture(sheetNames: ['Data']),
    );
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'renamed.bin',
    }, workspace.path);
    expect(result.text, contains('format=xlsx'));
    expect(result.text, contains('| Hello Excel |'));
  });

  test('handles booleans, formula cache, and out-of-range string indexes',
      () async {
    await File('${workspace.path}/types.xlsx').writeAsBytes(
      _xlsxFixture(sheetNames: ['Data']),
    );
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'types.xlsx',
    }, workspace.path);
    expect(result.text, contains('| 第二個 中文 | TRUE | 123 |  |'));
    // Shared string index 99 does not exist; the D2 cell is empty but its
    // column position is preserved (four columns in the row).
    expect(result.text, isNot(contains('D2')));
    expect(result.text, contains('|---|---|---|---|'));
  });

  test('reports when a workbook has no cell text', () async {
    await File('${workspace.path}/blank.xlsx').writeAsBytes(
      _xlsxFixture(sheetNames: ['Empty']),
    );
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'blank.xlsx',
    }, workspace.path);
    expect(result.text, contains('no extractable text'));
    expect(result.text, contains('no cell text or values'));
  });

  test('extracts chat-attached XLSX via the global extractor', () async {
    final path = '${workspace.path}/attached.xlsx';
    await File(path).writeAsBytes(_xlsxFixture(sheetNames: ['Data']));
    final text = await DocumentTextExtractor.extract(
      path: path,
      mime: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    expect(text, contains('--- Sheet 1 (Data) ---'));
    expect(text, contains('| Hello Excel |'));
  });

  test('auto-detects uppercase XLSX extensions', () async {
    await File('${workspace.path}/UPPER.XLSX').writeAsBytes(
      _xlsxFixture(sheetNames: ['Data']),
    );
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'UPPER.XLSX',
    }, workspace.path);
    expect(result.text, contains('format=xlsx'));
    expect(result.text, contains('| Hello Excel |'));
  });

  test('honors a format override for XLSX', () async {
    await File('${workspace.path}/renamed.bin').writeAsBytes(
      _xlsxFixture(sheetNames: ['Data']),
    );
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'renamed.bin',
      'format': 'xlsx',
    }, workspace.path);
    expect(result.text, contains('| Hello Excel |'));
  });

  test('extracts numeric-only workbooks without a sharedStrings part',
      () async {
    await File('${workspace.path}/numbers.xlsx').writeAsBytes(
      _xlsxFixture(
        sheetNames: ['Summary'],
        includeSharedStrings: false,
      ),
    );
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'numbers.xlsx',
    }, workspace.path);
    expect(result.text, contains('format=xlsx'));
    expect(result.text, contains('| 3.14 |'));
  });

  test('reports an XLSX missing workbook.xml as an error', () async {
    await File('${workspace.path}/bad.xlsx').writeAsBytes(
      _zipBytes({'xl/worksheets/sheet1.xml': '<worksheet/>'}),
    );
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'bad.xlsx',
      'format': 'xlsx',
    }, workspace.path);
    expect(result.text, contains('Error'));
    expect(result.text, contains('workbook.xml'));
  });

  test('supports offset, limit, next_offset, and has_more for XLSX',
      () async {
    await File('${workspace.path}/long.xlsx').writeAsBytes(
      _xlsxFixture(sheetNames: ['Data'], rows: 500),
    );
    final first = await FileToolService.execute('file_extract_text', {
      'path': 'long.xlsx',
    }, workspace.path);
    expect(first.text, contains('has_more=true'));
    expect(first.text, contains('next_offset='));
    final match = RegExp(r'next_offset=(\d+)').firstMatch(first.text);
    expect(match, isNotNull);
    final next = int.parse(match!.group(1)!);

    final second = await FileToolService.execute('file_extract_text', {
      'path': 'long.xlsx',
      'offset': next,
    }, workspace.path);
    expect(second.text, contains('next_offset='));
    expect(second.text, contains('Row number'));
  });

  test('does not split a UTF-8 code point in XLSX extracted text', () async {
    await File('${workspace.path}/uni.xlsx').writeAsBytes(
      _xlsxInlineCellFixture('A😀B'),
    );
    // Content is '--- Sheet 1 (Data) ---\n| A😀B |\n'. Find the emoji start
    // byte inside the pure extracted content, then read from the middle of it.
    final full = await FileToolService.execute('file_extract_text', {
      'path': 'uni.xlsx',
    }, workspace.path);
    final content = full.text.substring(full.text.indexOf('\n') + 1);
    final emojiStart = utf8.encode(content.split('😀').first).length;
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'uni.xlsx',
      'offset': emojiStart + 1,
      'limit': 10,
    }, workspace.path);
    expect(result.text, contains('B'));
    expect(result.text, isNot(contains('\uFFFD')));
  });

  test('rejects files over the extraction input limit without parsing',
      () async {
    final big = File('${workspace.path}/big.docx');
    await big.writeAsBytes(
      List<int>.filled(FileToolService.maxExtractInputBytes + 1, 0),
    );
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'big.docx',
    }, workspace.path);
    expect(result.text, contains('16 MB'));
  });

  test('supports offset, limit, next_offset, and has_more for extraction',
      () async {
    await File('${workspace.path}/long.docx').writeAsBytes(
      _docxFixture(paragraphs: 500),
    );
    final first = await FileToolService.execute('file_extract_text', {
      'path': 'long.docx',
    }, workspace.path);
    expect(first.text, contains('has_more=true'));
    expect(first.text, contains('next_offset='));
    final match = RegExp(r'next_offset=(\d+)').firstMatch(first.text);
    expect(match, isNotNull);
    final next = int.parse(match!.group(1)!);

    final second = await FileToolService.execute('file_extract_text', {
      'path': 'long.docx',
      'offset': next,
    }, workspace.path);
    expect(second.text, contains('next_offset='));
    expect(second.text, contains('Paragraph number'));
  });

  test('does not split a UTF-8 code point in extracted text', () async {
    await File('${workspace.path}/uni.docx').writeAsBytes(
      _docxFixtureRaw('A😀B'),
    );
    // The emoji occupies bytes 1..4 of the extracted text; offset 2 lands in
    // the middle of it and must advance to the next complete code point.
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'uni.docx',
      'offset': 2,
      'limit': 10,
    }, workspace.path);
    expect(result.text, contains('\nB'));
    expect(result.text, isNot(contains('\uFFFD')));
  });

  test('caps the limit parameter at the extract result maximum', () async {
    await File('${workspace.path}/long.docx').writeAsBytes(
      _docxFixture(paragraphs: 500),
    );
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'long.docx',
      'limit': FileToolService.maxExtractResultBytes + 1,
    }, workspace.path);
    expect(result.text, contains('limit capped'));
    expect(
      utf8.encode(result.text).length,
      lessThan(FileToolService.maxExtractResultBytes + 200),
    );
  });

  test('rejects an extraction symlink outside the workspace', () async {
    final outside = await Directory.systemTemp.createTemp(
      'omnichat_file_tools_outside_',
    );
    addTearDown(() async {
      if (await outside.exists()) await outside.delete(recursive: true);
    });
    final pdf = _pdfFixture(pages: 1);
    await File('${outside.path}/doc.pdf').writeAsBytes(pdf);
    try {
      await Link('${workspace.path}/link').create(outside.path);
    } catch (_) {
      return; // Symlink creation may require elevated privileges on Windows.
    }
    final result = await FileToolService.execute('file_extract_text', {
      'path': 'link/doc.pdf',
    }, workspace.path);
    expect(result.text, contains('Error'));
  });

  // ==========================================================================
  // file_extract_zip
  // ==========================================================================

  test('exposes file_extract_zip and file_create_pdf in the definition list',
      () {
    final names = FileToolService.getToolDefinitions()
        .map((definition) => definition['function']['name'])
        .toSet();
    expect(names, containsAll(<String>['file_extract_zip', 'file_create_pdf']));
  });

  test('extracts a ZIP archive into a folder named after the archive',
      () async {
    await File('${workspace.path}/bundle.zip').writeAsBytes(_zipBytes({
      'notes/a.txt': 'alpha',
      'notes/b.txt': 'beta',
      'readme.md': '# README',
    }));
    final result = await FileToolService.execute('file_extract_zip', {
      'path': 'bundle.zip',
    }, workspace.path);
    expect(result.text, contains('Extracted 3 file(s)'));
    expect(result.text, contains('- bundle/notes/a.txt'));
    expect(
      await File('${workspace.path}/bundle/notes/a.txt').readAsString(),
      'alpha',
    );
    expect(
      await File('${workspace.path}/bundle/readme.md').readAsString(),
      '# README',
    );
  });

  test('extracts a ZIP into an explicit destination directory', () async {
    await File('${workspace.path}/bundle.zip').writeAsBytes(_zipBytes({
      'a.txt': 'x',
    }));
    final result = await FileToolService.execute('file_extract_zip', {
      'path': 'bundle.zip',
      'destination': 'out/target',
    }, workspace.path);
    expect(result.text, contains('out/target'));
    expect(
      await File('${workspace.path}/out/target/a.txt').readAsString(),
      'x',
    );
  });

  test('rejects ZIP entries that escape the destination directory', () async {
    await File('${workspace.path}/evil.zip').writeAsBytes(_zipBytes({
      '../escape.txt': 'boom',
    }));
    final result = await FileToolService.execute('file_extract_zip', {
      'path': 'evil.zip',
    }, workspace.path);
    expect(result.text, contains('Error'));
    expect(result.text, contains('escapes'));
    expect(File('${workspace.path}/escape.txt').existsSync(), isFalse);
  });

  test('rejects backslash traversal and absolute-path ZIP entries', () async {
    await File('${workspace.path}/evil.zip').writeAsBytes(_zipBytes({
      r'..\escape.txt': 'boom',
      r'sub/../escape2.txt': 'boom',
      '/etc/passwd': 'root',
    }));
    final result = await FileToolService.execute('file_extract_zip', {
      'path': 'evil.zip',
    }, workspace.path);
    expect(result.text, contains('Error'));
    expect(File('${workspace.path}/escape.txt').existsSync(), isFalse);
    expect(File('${workspace.path}/etc/passwd').existsSync(), isFalse);
  });

  test('rejects ZIP entries with blocked extensions', () async {
    await File('${workspace.path}/bad.zip').writeAsBytes(_zipBytes({
      'tool.exe': 'MZ',
    }));
    final result = await FileToolService.execute('file_extract_zip', {
      'path': 'bad.zip',
    }, workspace.path);
    expect(result.text, contains('Error'));
    expect(result.text, contains('blocked'));
    expect(File('${workspace.path}/bad/tool.exe').existsSync(), isFalse);
  });

  test('rejects malformed and missing ZIP archives', () async {
    // Garbage bytes must be rejected safely (the decoder may return an empty
    // archive instead of throwing; either way no files are extracted).
    await File('${workspace.path}/fake.zip').writeAsBytes(
      utf8.encode('this is definitely not a zip archive'),
    );
    final malformed = await FileToolService.execute('file_extract_zip', {
      'path': 'fake.zip',
    }, workspace.path);
    expect(malformed.text, contains('Error'));

    final missing = await FileToolService.execute('file_extract_zip', {
      'path': 'nope.zip',
    }, workspace.path);
    expect(missing.text, contains('File not found'));
  });

  test('rejects ZIP archives with too many entries', () async {
    final entries = <String, String>{};
    for (var i = 0; i <= FileToolService.maxZipEntries; i++) {
      entries['f$i.txt'] = 'x';
    }
    await File('${workspace.path}/many.zip').writeAsBytes(_zipBytes(entries));
    final result = await FileToolService.execute('file_extract_zip', {
      'path': 'many.zip',
    }, workspace.path);
    expect(result.text, contains('more than 1000 files'));
  });

  test('rejects a directory or non-file ZIP path', () async {
    await Directory('${workspace.path}/dir').create();
    final dirResult = await FileToolService.execute('file_extract_zip', {
      'path': 'dir',
    }, workspace.path);
    expect(dirResult.text, contains('not a regular file'));
  });

  // ==========================================================================
  // file_create_pdf
  // ==========================================================================

  test('creates a readable PDF from Markdown content', () async {
    final result = await FileToolService.execute('file_create_pdf', {
      'path': 'report.pdf',
      'content': '# Title\n\nHello **world** and 中文 content.\n\n- item one\n- item two',
    }, workspace.path);
    expect(result.createdOrModifiedFilePath, isNotNull);
    expect(result.text, contains('Created'));
    final file = File('${workspace.path}/report.pdf');
    expect(await file.exists(), isTrue);
    final bytes = await file.readAsBytes();
    expect(bytes.length, greaterThan(100));

    final document = PdfDocument(inputBytes: bytes);
    addTearDown(document.dispose);
    final text = PdfTextExtractor(document).extractText();
    expect(text, contains('Title'));
    expect(text, contains('Hello'));
    expect(text, contains('world'));
  });

  test('renders Chinese text and tables in generated PDFs', () async {
    final result = await FileToolService.execute('file_create_pdf', {
      'path': 'chinese.pdf',
      'content': '# 報告\n\n中文段落測試\n\n| 名稱 | 數量 |\n| --- | --- |\n| 蘋果 | 3 |',
    }, workspace.path);
    expect(result.text, contains('Created'));
    final bytes = await File('${workspace.path}/chinese.pdf').readAsBytes();
    final document = PdfDocument(inputBytes: bytes);
    addTearDown(document.dispose);
    final text = PdfTextExtractor(document).extractText();
    expect(text, contains('報告'));
    expect(text, contains('蘋果'));
  });

  test('rejects invalid file_create_pdf arguments', () async {
    final missing = await FileToolService.execute('file_create_pdf', {
      'path': 'x.pdf',
    }, workspace.path);
    expect(missing.text, contains('content argument'));

    final empty = await FileToolService.execute('file_create_pdf', {
      'path': 'x.pdf',
      'content': '   ',
    }, workspace.path);
    expect(empty.text, contains('empty'));

    final oversized = await FileToolService.execute('file_create_pdf', {
      'path': 'x.pdf',
      'content': 'x' * (FileToolService.maxWriteBytes + 1),
    }, workspace.path);
    expect(oversized.text, contains('512 KB'));
  });
}

// -------------------------------------------------------------------------
// Fixture builders
// -------------------------------------------------------------------------

List<int> _zipBytes(Map<String, String> entries) {
  final archive = Archive();
  entries.forEach((name, content) {
    archive.addFile(ArchiveFile.string(name, content));
  });
  return ZipEncoder().encode(archive);
}

List<int> _docxFixture({int paragraphs = 3}) {
  final body = StringBuffer();
  body.write('<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell A1</w:t></w:r></w:p></w:tc></w:tr></w:tbl>');
  for (var i = 0; i < paragraphs; i++) {
    body.write(
      '<w:p><w:r><w:t>Paragraph number $i with padding text for length.</w:t></w:r></w:p>',
    );
  }
  return _zipBytes({
    'word/document.xml': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Hello &amp; welcome</w:t></w:r></w:p>
    <w:p><w:r><w:t>第二段 中文</w:t></w:r></w:p>
    $body
  </w:body>
</w:document>''',
  });
}

List<int> _docxFixtureRaw(String text) {
  return _zipBytes({
    'word/document.xml': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>$text</w:t></w:r></w:p>
  </w:body>
</w:document>''',
  });
}

List<int> _pptxFixture() {
  String slide(String text) => '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
  <p:spTree>
    <p:sp>
      <p:txBody>
        <a:bodyPr/>
        <a:p><a:r><a:t>$text</a:t></a:r></a:p>
      </p:txBody>
    </p:sp>
  </p:spTree>
</p:sld>''';
  return _zipBytes({
    'ppt/presentation.xml': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <p:sldIdLst>
    <p:sldId id="256" r:id="rId3"/>
    <p:sldId id="257" r:id="rId1"/>
    <p:sldId id="258" r:id="rId2"/>
  </p:sldIdLst>
</p:presentation>''',
    'ppt/_rels/presentation.xml.rels': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide10.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/>
</Relationships>''',
    'ppt/slides/slide1.xml': slide('Slide One'),
    'ppt/slides/slide2.xml': slide('Slide Two 中文'),
    'ppt/slides/slide10.xml': slide('Slide Ten'),
  });
}

List<int> _xlsxFixture({
  List<String> sheetNames = const ['Data'],
  bool includeSharedStrings = true,
  int rows = 3,
}) {
  final entries = <String, String>{};
  final sheets = StringBuffer();
  final rels = StringBuffer();
  for (var i = 0; i < sheetNames.length; i++) {
    final n = i + 1;
    final name = sheetNames[i];
    sheets.writeln('    <sheet name="$name" sheetId="$n" r:id="rId$n"/>');
    rels.writeln(
      '    <Relationship Id="rId$n" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet$n.xml"/>',
    );
    entries['xl/worksheets/sheet$n.xml'] = name == 'Summary'
        ? _xlsxSummarySheetXml()
        : name == 'Empty'
        ? _xlsxEmptySheetXml()
        : _xlsxDataSheetXml(rows);
  }
  entries['xl/workbook.xml'] = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
${sheets.toString().trimRight()}
  </sheets>
</workbook>''';
  entries['xl/_rels/workbook.xml.rels'] = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
${rels.toString().trimRight()}
</Relationships>''';
  if (includeSharedStrings) {
    entries['xl/sharedStrings.xml'] = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="2" uniqueCount="2">
  <si><t>Hello Excel</t></si>
  <si><r><t>第二個</t></r><r><t> 中文</t></r></si>
</sst>''';
  }
  return _zipBytes(entries);
}

List<int> _xlsxInlineCellFixture(String text) {
  return _zipBytes({
    'xl/workbook.xml': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
    <sheet name="Data" sheetId="1" r:id="rId1"/>
  </sheets>
</workbook>''',
    'xl/_rels/workbook.xml.rels': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>''',
    'xl/worksheets/sheet1.xml': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1"><c r="A1" t="inlineStr"><is><t>$text</t></is></c></row>
  </sheetData>
</worksheet>''',
  });
}

String _xlsxDataSheetXml(int rows) {
  final buffer = StringBuffer();
  buffer.writeln('''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>42</v></c><c r="C1" t="inlineStr"><is><t>Inline &amp; more</t></is></c></row>
    <row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2" t="b"><v>1</v></c><c r="C2"><f>SUM(1,2)</f><v>123</v></c><c r="D2" t="s"><v>99</v></c></row>''');
  for (var i = 3; i <= rows; i++) {
    buffer.writeln(
      '    <row r="$i"><c r="A$i" t="inlineStr"><is><t>Row number $i with padding text for length.</t></is></c></row>',
    );
  }
  buffer.writeln('  </sheetData>');
  buffer.writeln('</worksheet>');
  return buffer.toString();
}

String _xlsxSummarySheetXml() => '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1"><c r="A1"><v>3.14</v></c></row>
  </sheetData>
</worksheet>''';

String _xlsxEmptySheetXml() => '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1"><c r="A1"/></row>
  </sheetData>
</worksheet>''';

List<int> _docxSdtFixture() {
  return _zipBytes({
    'word/document.xml': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:sdt><w:sdtContent><w:p><w:r><w:t>SDT paragraph</w:t></w:r></w:p></w:sdtContent></w:sdt>
    <w:p>
      <w:r>
        <w:drawing>
          <wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">
            <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
              <a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">
                <wps:wsp xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">
                  <wps:txbx>
                    <w:txbxContent>
                      <w:p><w:r><w:t>Text box paragraph</w:t></w:r></w:p>
                    </w:txbxContent>
                  </wps:txbx>
                </wps:wsp>
              </a:graphicData>
            </a:graphic>
          </wp:inline>
        </w:drawing>
      </w:r>
    </w:p>
    <w:p><w:r><w:t>normal</w:t></w:r></w:p>
  </w:body>
</w:document>''',
  });
}

List<int> _pptxTableFixture() {
  return _zipBytes({
    'ppt/presentation.xml': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <p:sldIdLst>
    <p:sldId id="256" r:id="rId1"/>
  </p:sldIdLst>
</p:presentation>''',
    'ppt/_rels/presentation.xml.rels': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
</Relationships>''',
    'ppt/slides/slide1.xml': '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
  <p:cSld>
    <p:spTree>
      <p:graphicFrame>
        <a:graphic>
          <a:graphicData>
            <a:tbl>
              <a:tblPr/>
              <a:tblGrid>
                <a:gridCol/><a:gridCol/>
              </a:tblGrid>
              <a:tr h="100">
                <a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>Name</a:t></a:r></a:p></a:txBody></a:tc>
                <a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>Value</a:t></a:r></a:p></a:txBody></a:tc>
              </a:tr>
              <a:tr h="100">
                <a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>Alpha</a:t></a:r></a:p></a:txBody></a:tc>
                <a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>1</a:t></a:r></a:p></a:txBody></a:tc>
              </a:tr>
            </a:tbl>
          </a:graphicData>
        </a:graphic>
      </p:graphicFrame>
    </p:spTree>
  </p:cSld>
</p:sld>''',
  });
}

List<int> _pdfFixture({required int pages}) {
  final document = PdfDocument();
  for (var i = 0; i < pages; i++) {
    final page = document.pages.add();
    page.graphics.drawString(
      'Hello Page ${i + 1}',
      PdfStandardFont(PdfFontFamily.helvetica, 12),
    );
  }
  final bytes = document.saveSync();
  document.dispose();
  return bytes;
}
