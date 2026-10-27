import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/network/request_logger.dart';
import 'package:OmniChat/core/services/search/search_dispatch.dart';
import 'package:OmniChat/core/services/search/search_service.dart';
import 'package:OmniChat/core/services/web/charset_decoder.dart';
import 'package:OmniChat/core/services/web/content_extractor.dart';
import 'package:OmniChat/core/services/web/fetch_cache.dart';
import 'package:OmniChat/core/services/web/fetch_core.dart';
import 'package:OmniChat/core/services/web/fetch_source_service.dart';
import 'package:OmniChat/core/services/web/ssrf_guard.dart';
import 'package:OmniChat/core/services/web/web_fetch_tool.dart';

Future<SettingsProvider> _settings() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final provider = SettingsProvider();
  final done = Completer<void>();
  void listener() {
    if (!done.isCompleted) done.complete();
  }

  provider.addListener(listener);
  await done.future.timeout(const Duration(seconds: 10));
  provider.removeListener(listener);
  await provider.setWebFetchEnabled(true);
  return provider;
}

FetchCore _core(http.Client client, {bool allowPrivate = false}) =>
    FetchCore(
      client: client,
      guard: SsrfGuard(
        allowPrivateHosts: allowPrivate,
        lookup: (host) async => <InternetAddress>[
          InternetAddress('93.184.216.34'),
        ],
      ),
      sleep: (_) async {},
    );

class _TrailerErrorClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final controller = StreamController<List<int>>();
    controller.add(
      utf8.encode(
        '<html><body><article><p>${'Retained trailer body. ' * 30}</p>'
        '</article></body></html>',
      ),
    );
    controller.addError(
      http.ClientException(
        'Failed to parse HTTP, 115 does not match 13',
        request.url,
      ),
    );
    unawaited(controller.close());
    return http.StreamedResponse(
      controller.stream,
      200,
      headers: <String, String>{'content-type': 'text/html; charset=utf-8'},
      request: request,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('charset fallback', () {
    test('undeclared GBK is not decoded as Big5', () {
      final bytes = Uint8List.fromList(<int>[
        0xBC, 0xF2, 0xCC, 0xE5, 0xD6, 0xD0, 0xCE, 0xC4,
      ]);
      final decoded = CharsetDecoder.decode(bytes);
      expect(decoded.charset, 'gbk');
      expect(decoded.text, '简体中文');
    });

    test('undeclared Shift-JIS is not decoded as GBK', () {
      final bytes = Uint8List.fromList(<int>[
        0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA,
      ]);
      final decoded = CharsetDecoder.decode(bytes);
      expect(decoded.charset, 'shift_jis');
      expect(decoded.text, '日本語');
    });

    test('one invalid byte does not flip valid Big5 to Shift-JIS', () {
      final bytes = Uint8List.fromList(<int>[
        0xC1, 0x63, 0xC5, 0xE9, 0xA4, 0xA4, 0xA4, 0xE5, 0x80,
      ]);
      final decoded = CharsetDecoder.decode(bytes);
      expect(decoded.charset, 'big5');
      expect(decoded.text, startsWith('繁體中文'));
      expect(decoded.charsetFallback, isTrue);
    });
  });

  group('HTML pruning', () {
    test('article wrappers with widget/sidebar/menu classes survive', () {
      for (final className in <String>[
        'w-article widget article layout-rich',
        'article-with-sidebar',
        'mainContainer storyMenu',
      ]) {
        final html = '''
<html><body>
<section class="$className">
  <article><p>${'Article body with enough text. ' * 20}</p></article>
</section>
</body></html>
''';
        final result = HtmlExtractor.extract(html);
        expect(result.ok, isTrue, reason: className);
        expect(result.markdown, contains('Article body'), reason: className);
      }
    });

    test('invalid CSS selector returns invalid_arguments', () {
      final result = HtmlExtractor.extract(
        '<html><body><p>${'body text ' * 50}</p></body></html>',
        selector: 'div[',
      );
      expect(result.ok, isFalse);
      expect(result.errorCode, 'invalid_arguments');
    });
  });

  group('transport recovery', () {
    test('Dart HTTP trailer parse error keeps the complete text body', () async {
      final result = await _core(_TrailerErrorClient()).fetch(
        FetchRequest(url: Uri.parse('https://example.com/trailer')),
      );
      expect(result.content, contains('Retained trailer body.'));
    });

    test('Tier 2 refuses private targets before calling the provider', () async {
      final settings = await _settings();
      await settings.setSearchServices(<SearchServiceOptions>[
        TavilyOptions(id: 'tavily-1', apiKey: 'test-key'),
      ]);
      await settings.setSearchSelectedProviders(<String>['tavily-1']);
      await settings.setWebFetchSource('tavily-1');

      var providerCalls = 0;
      final service = FetchSourceService(
        client: MockClient((request) async {
          providerCalls++;
          return http.Response('{}', 200);
        }),
        cooldown: ProviderCooldown(),
      );
      await expectLater(
        service.fetch(
          request: FetchRequest(
            url: Uri.parse('http://127.0.0.1:11434/secret'),
          ),
          settings: settings,
          localCore: _core(
            MockClient(
              (request) async => http.Response(
                'local',
                200,
                headers: <String, String>{'content-type': 'text/plain'},
              ),
            ),
          ),
        ),
        throwsA(
          isA<FetchException>().having(
            (e) => e.code,
            'code',
            'blocked_private_address',
          ),
        ),
      );
      expect(providerCalls, 0);
    });

    test('Tier 2 skips the provider when local private access is enabled', () async {
      final settings = await _settings();
      await settings.setSearchServices(<SearchServiceOptions>[
        TavilyOptions(id: 'tavily-1', apiKey: 'test-key'),
      ]);
      await settings.setSearchSelectedProviders(<String>['tavily-1']);
      await settings.setWebFetchSource('tavily-1');
      await settings.setWebFetchAllowPrivateHosts(true);

      var providerCalls = 0;
      final service = FetchSourceService(
        client: MockClient((request) async {
          providerCalls++;
          return http.Response('{}', 200);
        }),
        cooldown: ProviderCooldown(),
      );
      final outcome = await service.fetch(
        request: FetchRequest(
          url: Uri.parse('http://127.0.0.1:11434/private'),
        ),
        settings: settings,
        localCore: _core(
          MockClient(
            (request) async => http.Response(
              'local private content',
              200,
              headers: <String, String>{'content-type': 'text/plain'},
            ),
          ),
          allowPrivate: true,
        ),
      );
      expect(providerCalls, 0);
      expect(outcome.source, 'local');
      expect(outcome.escalated, isFalse);
      expect(outcome.result.content, contains('local private content'));
    });
  });

  group('tool behavior', () {
    late SettingsProvider settings;

    setUp(() async {
      settings = await _settings();
    });

    test('trailing Markdown punctuation is removed from the URL', () async {
      Uri? requested;
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient((request) async {
            requested = request.url;
            return http.Response(
              'ok',
              200,
              headers: <String, String>{'content-type': 'text/plain'},
            );
          }),
        ),
        cache: FetchCache(),
      );
      await tool.execute(<String, dynamic>{
        'url': 'https://example.com/article)',
      });
      expect(requested?.toString(), 'https://example.com/article');
    });

    test('balanced parentheses in a Wikipedia URL are preserved', () async {
      Uri? requested;
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient((request) async {
            requested = request.url;
            return http.Response(
              'ok',
              200,
              headers: <String, String>{'content-type': 'text/plain'},
            );
          }),
        ),
        cache: FetchCache(),
      );
      await tool.execute(<String, dynamic>{
        'url': 'https://en.wikipedia.org/wiki/Test_(film)',
      });
      expect(requested?.path, '/wiki/Test_(film)');
    });

    test('cache key ignores a trailing slash', () async {
      var calls = 0;
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient((request) async {
            calls++;
            return http.Response(
              'ok',
              200,
              headers: <String, String>{'content-type': 'text/plain'},
            );
          }),
        ),
        cache: FetchCache(),
      );
      await tool.execute(<String, dynamic>{
        'url': 'https://example.com/article/',
      });
      await tool.execute(<String, dynamic>{
        'url': 'https://example.com/article',
      });
      expect(calls, 1);
    });

    test('cache hit keeps the original charset metadata', () async {
      final big5Sign = <int>[0xC1, 0x63, 0xC5, 0xE9, 0xA4, 0xA4, 0xA4, 0xE5];
      final bytes = Uint8List.fromList(<int>[
        ...utf8.encode('<html><body><article><p>'),
        ...List<List<int>>.generate(24, (_) => big5Sign).expand((row) => row),
        ...utf8.encode('</p></article></body></html>'),
      ]);
      var calls = 0;
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient((request) async {
            calls++;
            return http.Response.bytes(
              bytes,
              200,
              headers: <String, String>{
                'content-type': 'text/html; charset=big5',
              },
            );
          }),
        ),
        cache: FetchCache(),
      );
      final first = await tool.execute(<String, dynamic>{
        'url': 'https://example.com/big5',
      });
      final second = await tool.execute(<String, dynamic>{
        'url': 'https://example.com/big5',
      });
      expect(calls, 1);
      expect(first, contains('Charset: big5'));
      expect(second, contains('Charset: big5'));
    });

    test('HTML over 200k is marked truncated', () async {
      final html = '<html><body><article><p>${'x' * 300000}</p>'
          '</article></body></html>';
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient(
            (request) async => http.Response(
              html,
              200,
              headers: <String, String>{
                'content-type': 'text/html; charset=utf-8',
              },
            ),
          ),
        ),
        cache: FetchCache(),
      );
      final text = await tool.execute(<String, dynamic>{
        'url': 'https://example.com/large',
        'max_length': 1000,
      });
      expect(text, contains('Truncated: content was capped'));
    });

    test('invalid selector reaches the model as invalid_arguments', () async {
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient(
            (request) async => http.Response(
              '<html><body><p>${'body text ' * 50}</p></body></html>',
              200,
              headers: <String, String>{
                'content-type': 'text/html; charset=utf-8',
              },
            ),
          ),
        ),
        cache: FetchCache(),
      );
      final text = await tool.execute(<String, dynamic>{
        'url': 'https://example.com/selector',
        'selector': 'div[',
      });
      expect(text, contains('"error":"invalid_arguments"'));
    });

    test('403 browser challenge gets a non-retry instruction', () async {
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient(
            (request) async => http.Response(
              '<!DOCTYPE html><title>Checking your browser...</title>'
              '<script src="/__challenge/probes.js"></script>',
              403,
              headers: <String, String>{'content-type': 'text/html'},
            ),
          ),
        ),
        cache: FetchCache(),
      );
      final text = await tool.execute(<String, dynamic>{
        'url': 'https://example.com/blocked',
      });
      expect(text, contains('"error":"bot_challenge"'));
      expect(text, contains('hashcash'));
      expect(text, contains('Do not retry this URL'));
    });
  });

  group('transport hardening', () {
    test('POST JSON body gets a content type by default', () async {
      http.Request? captured;
      final core = _core(
        MockClient((request) async {
          captured = request;
          return http.Response(
            'ok',
            200,
            headers: <String, String>{'content-type': 'text/plain'},
          );
        }),
      );
      await core.fetch(
        FetchRequest(
          url: Uri.parse('https://example.com/api'),
          method: 'POST',
          body: '{"a":1}',
        ),
      );
      expect(captured, isNotNull);
      expect(
        captured!.headers['content-type'],
        startsWith('application/json'),
      );
    });

    test('custom User-Agent cannot replace the browser UA', () async {
      http.Request? captured;
      final core = _core(
        MockClient((request) async {
          captured = request;
          return http.Response(
            'ok',
            200,
            headers: <String, String>{'content-type': 'text/plain'},
          );
        }),
      );
      await core.fetch(
        FetchRequest(
          url: Uri.parse('https://example.com/'),
          headers: <String, String>{'User-Agent': 'curl/8'},
        ),
      );
      expect(captured!.headers['user-agent'], isNot('curl/8'));
    });

    test('cross-origin redirect drops custom credential headers', () async {
      http.Request? redirected;
      final core = _core(
        MockClient((request) async {
          if (request.url.host == 'example.com') {
            return http.Response(
              '',
              302,
              headers: <String, String>{
                'location': 'https://other.example/next',
              },
            );
          }
          redirected = request;
          return http.Response(
            'ok',
            200,
            headers: <String, String>{'content-type': 'text/plain'},
          );
        }),
      );
      await core.fetch(
        FetchRequest(
          url: Uri.parse('https://example.com/start'),
          headers: <String, String>{'X-Api-Key': 'secret'},
        ),
      );
      expect(redirected, isNotNull);
      expect(redirected!.headers['x-api-key'], isNull);
    });

    test('HTML extraction caps at 200k and sets the flag', () async {
      final html = '<html><body><article><p>${'x' * 300000}</p>'
          '</article></body></html>';
      final core = _core(
        MockClient(
          (request) async => http.Response(
            html,
            200,
            headers: <String, String>{
              'content-type': 'text/html; charset=utf-8',
            },
          ),
        ),
      );
      final result = await core.fetch(
        FetchRequest(url: Uri.parse('https://example.com/cap')),
      );
      expect(result.content.length, FetchCore.maxExtractedChars);
      expect(result.truncated, isTrue);
    });

    test('octet-stream PDF over 2 MB is sniffed before the cap', () async {
      final bytes = Uint8List(2100 * 1024)
        ..setRange(0, 5, utf8.encode('%PDF-'));
      final core = _core(
        MockClient(
          (request) async => http.Response.bytes(
            bytes,
            200,
            headers: <String, String>{
              'content-type': 'application/octet-stream',
            },
          ),
        ),
      );
      await expectLater(
        core.fetch(
          FetchRequest(
            url: Uri.parse('https://example.com/doc.pdf'),
            raw: true,
          ),
        ),
        throwsA(
          isA<FetchException>().having(
            (e) => e.code,
            'code',
            isNot('response_too_large'),
          ),
        ),
      );
    });

    test('POST is not retried on 503', () async {
      var calls = 0;
      final core = _core(
        MockClient((request) async {
          calls++;
          return http.Response('busy', 503);
        }),
      );
      await expectLater(
        core.fetch(
          FetchRequest(
            url: Uri.parse('https://example.com/post'),
            method: 'POST',
            body: 'a=1',
          ),
        ),
        throwsA(isA<FetchException>()),
      );
      expect(calls, 1);
    });
  });

  group('request logging', () {
    test('redacts authorization and API-key headers', () {
      final redacted = RequestLogger.redactHeaders(<String, String>{
        'Authorization': 'Bearer secret',
        'X-Api-Key': 'secret',
        'Accept': 'text/html',
      });
      expect(redacted['Authorization'], '***');
      expect(redacted['X-Api-Key'], '***');
      expect(redacted['Accept'], 'text/html');
    });
  });

  group('Tier 2 state', () {
    test('deleting a pinned fetch provider resets the source to local', () async {
      final settings = await _settings();
      await settings.setSearchServices(<SearchServiceOptions>[
        TavilyOptions(id: 'tavily-1', apiKey: 'test-key'),
      ]);
      await settings.setSearchSelectedProviders(<String>['tavily-1']);
      await settings.setWebFetchSource('tavily-1');
      expect(settings.webFetchSource, 'tavily-1');
      await settings.setSearchServices(<SearchServiceOptions>[
        SearchServiceOptions.defaultOption,
      ]);
      expect(settings.webFetchSource, 'local');
    });

    test('a provider failure is surfaced in the tool output', () async {
      final settings = await _settings();
      await settings.setSearchServices(<SearchServiceOptions>[
        TavilyOptions(id: 'tavily-1', apiKey: 'test-key'),
      ]);
      await settings.setSearchSelectedProviders(<String>['tavily-1']);
      await settings.setWebFetchSource('tavily-1');
      final service = FetchSourceService(
        client: MockClient((request) async => http.Response('busy', 500)),
        cooldown: ProviderCooldown(),
      );
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient(
            (request) async => http.Response(
              'local content',
              200,
              headers: <String, String>{'content-type': 'text/plain'},
            ),
          ),
        ),
        sourceService: service,
        cache: FetchCache(),
      );
      final text = await tool.execute(<String, dynamic>{
        'url': 'https://example.com/fallback',
      });
      expect(text, contains('Escalation:'));
      expect(text, contains('HTTP 500'));
    });

    test('not attempting a provider is not reported as rate limited', () async {
      final settings = await _settings();
      await settings.setSearchServices(<SearchServiceOptions>[
        TavilyOptions(id: 'tavily-1', apiKey: 'test-key'),
      ]);
      await settings.setSearchSelectedProviders(<String>['tavily-1']);
      await settings.setWebFetchSource('tavily-1');
      final service = FetchSourceService(
        client: MockClient(
          (request) async => fail('provider must not be called'),
        ),
        cooldown: ProviderCooldown(),
      );
      final outcome = await service.fetch(
        request: FetchRequest(
          url: Uri.parse('https://example.com/a'),
          raw: true,
        ),
        settings: settings,
        localCore: _core(
          MockClient(
            (request) async => http.Response(
              'local',
              200,
              headers: <String, String>{'content-type': 'text/plain'},
            ),
          ),
        ),
        allowEscalation: false,
      );
      expect(outcome.source, 'local');
      expect(outcome.escalated, isFalse);
      expect(outcome.escalationError, isNull);
    });
  });
}
