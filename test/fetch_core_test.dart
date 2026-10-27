import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:OmniChat/core/services/chat/document_text_extractor.dart';
import 'package:OmniChat/core/services/web/fetch_core.dart';
import 'package:OmniChat/core/services/web/ssrf_guard.dart';

FetchCore _core(http.Client client) => FetchCore(
  client: client,
  guard: SsrfGuard(
    lookup: (host) async => <InternetAddress>[
      InternetAddress('93.184.216.34'),
    ],
  ),
  sleep: (_) async {},
);

void main() {
  group('content routing', () {
    test('extracts main content from HTML and keeps metadata', () async {
      final client = MockClient((request) async {
        return http.Response(
          '''
<html><head><title>Hello</title></head>
<body>
  <nav>menu menu</nav>
  <article><p>${'Article body, with commas, and enough text. ' * 12}</p></article>
  <footer>footer footer</footer>
</body></html>
''',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      });
      final result = await _core(client).fetch(
        FetchRequest(url: Uri.parse('https://example.com/page')),
      );
      expect(result.content, contains('Article body'));
      expect(result.content, isNot(contains('menu menu')));
      expect(result.content, isNot(contains('footer footer')));
      expect(result.metadata.title, 'Hello');
      expect(result.charset, 'utf-8');
      expect(result.status, 200);
    });

    test('honours Big5 charset', () async {
      final client = MockClient((request) async {
        return http.Response.bytes(
          <int>[0xC1, 0x63, 0xC5, 0xE9, 0xA4, 0xA4, 0xA4, 0xE5],
          200,
          headers: {'content-type': 'text/plain; charset=big5'},
        );
      });
      final result = await _core(client).fetch(
        FetchRequest(url: Uri.parse('https://example.com/big5')),
      );
      expect(result.charset, 'big5');
      expect(result.content, '繁體中文');
    });

    test('pretty-prints small JSON', () async {
      final client = MockClient(
        (request) async => http.Response(
          '{"a":1,"b":[2,3]}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final result = await _core(client).fetch(
        FetchRequest(url: Uri.parse('https://example.com/api')),
      );
      expect(result.content, contains('\n'));
      expect(result.content, contains('  "a": 1'));
    });

    test('XML feeds are returned as plain text', () async {
      final client = MockClient(
        (request) async => http.Response(
          '<?xml version="1.0"?><rss><channel><title>Feed</title></channel></rss>',
          200,
          headers: {'content-type': 'application/rss+xml'},
        ),
      );
      final result = await _core(client).fetch(
        FetchRequest(url: Uri.parse('https://example.com/feed.xml')),
      );
      expect(result.content, contains('<rss>'));
      expect(result.content, contains('<title>Feed</title>'));
    });

    test('strips Markdown frontmatter', () async {
      final client = MockClient(
        (request) async => http.Response(
          '---\ntitle: x\n---\n# Body',
          200,
          headers: {'content-type': 'text/markdown'},
        ),
      );
      final result = await _core(client).fetch(
        FetchRequest(url: Uri.parse('https://example.com/readme.md')),
      );
      expect(result.content, '# Body');
    });

    test('raw=true returns the server bytes as text', () async {
      final client = MockClient(
        (request) async => http.Response(
          '<html><body><nav>raw nav</nav></body></html>',
          200,
          headers: {'content-type': 'text/html'},
        ),
      );
      final result = await _core(client).fetch(
        FetchRequest(
          url: Uri.parse('https://example.com/raw'),
          raw: true,
        ),
      );
      expect(result.content, contains('<nav>raw nav</nav>'));
    });

    test('large HTML is still extracted (background isolate path)', () async {
      final paragraph = '<p>${'Large article paragraph. ' * 3000}</p>';
      expect(paragraph.length, greaterThan(FetchCore.computeIsolateThresholdChars));
      final client = MockClient(
        (request) async => http.Response(
          '<html><head><title>Big</title></head><body>$paragraph</body></html>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        ),
      );
      final result = await _core(client).fetch(
        FetchRequest(url: Uri.parse('https://example.com/big.html')),
      );
      expect(result.content, contains('Large article paragraph.'));
      expect(result.metadata.title, 'Big');
    });

    test('images are unsupported binary', () async {
      final client = MockClient(
        (request) async => http.Response.bytes(
          <int>[0x89, 0x50, 0x4E, 0x47],
          200,
          headers: {'content-type': 'image/png'},
        ),
      );
      await expectLater(
        _core(client).fetch(
          FetchRequest(url: Uri.parse('https://example.com/a.png')),
        ),
        throwsA(
          isA<FetchException>().having(
            (e) => e.code,
            'code',
            'unsupported_binary',
          ),
        ),
      );
    });
  });

  group('bot challenges', () {
    test('202 AWS WAF page returns bot_challenge', () async {
      final client = MockClient(
        (request) async => http.Response(
          '<html><body><script>window.gokuProps = {};</script></body></html>',
          202,
          headers: {'content-type': 'text/html'},
        ),
      );
      await expectLater(
        _core(client).fetch(
          FetchRequest(url: Uri.parse('https://example.com/waf')),
        ),
        throwsA(
          isA<FetchException>()
              .having((e) => e.code, 'code', 'bot_challenge')
              .having((e) => e.status, 'status', 202)
              .having((e) => e.challenge, 'challenge', 'AWS WAF'),
        ),
      );
    });

    test('200 Reddit JS challenge returns bot_challenge', () async {
      final client = MockClient(
        (request) async => http.Response(
          '<html><body><form id="js_challenge">'
          '<input name="jsc_token" value="x"></form></body></html>',
          200,
          headers: {'content-type': 'text/html'},
        ),
      );
      await expectLater(
        _core(client).fetch(
          FetchRequest(url: Uri.parse('https://example.com/reddit')),
        ),
        throwsA(
          isA<FetchException>()
              .having((e) => e.code, 'code', 'bot_challenge')
              .having((e) => e.challenge, 'challenge', 'Reddit'),
        ),
      );
    });

    test('403 Cloudflare Turnstile returns bot_challenge', () async {
      final client = MockClient(
        (request) async => http.Response(
          '<html><script src="https://challenges.cloudflare.com/turnstile/v0/api.js">'
          '</script><p>Verify you are human</p></html>',
          403,
          headers: {'content-type': 'text/html'},
        ),
      );
      await expectLater(
        _core(client).fetch(
          FetchRequest(url: Uri.parse('https://example.com/cf')),
        ),
        throwsA(
          isA<FetchException>()
              .having((e) => e.code, 'code', 'bot_challenge')
              .having((e) => e.challenge, 'challenge', 'Cloudflare'),
        ),
      );
    });

    test('403 hashcash returns bot_challenge', () async {
      final client = MockClient(
        (request) async => http.Response(
          '<html><title>Checking your browser...</title>'
          '<script src="/__challenge/probes.js"></script></html>',
          403,
          headers: {'content-type': 'text/html'},
        ),
      );
      await expectLater(
        _core(client).fetch(
          FetchRequest(url: Uri.parse('https://example.com/hashcash')),
        ),
        throwsA(
          isA<FetchException>()
              .having((e) => e.code, 'code', 'bot_challenge')
              .having((e) => e.challenge, 'challenge', 'hashcash'),
        ),
      );
    });

    test('non-2xx challenge marker after a large CSS block is detected', () async {
      final css = '<style>${'x' * 20000}</style>';
      final client = MockClient(
        (request) async => http.Response(
          '<html><body>$css<form id="js_challenge"><input name="jsc_token"></form></body></html>',
          403,
          headers: {'content-type': 'text/html'},
        ),
      );
      await expectLater(
        _core(client).fetch(
          FetchRequest(url: Uri.parse('https://example.com/reddit-403')),
        ),
        throwsA(
          isA<FetchException>()
              .having((e) => e.code, 'code', 'bot_challenge')
              .having((e) => e.challenge, 'challenge', 'Reddit'),
        ),
      );
    });

    test('generic 403 stays http_error', () async {
      final client = MockClient(
        (request) async => http.Response(
          '<html><body><h1>Forbidden</h1></body></html>',
          403,
          headers: {'content-type': 'text/html'},
        ),
      );
      await expectLater(
        _core(client).fetch(
          FetchRequest(url: Uri.parse('https://example.com/forbidden')),
        ),
        throwsA(
          isA<FetchException>()
              .having((e) => e.code, 'code', 'http_error')
              .having(
                (e) => e.bodySnippet!.length,
                'snippet length',
                lessThanOrEqualTo(FetchCore.maxErrorSnippetChars),
              ),
        ),
      );
    });

    test('normal 200 article is not a challenge', () async {
      final client = MockClient(
        (request) async => http.Response(
          '<html><body><article><p>'
          '${'Cloudflare Turnstile and captcha discussion. ' * 20}'
          '</p></article></body></html>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        ),
      );
      final result = await _core(client).fetch(
        FetchRequest(url: Uri.parse('https://example.com/article')),
      );
      expect(result.content, contains('Cloudflare Turnstile'));
    });

    test('raw=true keeps the challenge body and marks it', () async {
      final client = MockClient(
        (request) async => http.Response(
          '<html><body><form id="js_challenge"><input name="jsc_token">raw body</form></body></html>',
          200,
          headers: {'content-type': 'text/html'},
        ),
      );
      final result = await _core(client).fetch(
        FetchRequest(
          url: Uri.parse('https://example.com/reddit'),
          raw: true,
        ),
      );
      expect(result.challenge, 'Reddit');
      expect(result.content, contains('raw body'));
    });
  });

  group('redirects', () {
    test('301 + POST returns redirect_method_change', () async {
      final client = MockClient(
        (request) async => http.Response(
          '',
          301,
          headers: {'location': 'https://example.com/other'},
        ),
      );
      await expectLater(
        _core(client).fetch(
          FetchRequest(
            url: Uri.parse('https://example.com/post'),
            method: 'POST',
            body: 'a=1',
          ),
        ),
        throwsA(
          isA<FetchException>().having(
            (e) => e.code,
            'code',
            'redirect_method_change',
          ),
        ),
      );
    });

    test('302 + POST also returns redirect_method_change', () async {
      final client = MockClient(
        (request) async => http.Response(
          '',
          302,
          headers: {'location': 'https://example.com/other'},
        ),
      );
      await expectLater(
        _core(client).fetch(
          FetchRequest(
            url: Uri.parse('https://example.com/post'),
            method: 'POST',
            body: 'a=1',
          ),
        ),
        throwsA(
          isA<FetchException>().having(
            (e) => e.code,
            'code',
            'redirect_method_change',
          ),
        ),
      );
    });

    test('303 switches to GET and drops the body', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (requests.length == 1) {
          return http.Response(
            '',
            303,
            headers: {'location': '/next'},
          );
        }
        return http.Response(
          'done',
          200,
          headers: {'content-type': 'text/plain'},
        );
      });
      final result = await _core(client).fetch(
        FetchRequest(
          url: Uri.parse('https://example.com/post'),
          method: 'POST',
          body: 'a=1',
        ),
      );
      expect(result.content, 'done');
      expect(requests, hasLength(2));
      expect(requests[1].method, 'GET');
      expect(requests[1].body, isEmpty);
    });

    test('307 preserves method and body', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (requests.length == 1) {
          return http.Response(
            '',
            307,
            headers: {'location': 'https://example.com/next'},
          );
        }
        return http.Response(
          'ok',
          200,
          headers: {'content-type': 'text/plain'},
        );
      });
      await _core(client).fetch(
        FetchRequest(
          url: Uri.parse('https://example.com/post'),
          method: 'POST',
          body: 'a=1',
        ),
      );
      expect(requests[1].method, 'POST');
      expect(requests[1].body, 'a=1');
    });

    test('each hop is checked against private addresses', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(
          '',
          302,
          headers: {'location': 'http://127.0.0.1/secret'},
        );
      });
      await expectLater(
        _core(client).fetch(
          FetchRequest(url: Uri.parse('https://example.com/go')),
        ),
        throwsA(
          isA<FetchException>().having(
            (e) => e.code,
            'code',
            'blocked_private_address',
          ),
        ),
      );
      expect(requests, hasLength(1));
    });

    test('stops after too many redirects', () async {
      var count = 0;
      final client = MockClient((request) async {
        count++;
        return http.Response(
          '',
          302,
          headers: {'location': '/loop'},
        );
      });
      await expectLater(
        _core(client).fetch(
          FetchRequest(url: Uri.parse('https://example.com/loop')),
        ),
        throwsA(
          isA<FetchException>().having(
            (e) => e.code,
            'code',
            'too_many_redirects',
          ),
        ),
      );
      expect(count, 6); // first + 5 followed redirects
    });
  });

  group('headers and limits', () {
    test('denylisted headers never reach the wire', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          'ok',
          200,
          headers: {'content-type': 'text/plain'},
        );
      });
      await _core(client).fetch(
        FetchRequest(
          url: Uri.parse('https://example.com/'),
          headers: <String, String>{
            'Accept-Encoding': 'gzip',
            'Host': 'evil.example',
            'Content-Length': '99',
            'Connection': 'keep-alive',
            'X-Custom': 'yes',
          },
        ),
      );
      expect(captured, isNotNull);
      final sent = captured!.headers.keys.map((k) => k.toLowerCase()).toSet();
      expect(sent, isNot(contains('accept-encoding')));
      expect(sent, isNot(contains('host')));
      expect(sent, isNot(contains('content-length')));
      expect(sent, isNot(contains('connection')));
      expect(captured!.headers['X-Custom'], 'yes');
    });

    test('a response over 2 MB is rejected', () async {
      final client = MockClient(
        (request) async => http.Response.bytes(
          Uint8List(FetchCore.maxDownloadBytes + 1),
          200,
          headers: {'content-type': 'application/octet-stream'},
        ),
      );
      await expectLater(
        _core(client).fetch(
          FetchRequest(url: Uri.parse('https://example.com/big')),
        ),
        throwsA(
          isA<FetchException>().having(
            (e) => e.code,
            'code',
            'response_too_large',
          ),
        ),
      );
    });

    test('retries 503 and succeeds', () async {
      var attempts = 0;
      final client = MockClient((request) async {
        attempts++;
        if (attempts == 1) return http.Response('busy', 503);
        return http.Response(
          'ok',
          200,
          headers: {'content-type': 'text/plain'},
        );
      });
      final result = await _core(client).fetch(
        FetchRequest(url: Uri.parse('https://example.com/retry')),
      );
      expect(attempts, 2);
      expect(result.content, 'ok');
    });

    test('non-2xx carries status and a bounded body snippet', () async {
      final client = MockClient(
        (request) async => http.Response(
          'not found ${'x' * 2000}',
          404,
          headers: {'content-type': 'text/plain'},
        ),
      );
      await expectLater(
        _core(client).fetch(
          FetchRequest(url: Uri.parse('https://example.com/missing')),
        ),
        throwsA(
          isA<FetchException>()
              .having((e) => e.code, 'code', 'http_error')
              .having((e) => e.status, 'status', 404)
              .having(
                (e) => e.bodySnippet!.length,
                'snippet length',
                lessThanOrEqualTo(1024),
              ),
        ),
      );
    });
  });

  group('PDF', () {
    test('extracts page text from a PDF response', () async {
      final pdf = _buildPdf();
      final client = MockClient(
        (request) async => http.Response.bytes(
          pdf,
          200,
          headers: {'content-type': 'application/pdf'},
        ),
      );
      final result = await _core(client).fetch(
        FetchRequest(url: Uri.parse('https://example.com/doc.pdf')),
      );
      expect(result.content, contains('--- Page 1 ---'));
      expect(result.content, contains('Hello PDF'));
    });

    test('a PDF without text returns the scanned-image notice', () async {
      final client = MockClient(
        (request) async => http.Response.bytes(
          _buildPdf(text: null),
          200,
          headers: {'content-type': 'application/pdf'},
        ),
      );
      final result = await _core(client).fetch(
        FetchRequest(url: Uri.parse('https://example.com/scan.pdf')),
      );
      expect(result.content, contains('no extractable text'));
      expect(result.content, contains('scanned images'));
    });

    test('the bytes entry point rejects a PDF over 16 MB', () {
      final oversized = Uint8List(DocumentTextExtractor.maxPdfBytes + 1)
        ..setRange(0, 5, utf8.encode('%PDF-'));
      expect(
        () => DocumentTextExtractor.extractPdfBytes(
          oversized,
          maxOutputBytes: 1000,
        ),
        throwsA(isA<DocumentExtractionException>()),
      );
    });
  });
}

/// Builds a one-page PDF entirely in memory (Syncfusion is a runtime
/// dependency of the app, so the test does not need a fixture file).
/// Passing `text: null` leaves the page blank, simulating a scan.
Uint8List _buildPdf({String? text = 'Hello PDF'}) {
  final document = PdfDocument();
  final page = document.pages.add();
  if (text != null) {
    page.graphics.drawString(
      text,
      PdfStandardFont(PdfFontFamily.helvetica, 12),
    );
  }
  final bytes = Uint8List.fromList(document.saveSync());
  document.dispose();
  return bytes;
}
