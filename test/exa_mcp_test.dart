import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/search/providers/exa_mcp_search_service.dart';
import 'package:OmniChat/core/services/search/search_service.dart';
import 'package:OmniChat/core/services/web/fetch_core.dart';
import 'package:OmniChat/core/services/web/fetch_source_service.dart';
import 'package:OmniChat/core/services/web/ssrf_guard.dart';

class _FakeExaMcpServer {
  _FakeExaMcpServer(this.server) {
    server.listen(_handle);
  }

  final HttpServer server;
  final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];
  final List<Map<String, String>> headers = <Map<String, String>>[];
  String searchText = '';
  String fetchText = '';
  bool toolError = false;
  bool forbidden = false;

  String get url => 'http://${server.address.address}:${server.port}/mcp';

  Future<void> _handle(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    final capturedHeaders = <String, String>{};
    request.headers.forEach((key, values) {
      capturedHeaders[key] = values.join(',');
    });
    headers.add(capturedHeaders);
    if (forbidden) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write('forbidden');
      await request.response.close();
      return;
    }
    if (raw.isEmpty) {
      request.response.statusCode = HttpStatus.accepted;
      await request.response.close();
      return;
    }
    final message = jsonDecode(raw) as Map<String, dynamic>;
    final method = (message['method'] ?? '').toString();
    if (method == 'initialize') {
      _json(request, {
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': {
          'protocolVersion': '2025-03-26',
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {'name': 'fake-exa', 'version': '1.0.0'},
        },
      });
      return;
    }
    if (method == 'notifications/initialized') {
      request.response.statusCode = HttpStatus.accepted;
      await request.response.close();
      return;
    }
    if (method == 'tools/call') {
      final params = (message['params'] as Map).cast<String, dynamic>();
      final name = (params['name'] ?? '').toString();
      final args = (params['arguments'] as Map?)?.cast<String, dynamic>() ?? {};
      calls.add({'name': name, 'arguments': args});
      final text = name == 'web_fetch_exa' ? fetchText : searchText;
      _json(request, {
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': {
          'content': [
            {'type': 'text', 'text': text},
          ],
          'isError': toolError,
        },
      });
      return;
    }
    _json(request, {
      'jsonrpc': '2.0',
      'id': message['id'],
      'error': {'code': -32601, 'message': 'method not found'},
    });
  }

  void _json(HttpRequest request, Map<String, dynamic> body) {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    request.response.close();
  }
}

void main() {
  late _FakeExaMcpServer fake;

  setUp(() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fake = _FakeExaMcpServer(server);
    addTearDown(() => server.close(force: true));
  });

  test('search performs an MCP handshake and parses result metadata', () async {
    fake.searchText = [
      'Title: Example',
      'URL: https://example.com/a',
      'Published: 2026-11-01',
      'Author: Test',
      'Highlights:',
      'hello world',
      '',
      '---',
      '',
      'Title: Second',
      'URL: https://example.com/b',
      'Published: N/A',
      'Author: N/A',
      'Text:',
      'second body',
    ].join('\n');

    final service = ExaMcpSearchService();
    final result = await service.search(
      query: 'hello',
      commonOptions: const SearchCommonOptions(resultSize: 2),
      serviceOptions: ExaMcpOptions(id: 'exa', apiKey: 'secret', url: fake.url),
    );

    expect(result.items, hasLength(2));
    expect(result.items.first.title, 'Example');
    expect(result.items.first.url, 'https://example.com/a');
    expect(result.items.first.text, 'hello world');
    expect(result.items.last.title, 'Second');
    expect(fake.headers.any((h) => (h['x-api-key'] ?? '') == 'secret'), isTrue);
    final call = fake.calls.single;
    expect(call['name'], 'web_search_exa');
    expect((call['arguments'] as Map)['query'], 'hello');
    expect((call['arguments'] as Map)['numResults'], 2);
  });

  test('fetch parses the Markdown page payload', () async {
    fake.fetchText = [
      '# Example page',
      'URL: https://example.com/page',
      '',
      'Body content',
    ].join('\n');

    final service = ExaMcpSearchService();
    final page = await service.fetch(
      url: 'https://example.com/page',
      commonOptions: const SearchCommonOptions(),
      serviceOptions: ExaMcpOptions(id: 'exa', url: fake.url),
    );

    expect(page.title, 'Example page');
    expect(page.url, 'https://example.com/page');
    expect(page.content, 'Body content');
    final call = fake.calls.single;
    expect(call['name'], 'web_fetch_exa');
    expect((call['arguments'] as Map)['urls'], ['https://example.com/page']);
    expect((call['arguments'] as Map)['maxCharacters'], 100000);
  });

  test(
    'FetchSourceService resolves and dispatches the capability source',
    () async {
      fake.fetchText = '# Page\nURL: https://example.com/page\n\nExa content';
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final settings = SettingsProvider();
      final ready = Completer<void>();
      void listener() {
        if (!ready.isCompleted) ready.complete();
      }

      settings.addListener(listener);
      await ready.future.timeout(const Duration(seconds: 10));
      settings.removeListener(listener);
      final options = ExaMcpOptions(id: 'exa', url: fake.url);
      await settings.setSearchServices([options]);
      await settings.setWebFetchSource('exa');

      final service = FetchSourceService(
        guard: SsrfGuard(
          lookup: (host) async => <InternetAddress>[
            InternetAddress('93.184.216.34'),
          ],
        ),
      );
      final resolved = service.resolve(settings);
      expect(resolved.source, 'exa_mcp');
      expect(resolved.displayName, 'Exa MCP');
      expect(resolved.isCapability, isTrue);
      expect(resolved.isLocal, isFalse);

      final local = FetchCore(
        client: MockClient(
          (request) async => http.Response('local content', 200),
        ),
        guard: SsrfGuard(
          lookup: (host) async => <InternetAddress>[
            InternetAddress('93.184.216.34'),
          ],
        ),
      );
      final outcome = await service.fetch(
        request: FetchRequest(url: Uri.parse('https://example.com/page')),
        settings: settings,
        localCore: local,
      );

      expect(outcome.source, 'exa_mcp');
      expect(outcome.sourceName, 'Exa MCP');
      expect(outcome.result.content, 'Exa content');
      expect(outcome.escalated, isFalse);
    },
  );

  test('HTTP 403 fails fast with the keyless direct-IPv4 guidance', () async {
    fake.forbidden = true;
    final service = ExaMcpSearchService();

    await expectLater(
      service
          .search(
            query: 'q',
            commonOptions: const SearchCommonOptions(),
            serviceOptions: ExaMcpOptions(id: 'exa', url: fake.url),
          )
          .timeout(const Duration(seconds: 5)),
      throwsA(
        predicate(
          (e) =>
              e.toString().contains('403') &&
              e.toString().contains('direct IPv4'),
        ),
      ),
    );
  });

  test('MCP isError and quota text are surfaced as failures', () async {
    fake.toolError = true;
    fake.searchText = 'quota exceeded';
    final service = ExaMcpSearchService();

    await expectLater(
      service.search(
        query: 'q',
        commonOptions: const SearchCommonOptions(),
        serviceOptions: ExaMcpOptions(id: 'exa', url: fake.url),
      ),
      throwsA(predicate((e) => e.toString().contains('quota exceeded'))),
    );
  });
}
