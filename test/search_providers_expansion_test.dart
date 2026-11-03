import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:OmniChat/core/services/search/providers/anysearch_search_service.dart';
import 'package:OmniChat/core/services/search/providers/deepseek_search_service.dart';
import 'package:OmniChat/core/services/search/providers/parallel_search_service.dart';
import 'package:OmniChat/core/services/search/providers/you_search_service.dart';
import 'package:OmniChat/core/services/search/search_service.dart';
import 'package:OmniChat/core/services/web/provider_adapters.dart';

void main() {
  group('AnySearch', () {
    test('search is keyless by default and clamps max_results to 10', () async {
      late http.Request request;
      final client = MockClient((req) async {
        request = req as http.Request;
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'results': [
                {
                  'title': 'Result',
                  'url': 'https://example.com',
                  'snippet': 'Snippet',
                },
              ],
            },
          }),
          200,
        );
      });
      final service = AnySearchSearchService(client: client);

      final result = await service.search(
        query: 'flutter',
        commonOptions: const SearchCommonOptions(resultSize: 50),
        serviceOptions: AnySearchOptions(id: 'any'),
      );

      expect(request.url.toString(), 'https://api.anysearch.com/v1/search');
      expect(request.headers['Authorization'], isNull);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['query'], 'flutter');
      expect(body['max_results'], 10);
      expect(body['format'], 'json');
      expect(result.items.single.text, 'Snippet');
    });

    test('search sends bearer key and surfaces code/message errors', () async {
      final client = MockClient(
        (req) async => http.Response(
          jsonEncode({
            'code': 401,
            'message': 'invalid key',
            'request_id': 'req-1',
          }),
          200,
        ),
      );
      final service = AnySearchSearchService(client: client);

      await expectLater(
        service.search(
          query: 'q',
          commonOptions: const SearchCommonOptions(),
          serviceOptions: AnySearchOptions(id: 'any', apiKey: 'secret'),
        ),
        throwsA(
          predicate(
            (e) =>
                e.toString().contains('invalid key') &&
                e.toString().contains('req-1'),
          ),
        ),
      );
    });

    test('fetch adapter uses sibling /extract endpoint', () {
      final adapter = providerFetchAdapterFor('anysearch')!;
      final uri = adapter.uriBuilder(
        'https://example.com',
        AnySearchOptions(
          id: 'any',
          apiKey: 'k',
          url: 'https://gateway.example.com/v1/search',
        ),
      );
      expect(uri.toString(), 'https://gateway.example.com/v1/extract');
      expect(
        adapter.bodyBuilder!('https://example.com', AnySearchOptions(id: 'a')),
        {'url': 'https://example.com'},
      );
      expect(
        adapter.errorExtractor!({'code': 429, 'message': 'quota'}),
        contains('quota'),
      );
      expect(
        adapter.contentExtractor({
          'data': {'title': 'T', 'content': 'C'},
        }),
        'C',
      );
    });
  });

  group('DeepSeek Search', () {
    test('search clamps count to 50 and prefers summary with date', () async {
      late http.Request request;
      final client = MockClient((req) async {
        request = req as http.Request;
        return http.Response(
          jsonEncode({
            'results': [
              {
                'title': 'Deep',
                'url': 'https://example.com/deep',
                'snippet': 'short',
                'summary': 'long summary',
                'date': '2026-11-02T00:00:00Z',
              },
            ],
          }),
          200,
        );
      });
      final service = DeepSeekSearchService(client: client);

      final result = await service.search(
        query: 'q',
        commonOptions: const SearchCommonOptions(resultSize: 99),
        serviceOptions: DeepSeekSearchOptions(id: 'ds', apiKey: 'key'),
      );

      expect(request.headers['Authorization'], 'Bearer key');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['count'], 50);
      expect(body['need_content'], false);
      expect(result.items.single.text, contains('long summary'));
      expect(result.items.single.text, startsWith('[Published: 2026-11-02]'));
    });

    test('fetch adapter maps markdown content and title', () {
      final adapter = providerFetchAdapterFor('deepseek')!;
      expect(
        adapter.contentExtractor({'content': '# Body', 'title': 'Title'}),
        '# Body',
      );
      expect(adapter.titleExtractor!({'title': 'Title'}), 'Title');
    });
  });

  group('Parallel', () {
    test('search uses x-api-key and nested advanced_settings', () async {
      late http.Request request;
      final client = MockClient((req) async {
        request = req as http.Request;
        return http.Response(
          jsonEncode({
            'results': [
              {
                'title': 'Parallel result',
                'url': 'https://example.com/p',
                'excerpts': ['one', 'two'],
              },
            ],
          }),
          200,
        );
      });
      final service = ParallelSearchService(client: client);

      final result = await service.search(
        query: 'q',
        commonOptions: const SearchCommonOptions(resultSize: 50),
        serviceOptions: ParallelOptions(id: 'p', apiKey: 'key', mode: 'basic'),
      );

      expect(request.headers['x-api-key'], 'key');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['objective'], 'q');
      expect(body['mode'], 'basic');
      expect((body['advanced_settings'] as Map)['max_results'], 20);
      expect(result.items.single.text, 'one\n\ntwo');
    });

    test('fetch adapter joins excerpts when full_content is absent', () {
      final adapter = providerFetchAdapterFor('parallel')!;
      expect(
        adapter.contentExtractor({
          'results': [
            {
              'excerpts': ['alpha', 'beta'],
            },
          ],
        }),
        'alpha\n\nbeta',
      );
      expect(
        adapter.errorExtractor!({
          'errors': [
            {
              'error_type': 'rate_limited',
              'http_status_code': 429,
              'message': 'slow down',
            },
          ],
        }),
        contains('429'),
      );
    });
  });

  group('You.com', () {
    test('search merges web and news results with highlights', () async {
      late http.Request request;
      final client = MockClient((req) async {
        request = req as http.Request;
        return http.Response(
          jsonEncode({
            'results': {
              'web': [
                {
                  'title': 'Web',
                  'url': 'https://example.com/w',
                  'contents': {
                    'highlights': ['highlight one', 'highlight two'],
                  },
                },
              ],
              'news': [
                {
                  'title': 'News',
                  'url': 'https://example.com/n',
                  'description': 'news description',
                },
              ],
            },
          }),
          200,
        );
      });
      final service = YouSearchService(client: client);

      final result = await service.search(
        query: 'q',
        commonOptions: const SearchCommonOptions(resultSize: 10),
        serviceOptions: YouSearchOptions(id: 'y', apiKey: 'key'),
      );

      expect(request.headers['X-API-Key'], 'key');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['count'], 10);
      expect(body['extraction'], {'extraction_mode': 'highlights'});
      expect(result.items, hasLength(2));
      expect(result.items.first.text, 'highlight one\n\nhighlight two');
      expect(result.items.last.text, 'news description');
    });

    test('fetch adapter maps markdown from the array response', () {
      final adapter = providerFetchAdapterFor('you')!;
      expect(
        adapter.contentExtractor([
          {'markdown': '# Page', 'title': 'Page'},
        ]),
        '# Page',
      );
      expect(
        adapter.titleExtractor!([
          {'markdown': '# Page', 'title': 'Page'},
        ]),
        'Page',
      );
    });
  });

  test('new options round-trip through fromJson/toJson', () {
    final options = <SearchServiceOptions>[
      AnySearchOptions(id: 'a', apiKey: 'k', zone: 'cn', language: 'zh'),
      DeepSeekSearchOptions(id: 'd', apiKey: 'k'),
      ParallelOptions(id: 'p', apiKey: 'k', mode: 'advanced'),
      YouSearchOptions(id: 'y', apiKey: 'k', contentMode: 'snippets'),
      ExaMcpOptions(id: 'e', apiKey: 'k', url: 'https://mcp.example.com'),
    ];
    for (final option in options) {
      final restored = SearchServiceOptions.fromJson(option.toJson());
      expect(restored.runtimeType, option.runtimeType);
      expect(restored.toJson(), option.toJson());
    }
  });
}
