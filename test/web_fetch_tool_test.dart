import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/search/search_service.dart';
import 'package:OmniChat/core/services/web/fetch_cache.dart';
import 'package:OmniChat/core/services/web/fetch_core.dart';
import 'package:OmniChat/core/services/web/fetch_source_service.dart';
import 'package:OmniChat/core/services/web/ssrf_guard.dart';
import 'package:OmniChat/core/services/web/web_fetch_tool.dart';

Future<SettingsProvider> _loadedSettings({
  bool allowPost = false,
  String source = 'local',
  List<SearchServiceOptions> services = const <SearchServiceOptions>[],
  List<String> selected = const <String>[],
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final sp = SettingsProvider();
  final done = Completer<void>();
  void listener() {
    if (!done.isCompleted) done.complete();
  }

  sp.addListener(listener);
  await done.future.timeout(const Duration(seconds: 10));
  sp.removeListener(listener);

  await sp.setWebFetchEnabled(true);
  await sp.setWebFetchAllowPost(allowPost);
  await sp.setWebFetchSource(source);
  if (services.isNotEmpty) {
    await sp.setSearchServices(services);
    await sp.setSearchSelectedProviders(selected);
  }
  return sp;
}

FetchCore _core(http.Client client) => FetchCore(
  client: client,
  guard: SsrfGuard(
    lookup: (host) async => <InternetAddress>[
      InternetAddress('93.184.216.34'),
    ],
  ),
  sleep: (_) async {},
);

String _window(String text) {
  final index = text.indexOf('---\n\n');
  return index < 0 ? '' : text.substring(index + 5);
}

void main() {
  group('tool definition and aliases', () {
    test('only web_fetch is advertised', () {
      final def = WebFetchTool.getToolDefinition();
      final fn = def['function'] as Map<String, dynamic>;
      expect(fn['name'], 'web_fetch');
      final description = fn['description'] as String;
      expect(description, contains('next_start_index'));
      expect(description, isNot(contains('fetch_html')));

      final params =
          (fn['parameters'] as Map<String, dynamic>)['properties']
              as Map<String, dynamic>;
      expect(
        params.keys,
        containsAll(<String>[
          'url',
          'method',
          'headers',
          'body',
          'raw',
          'selector',
          'max_length',
          'start_index',
        ]),
      );
    });

    test('legacy names resolve to web_fetch', () {
      for (final alias in <String>[
        'read_page',
        'fetch_url',
        'fetch_html',
        'fetch_markdown',
        'fetch_txt',
        'fetch_json',
      ]) {
        expect(WebFetchTool.canonicalToolName(alias), 'web_fetch');
      }
      expect(WebFetchTool.canonicalToolName('search_web'), 'search_web');
    });
  });

  group('argument validation', () {
    late SettingsProvider settings;
    late WebFetchTool tool;

    setUp(() async {
      settings = await _loadedSettings();
      tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient(
            (request) async => http.Response(
              'ok',
              200,
              headers: {'content-type': 'text/plain'},
            ),
          ),
        ),
        cache: FetchCache(),
      );
    });

    Future<Map<String, dynamic>> run(Map<String, dynamic> args) async {
      final text = await tool.execute(args);
      return jsonDecode(text) as Map<String, dynamic>;
    }

    test('missing / relative URL is invalid_url', () async {
      expect((await run({'url': 'example.com'}))['error'], 'invalid_url');
      expect((await run({'url': 'ftp://x/y'}))['error'], 'invalid_url');
      expect((await run({}))['error'], 'invalid_arguments');
    });

    test('body without POST is invalid_arguments', () async {
      expect(
        (await run({'url': 'https://example.com', 'body': 'x'}))['error'],
        'invalid_arguments',
      );
    });

    test('raw + selector is invalid_arguments', () async {
      expect(
        (await run({
          'url': 'https://example.com',
          'raw': true,
          'selector': '#main',
        }))['error'],
        'invalid_arguments',
      );
    });

    test('max_length out of range is invalid_arguments', () async {
      expect(
        (await run({
          'url': 'https://example.com',
          'max_length': 20001,
        }))['error'],
        'invalid_arguments',
      );
      expect(
        (await run({
          'url': 'https://example.com',
          'max_length': 0,
        }))['error'],
        'invalid_arguments',
      );
    });

    test('negative start_index is invalid_arguments', () async {
      expect(
        (await run({
          'url': 'https://example.com',
          'start_index': -1,
        }))['error'],
        'invalid_arguments',
      );
    });

    test('POST without permission returns post_disabled', () async {
      final error = await run({
        'url': 'https://example.com/api',
        'method': 'POST',
        'body': '{"a":1}',
      });
      expect(error['error'], 'post_disabled');
    });
  });

  group('pagination', () {
    test('windows do not overlap or leave gaps', () async {
      final content = List<String>.generate(1200, (_) => 'abcdefghij').join();
      final settings = await _loadedSettings();
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient(
            (request) async => http.Response(
              content,
              200,
              headers: {'content-type': 'text/plain'},
            ),
          ),
        ),
        cache: FetchCache(),
      );

      final first = await tool.execute({
        'url': 'https://example.com/long',
        'max_length': 5000,
      });
      expect(first, contains('Total length: 12000'));
      expect(first, contains('Showing: 0-4999'));
      expect(first, contains('Next start_index: 5000'));

      final second = await tool.execute({
        'url': 'https://example.com/long',
        'start_index': 5000,
        'max_length': 5000,
      });
      expect(second, contains('Showing: 5000-9999'));

      final third = await tool.execute({
        'url': 'https://example.com/long',
        'start_index': 10000,
        'max_length': 5000,
      });
      expect(third, contains('Showing: 10000-11999'));
      expect(third, isNot(contains('Next start_index')));

      expect(
        _window(first) + _window(second) + _window(third),
        content,
      );
    });

    test('start_index past the end returns no_more_content', () async {
      final settings = await _loadedSettings();
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient(
            (request) async => http.Response(
              'short',
              200,
              headers: {'content-type': 'text/plain'},
            ),
          ),
        ),
        cache: FetchCache(),
      );
      final text = await tool.execute({
        'url': 'https://example.com/short',
        'start_index': 99,
      });
      expect(
        (jsonDecode(text) as Map<String, dynamic>)['error'],
        'no_more_content',
      );
    });

    test('surrogate pairs are never split', () async {
      final content = '😀' * 300;
      final settings = await _loadedSettings();
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient(
            (request) async => http.Response(
              content,
              200,
              headers: {'content-type': 'text/plain; charset=utf-8'},
            ),
          ),
        ),
        cache: FetchCache(),
      );
      final collected = StringBuffer();
      var start = 0;
      while (true) {
        final text = await tool.execute({
          'url': 'https://example.com/emoji',
          'start_index': start,
          'max_length': 3,
        });
        if (text.startsWith('{')) {
          expect(
            (jsonDecode(text) as Map<String, dynamic>)['error'],
            'no_more_content',
          );
          break;
        }
        final window = _window(text);
        for (final unit in window.codeUnits) {
          // No lone surrogate at either end of a window.
          if (unit >= 0xDC00 && unit <= 0xDFFF) {
            expect(
              window.codeUnits.first,
              isNot(unit),
              reason: 'window starts with a low surrogate',
            );
          }
        }
        collected.write(window);
        final match = RegExp(
          r'Next start_index: (\d+)',
        ).firstMatch(text);
        if (match == null) break;
        start = int.parse(match.group(1)!);
      }
      expect(collected.toString(), content);
    });
  });

  group('policy matrix', () {
    Future<int> runTwice(Map<String, dynamic> args) async {
      var requests = 0;
      final settings = await _loadedSettings(allowPost: true);
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient((request) async {
            requests++;
            return http.Response(
              'policy body',
              200,
              headers: {'content-type': 'text/plain'},
            );
          }),
        ),
        cache: FetchCache(),
      );
      await tool.execute({'url': 'https://example.com/p', ...args});
      await tool.execute({'url': 'https://example.com/p', ...args});
      return requests;
    }

    test('plain GET is cached', () async {
      expect(await runTwice(<String, dynamic>{}), 1);
    });

    test('raw=true is never cached', () async {
      expect(await runTwice(<String, dynamic>{'raw': true}), 2);
    });

    test('custom header is never cached', () async {
      expect(
        await runTwice(<String, dynamic>{
          'headers': <String, String>{'accept': 'text/html'},
        }),
        2,
      );
    });

    test('selector is never cached', () async {
      expect(await runTwice(<String, dynamic>{'selector': 'body'}), 2);
    });

    test('POST is never cached', () async {
      expect(
        await runTwice(<String, dynamic>{
          'method': 'POST',
          'body': '{}',
        }),
        2,
      );
    });
  });

  group('source pinning', () {
    late SettingsProvider settings;

    setUp(() async {
      settings = await _loadedSettings(
        services: <SearchServiceOptions>[
          TavilyOptions(id: 'tavily-1', apiKey: 'tvly-test'),
        ],
        selected: <String>['tavily-1'],
      );
    });

    test('a continuation reuses the cached source', () async {
      var requests = 0;
      final cache = FetchCache();
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient((request) async {
            requests++;
            return http.Response(
              'cached content that is long enough',
              200,
              headers: {'content-type': 'text/plain'},
            );
          }),
        ),
        cache: cache,
        sourceService: FetchSourceService(
          client: MockClient(
            (request) async => fail('provider must not be called'),
          ),
        ),
      );
      await settings.setWebFetchSource('local');
      await tool.execute({'url': 'https://example.com/pinned'});
      await settings.setWebFetchSource('tavily-1');
      final second = await tool.execute({
        'url': 'https://example.com/pinned',
        'start_index': 5,
      });
      expect(second, contains('Source: local'));
      expect(requests, 1);
    });

    test('an unavailable pinned source returns source_changed', () async {
      final cache = FetchCache(ttl: Duration.zero);
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient(
            (request) async => http.Response(
              'cached content that is long enough',
              200,
              headers: {'content-type': 'text/plain'},
            ),
          ),
        ),
        cache: cache,
        sourceService: FetchSourceService(),
      );
      await settings.setWebFetchSource('local');
      await tool.execute({'url': 'https://example.com/pinned'});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await settings.setWebFetchSource('tavily-1');
      final second = await tool.execute({
        'url': 'https://example.com/pinned',
        'start_index': 5,
      });
      expect(
        (jsonDecode(second) as Map<String, dynamic>)['error'],
        'source_changed',
      );
    });
  });

  group('http errors', () {
    test('404 points at search_web instead of retrying', () async {
      final settings = await _loadedSettings();
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient(
            (request) async => http.Response(
              '<html><body>not found</body></html>',
              404,
              headers: {'content-type': 'text/html'},
            ),
          ),
        ),
        cache: FetchCache(),
      );
      final text = await tool.execute({'url': 'https://example.com/missing'});
      final error = jsonDecode(text) as Map<String, dynamic>;
      expect(error['error'], 'http_error');
      expect(error['instruction'], contains('does not exist'));
      expect(error['instruction'], contains('search_web'));
    });
  });

  group('bot challenges', () {
    test('403 Cloudflare challenge becomes bot_challenge without body', () async {
      final settings = await _loadedSettings();
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient(
            (request) async => http.Response(
              '<html><script src="https://challenges.cloudflare.com/turnstile/v0/api.js">'
              '</script><p>Verify you are human</p></html>',
              403,
              headers: {'content-type': 'text/html'},
            ),
          ),
        ),
        cache: FetchCache(),
      );
      final text = await tool.execute({'url': 'https://example.com/cf'});
      final error = jsonDecode(text) as Map<String, dynamic>;
      expect(error['error'], 'bot_challenge');
      expect(error['challenge'], 'Cloudflare');
      expect(error['status'], 403);
      expect(error['instruction'], contains('Do not retry this URL'));
      expect(error.containsKey('body'), isFalse);
    });

    test('raw challenge keeps the body and adds a Challenge header', () async {
      final settings = await _loadedSettings();
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient(
            (request) async => http.Response(
              '<html><body><form id="js_challenge">'
              '<input name="jsc_token">raw challenge body</form>'
              '</body></html>',
              200,
              headers: {'content-type': 'text/html'},
            ),
          ),
        ),
        cache: FetchCache(),
      );
      final text = await tool.execute({
        'url': 'https://example.com/reddit',
        'raw': true,
      });
      expect(text, contains('Challenge: Reddit'));
      expect(text, contains('raw challenge body'));
    });

    test('generic 403 body is capped', () async {
      final settings = await _loadedSettings();
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient(
            (request) async => http.Response(
              '<html><body>${'x' * 5000}</body></html>',
              403,
              headers: {'content-type': 'text/html'},
            ),
          ),
        ),
        cache: FetchCache(),
      );
      final text = await tool.execute({'url': 'https://example.com/403'});
      final error = jsonDecode(text) as Map<String, dynamic>;
      expect(error['error'], 'http_error');
      expect((error['body'] as String).length, lessThanOrEqualTo(512));
    });

    test('no_readable_content points at JavaScript or a bot challenge', () async {
      final settings = await _loadedSettings();
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient(
            (request) async => http.Response(
              '<html><body><div> </div></body></html>',
              200,
              headers: {'content-type': 'text/html'},
            ),
          ),
        ),
        cache: FetchCache(),
      );
      final text = await tool.execute({'url': 'https://example.com/empty'});
      final error = jsonDecode(text) as Map<String, dynamic>;
      expect(error['error'], 'no_readable_content');
      expect(error['instruction'], contains('JavaScript'));
    });
  });

  group('aliases and binary', () {
    test('fetch_html keeps raw semantics', () async {
      final settings = await _loadedSettings();
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient(
            (request) async => http.Response(
              '<html><body><nav>raw nav</nav><p>body</p></body></html>',
              200,
              headers: {'content-type': 'text/html'},
            ),
          ),
        ),
        cache: FetchCache(),
      );
      final text = await tool.execute(
        {'url': 'https://example.com/raw'},
        invokedName: 'fetch_html',
      );
      expect(text, contains('<nav>raw nav</nav>'));
    });

    test('raw binary returns unsupported_binary', () async {
      final settings = await _loadedSettings();
      final tool = WebFetchTool(
        settings: settings,
        core: _core(
          MockClient(
            (request) async => http.Response.bytes(
              <int>[0x89, 0x50, 0x4E, 0x47],
              200,
              headers: {'content-type': 'image/png'},
            ),
          ),
        ),
        cache: FetchCache(),
      );
      final text = await tool.execute({
        'url': 'https://example.com/a.png',
        'raw': true,
      });
      expect(
        (jsonDecode(text) as Map<String, dynamic>)['error'],
        'unsupported_binary',
      );
    });
  });
}
