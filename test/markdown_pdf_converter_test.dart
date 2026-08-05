import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/file/markdown_pdf_converter.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  String extract(List<int> bytes) {
    final document = PdfDocument(inputBytes: bytes);
    addTearDown(document.dispose);
    return PdfTextExtractor(document).extractText();
  }

  test('renders headings, paragraphs, lists, and page numbers', () {
    final bytes = MarkdownPdfConverter.convert(
      '# Title\n\nParagraph with **bold** and `code`.\n\n- alpha\n- beta\n\n1. first\n2. second',
    );
    final document = PdfDocument(inputBytes: bytes);
    addTearDown(document.dispose);
    expect(document.pages.count, greaterThanOrEqualTo(1));
    final text = PdfTextExtractor(document).extractText();
    expect(text, contains('Title'));
    expect(text, contains('bold'));
    expect(text, contains('code'));
    expect(text, contains('alpha'));
    expect(text, contains('first'));
    expect(text, contains('第 1 頁'));
  });

  test('renders tables, code blocks, quotes, and horizontal rules', () {
    final bytes = MarkdownPdfConverter.convert(
      '| Name | Value |\n| --- | --- |\n| Apple | 3 |\n| Pear | 5 |\n\n```\ncode block line\n```\n\n> quoted text\n\n---',
    );
    final text = extract(bytes);
    expect(text, contains('Name'));
    expect(text, contains('Apple'));
    expect(text, contains('code block line'));
    expect(text, contains('quoted text'));
  });

  test('renders Simplified and Traditional Chinese text', () {
    final simplified = extract(
      MarkdownPdfConverter.convert('# 报告\n\n简体中文内容测试'),
    );
    expect(simplified, contains('报告'));
    expect(simplified, contains('简体中文'));

    final traditional = extract(
      MarkdownPdfConverter.convert('# 報告\n\n繁體中文內容測試'),
    );
    expect(traditional, contains('報告'));
    expect(traditional, contains('繁體中文'));
  });

  test('strips link and image markup', () {
    final text = extract(
      MarkdownPdfConverter.convert(
        'See [the docs](https://example.com) and ![alt text](image.png).',
      ),
    );
    expect(text, contains('the docs'));
    expect(text, contains('alt text'));
    expect(text, isNot(contains('https://example.com')));
  });

  test('output stays well below the size cap for large input', () {
    final bytes = MarkdownPdfConverter.convert(
      List<String>.filled(2000, '段落內容測試').join('\n\n'),
    );
    expect(bytes.length, lessThan(MarkdownPdfConverter.maxPdfBytes));
  });

  test('flowing paragraphs occupy real vertical space across pages', () {
    // If lines were drawn on top of each other (a layout regression), all 40
    // paragraphs would fit on a single page. Asserting two pages is robust to
    // font-width differences while still catching the regression.
    final content = List<String>.generate(40, (i) {
      return 'Paragraph $i with enough words to wrap onto multiple lines on the page.';
    }).join('\n\n');
    final bytes = MarkdownPdfConverter.convert(content);
    final document = PdfDocument(inputBytes: bytes);
    addTearDown(document.dispose);
    expect(document.pages.count, greaterThanOrEqualTo(2));
  });

  test('multi-line code blocks occupy real vertical space across pages', () {
    final codeLines = List<String>.generate(60, (i) => 'code line $i').join(
      '\n',
    );
    final bytes = MarkdownPdfConverter.convert('```\n$codeLines\n```');
    final document = PdfDocument(inputBytes: bytes);
    addTearDown(document.dispose);
    expect(document.pages.count, greaterThanOrEqualTo(2));
  });
}
