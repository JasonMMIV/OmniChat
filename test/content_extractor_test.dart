import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/web/content_extractor.dart';

String _articleHtml({
  String outside = '',
  String extra = '',
}) =>
    '''
<!doctype html>
<html lang="zh-Hant">
<head>
  <title>測試文章</title>
  <meta name="description" content="這是一段描述">
  <meta property="og:site_name" content="OmniChat News">
  <meta property="article:published_time" content="2026-01-02T03:04:05Z">
</head>
<body>
  <header><a href="/">Home</a><nav><a href="/a">A</a><a href="/b">B</a></nav></header>
  <main>
    <article>
      <h1>主要標題</h1>
      <p>第一段內容，包含足夠的文字來通過最低長度門檻。這裡再補一些文字，讓段落看起來像真正的文章內容，而不是選單或按鈕。</p>
      <p>第二段內容，說明這個頁面的主旨。這段文字也會被保留下來，並且不會被當成 boilerplate 刪除。</p>
      <p>第三段內容，補足長度。文章需要超過兩百五十個字元才會被視為正文，因此這裡繼續加上更多描述。</p>
    </article>
  </main>
  <aside>側欄廣告</aside>
  <footer>頁尾版權所有</footer>
  $extra
  $outside
</body>
</html>
''';

void main() {
  group('main content', () {
    test('extracts article text and metadata', () {
      final result = HtmlExtractor.extract(_articleHtml());
      expect(result.ok, isTrue);
      expect(result.markdown, contains('主要標題'));
      expect(result.markdown, contains('第一段內容'));
      expect(result.markdown, contains('第二段內容'));
      expect(result.markdown, isNot(contains('側欄廣告')));
      expect(result.markdown, isNot(contains('頁尾版權所有')));
      expect(result.metadata.title, '測試文章');
      expect(result.metadata.description, '這是一段描述');
      expect(result.metadata.siteName, 'OmniChat News');
      expect(result.metadata.language, 'zh-Hant');
      expect(result.metadata.publishedTime, '2026-01-02T03:04:05Z');
    });

    test('forum comments are never treated as boilerplate', () {
      final html = '''
<html><body>
<h1>討論串</h1>
<div class="comments">
  <div class="comment">
    <p>這是第一則回覆，內容也很長，而且必須被保留下來，不能因為 class 名稱含有 comment 就被刪除。</p>
  </div>
  <div class="comment">
    <p>這是第二則回覆，同樣需要保留。論壇頁面的正文往往就在 comments 容器裡，所以這個 class 不在負面樣式清單中。</p>
  </div>
</div>
</body></html>
''';
      final result = HtmlExtractor.extract(html);
      expect(result.ok, isTrue);
      expect(result.markdown, contains('第一則回覆'));
      expect(result.markdown, contains('第二則回覆'));
    });

    test('selector restricts extraction', () {
      final html = '''
<html><body>
<div id="main">
  <p>想要的內容，這一段必須出現，而且長度足夠。為了通過最低字元門檻，這裡再加上一些補充文字，讓段落更長一些。</p>
</div>
<div id="other">
  <p>不想要的內容，這一段不應該出現。這裡也加上一些文字，避免因為太短而被忽略。</p>
</div>
</body></html>
''';
      final result = HtmlExtractor.extract(html, selector: '#main');
      expect(result.ok, isTrue);
      expect(result.markdown, contains('想要的內容'));
      expect(result.markdown, isNot(contains('不想要的內容')));
    });

    test('missing selector returns selector_not_found', () {
      final result = HtmlExtractor.extract(
        _articleHtml(),
        selector: '#does-not-exist',
      );
      expect(result.ok, isFalse);
      expect(result.errorCode, 'selector_not_found');
    });

    test('safety valve keeps the body when extraction prunes too much', () {
      final outside = '<p>${'外部段落文字。' * 200}</p>';
      final html = _articleHtml(outside: outside);
      final result = HtmlExtractor.extract(html);
      expect(result.ok, isTrue);
      expect(result.markdown, contains('外部段落文字'));
    });

    test('handles a document larger than the parser cap', () {
      final html = '<html><body>${'<p>hello world</p>' * 70000}</body></html>';
      expect(html.length, greaterThan(1024 * 1024));
      final result = HtmlExtractor.extract(html);
      expect(result.ok, isTrue);
      expect(result.markdown, contains('hello world'));
    });

    test('empty page returns no_readable_content', () {
      final result = HtmlExtractor.extract(
        '<html><body>   <div> </div> </body></html>',
      );
      expect(result.ok, isFalse);
      expect(result.errorCode, 'no_readable_content');
    });
  });

  group('metadata', () {
    test('falls back to og:title and JSON-LD date', () {
      final result = HtmlExtractor.extract('''
<html><body>
<head>
  <meta property="og:title" content="OG 標題">
  <script type="application/ld+json">{"datePublished":"2025-05-06T07:08:09Z"}</script>
</head>
<article><p>${'正文內容，' * 80}</p></article>
</body></html>
''');
      expect(result.metadata.title, 'OG 標題');
      expect(result.metadata.publishedTime, '2025-05-06T07:08:09Z');
    });
  });

  group('formatting helpers', () {
    test('strips YAML frontmatter', () {
      final text = '---\ntitle: x\n---\n# Heading\n\nBody';
      expect(HtmlExtractor.stripFrontmatter(text), '# Heading\n\nBody');
    });

    test('pretty-prints small JSON', () {
      final formatted = HtmlExtractor.formatJson('{"a":1,"b":[2,3]}');
      expect(formatted, contains('\n'));
      expect(formatted, contains('  "a": 1'));
    });

    test('minifies large JSON', () {
      final raw = '{"a":"${'x' * 5000}"}';
      final formatted = HtmlExtractor.formatJson(raw);
      expect(formatted, isNot(contains('\n')));
      expect(formatted, contains('"a"'));
    });

    test('normalizes whitespace but keeps paragraphs', () {
      final normalized = HtmlExtractor.normalizePlainText(
        'a  \r\n\r\n\r\n\r\nb\t',
      );
      expect(normalized, 'a\n\nb');
    });
  });
}
