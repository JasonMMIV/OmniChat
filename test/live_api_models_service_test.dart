import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:OmniChat/core/services/live/live_api_models_service.dart';

void main() {
  group('LiveApiModelsService.modelsUri', () {
    test('official host uses root path without port', () {
      expect(
        LiveApiModelsService.modelsUri(null).toString(),
        'https://generativelanguage.googleapis.com/v1beta/models',
      );
      expect(
        LiveApiModelsService.modelsUri(
          'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent',
        ).toString(),
        'https://generativelanguage.googleapis.com/v1beta/models',
      );
    });

    test('custom endpoint preserves port and strips /ws/ path', () {
      final uri = LiveApiModelsService.modelsUri(
        'wss://live.example.com:8443/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent',
      );
      expect(uri.scheme, 'https');
      expect(uri.host, 'live.example.com');
      expect(uri.port, 8443);
      expect(uri.path, '/v1beta/models');
    });

    test('custom endpoint keeps non-ws path prefix', () {
      final uri = LiveApiModelsService.modelsUri('wss://gw.example.com/v1/live');
      expect(uri.host, 'gw.example.com');
      expect(uri.path, '/v1/live/v1beta/models');
    });

    test('invalid baseUrl falls back to official endpoint', () {
      expect(
        LiveApiModelsService.modelsUri('not-a-url').toString(),
        'https://generativelanguage.googleapis.com/v1beta/models',
      );
      expect(
        LiveApiModelsService.modelsUri('http://insecure.example.com/ws').toString(),
        'https://generativelanguage.googleapis.com/v1beta/models',
      );
    });
  });

  group('LiveApiModelsService.parseModels', () {
    test('keeps models with supportsLiveGeneration=true', () {
      final body = jsonEncode({
        'models': [
          {
            'name': 'models/gemini-3.1-flash-live-preview',
            'supportsLiveGeneration': true,
            'supportedGenerationMethods': ['generateContent'],
          },
          {
            'name': 'models/gemini-2.5-pro',
            'supportedGenerationMethods': ['generateContent'],
          },
        ],
      });
      expect(LiveApiModelsService.parseModels(body), [
        'gemini-3.1-flash-live-preview',
      ]);
    });

    test('keeps models declaring bidiGenerateContent (real API shape)', () {
      final body = jsonEncode({
        'models': [
          {
            'name': 'models/gemini-2.5-flash-native-audio-preview-12-2025',
            'supportedGenerationMethods': ['countTokens', 'bidiGenerateContent'],
          },
          {
            'name': 'models/gemini-3.1-flash-live-preview',
            'supportedGenerationMethods': ['bidiGenerateContent'],
          },
          {
            'name': 'models/gemini-3.5-live-translate-preview',
            'supportedGenerationMethods': ['countTokens', 'bidiGenerateContent'],
          },
          {
            'name': 'models/gemini-2.5-pro',
            'supportedGenerationMethods': ['generateContent'],
          },
        ],
      });
      expect(LiveApiModelsService.parseModels(body), [
        'gemini-2.5-flash-native-audio-preview-12-2025',
        'gemini-3.1-flash-live-preview',
        'gemini-3.5-live-translate-preview',
      ]);
    });

    test('keeps names containing live when methods unset or support generateContent',
        () {
      final body = jsonEncode({
        'models': [
          {
            'name': 'models/gemini-2.0-flash-live-preview',
            'supportsLiveGeneration': false,
          },
          {
            'name': 'models/gemini-2.0-flash-live-preview-audio',
            'supportsLiveGeneration': true,
          },
        ],
      });
      expect(LiveApiModelsService.parseModels(body), [
        'gemini-2.0-flash-live-preview',
        'gemini-2.0-flash-live-preview-audio',
      ]);
    });

    test('rejects non-live models and sorts results', () {
      final body = jsonEncode({
        'models': [
          {
            'name': 'models/z-live-alpha',
            'supportsLiveGeneration': true,
          },
          {
            'name': 'models/gemini-2.5-pro',
            'supportedGenerationMethods': ['generateContent'],
          },
          {
            'name': 'models/a-flash-live',
            'supportsLiveGeneration': false,
            'supportedGenerationMethods': ['generateContent'],
          },
          {'name': 'models/broken'},
        ],
      });
      expect(LiveApiModelsService.parseModels(body), [
        'a-flash-live',
        'z-live-alpha',
      ]);
    });

    test('returns empty for malformed payloads', () {
      expect(LiveApiModelsService.parseModels('not json'), isEmpty);
      expect(LiveApiModelsService.parseModels('{"models": 42}'), isEmpty);
      expect(LiveApiModelsService.parseModels('{"models": []}'), isEmpty);
    });
  });

  group('maskApiKey（§5.8 診斷遮蔽）', () {
    test('redacts the key anywhere it appears', () {
      const msg =
          "WebSocketException: Connection to 'wss://example.com/ws?key=AIza-secret123' was not upgraded";
      final masked = maskApiKey(msg, 'AIza-secret123');
      expect(masked, isNot(contains('AIza-secret123')));
      expect(masked, contains('***'));
    });

    test('leaves messages without the key untouched', () {
      const msg = 'socket closed: no key here';
      expect(maskApiKey(msg, 'AIza-secret123'), msg);
    });

    test('empty key returns message as-is', () {
      const msg = 'connection reset by peer';
      expect(maskApiKey(msg, '   '), msg);
    });
  });

  group('LiveApiModelsService.fetchLiveModels', () {
    test('returns emptyKey error without network call', () async {
      final result = await LiveApiModelsService.fetchLiveModels(apiKey: '  ');
      expect(result.hasError, isTrue);
      expect(result.error, LiveApiModelsError.emptyKey);
    });

    test('parses successful response and caches it', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        expect(request.url.queryParameters['key'], 'AIza-test');
        expect(request.url.host, 'generativelanguage.googleapis.com');
        expect(request.url.queryParameters['pageSize'], '100');
        return http.Response(
          jsonEncode({
            'models': [
              {'name': 'models/gemini-3.1-flash-live-preview'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final first = await LiveApiModelsService.fetchLiveModels(
        apiKey: 'AIza-test',
        client: client,
      );
      expect(first.hasError, isFalse);
      expect(first.models, ['gemini-3.1-flash-live-preview']);
      // cached: second call must not hit the network
      final second = await LiveApiModelsService.fetchLiveModels(
        apiKey: 'AIza-test',
        client: client,
      );
      expect(second.models, ['gemini-3.1-flash-live-preview']);
      expect(calls, 1);
      LiveApiModelsService.invalidateCache();
    });

    test('network error detail masks the api key from the request uri',
        () async {
      final client = MockClient((request) async {
        throw http.ClientException(
          'Connection failed',
          request.url, // uri 含 `?key=...`
        );
      });
      final result = await LiveApiModelsService.fetchLiveModels(
        apiKey: 'AIza-leak-check',
        client: client,
      );
      expect(result.hasError, isTrue);
      expect(result.error, LiveApiModelsError.network);
      expect(result.detail, isNot(contains('AIza-leak-check')));
    });

    test('follows nextPageToken to collect all live models', () async {
      final client = MockClient((request) async {
        final token = request.url.queryParameters['pageToken'] ?? '';
        return http.Response(
          jsonEncode({
            'models': [
              {'name': 'models/gemini-2.5-pro'},
              if (token.isEmpty)
                {'name': 'models/gemini-3.1-flash-live-preview'},
              if (token == 'page-2')
                {'name': 'models/gemini-3.5-live-translate-preview'},
            ],
            if (token.isEmpty) 'nextPageToken': 'page-2',
          }),
          200,
        );
      });
      final result = await LiveApiModelsService.fetchLiveModels(
        apiKey: 'AIza-test',
        client: client,
      );
      expect(result.hasError, isFalse);
      expect(result.models, [
        'gemini-3.1-flash-live-preview',
        'gemini-3.5-live-translate-preview',
      ]);
      LiveApiModelsService.invalidateCache();
    });

    test('reports http error on non-200', () async {
      final client = MockClient((request) async => http.Response('{}', 401));
      final result = await LiveApiModelsService.fetchLiveModels(
        apiKey: 'bad-key',
        client: client,
      );
      expect(result.error, LiveApiModelsError.http);
      LiveApiModelsService.invalidateCache();
    });

    test('derives models endpoint host from custom baseUrl', () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'live.example.com');
        expect(request.url.path, '/v1beta/models');
        expect(request.url.port, 443);
        return http.Response(
          jsonEncode({
            'models': [
              {'name': 'models/gemini-3.1-flash-live-preview'},
            ],
          }),
          200,
        );
      });
      final result = await LiveApiModelsService.fetchLiveModels(
        apiKey: 'AIza-test',
        baseUrl:
            'wss://live.example.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent',
        client: client,
      );
      expect(result.hasError, isFalse);
      expect(result.models, ['gemini-3.1-flash-live-preview']);
      LiveApiModelsService.invalidateCache();
    });

    test('cache is scoped per api key', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response(
          jsonEncode({
            'models': [{'name': 'models/gemini-3.1-flash-live-preview'}],
          }),
          200,
        );
      });
      LiveApiModelsService.invalidateCache();
      await LiveApiModelsService.fetchLiveModels(
        apiKey: 'AIza-key-a',
        client: client,
      );
      await LiveApiModelsService.fetchLiveModels(
        apiKey: 'AIza-key-b',
        client: client,
      );
      // 不同 key 不得共用快取 → 兩次都打到網路
      expect(calls, 2);
      LiveApiModelsService.invalidateCache();
    });

    test('cache is scoped per baseUrl host', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response(
          jsonEncode({
            'models': [{'name': 'models/gemini-3.1-flash-live-preview'}],
          }),
          200,
        );
      });
      LiveApiModelsService.invalidateCache();
      await LiveApiModelsService.fetchLiveModels(
        apiKey: 'AIza-shared',
        client: client,
      );
      await LiveApiModelsService.fetchLiveModels(
        apiKey: 'AIza-shared',
        baseUrl: 'wss://other.example.com/ws',
        client: client,
      );
      // 不同 host 不得共用快取
      expect(calls, 2);
      LiveApiModelsService.invalidateCache();
    });

    test('same key and endpoint reuse cache (single network call)', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response(
          jsonEncode({
            'models': [{'name': 'models/gemini-3.1-flash-live-preview'}],
          }),
          200,
        );
      });
      LiveApiModelsService.invalidateCache();
      await LiveApiModelsService.fetchLiveModels(
        apiKey: 'AIza-reuse',
        baseUrl: 'wss://gw.example.com/ws',
        client: client,
      );
      await LiveApiModelsService.fetchLiveModels(
        apiKey: 'AIza-reuse',
        baseUrl: 'wss://gw.example.com/ws',
        client: client,
      );
      expect(calls, 1);
      LiveApiModelsService.invalidateCache();
    });

    test('invalidateCache clears all scoped entries', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response(
          jsonEncode({
            'models': [{'name': 'models/gemini-3.1-flash-live-preview'}],
          }),
          200,
        );
      });
      LiveApiModelsService.invalidateCache();
      await LiveApiModelsService.fetchLiveModels(
        apiKey: 'AIza-clear',
        client: client,
      );
      LiveApiModelsService.invalidateCache();
      await LiveApiModelsService.fetchLiveModels(
        apiKey: 'AIza-clear',
        client: client,
      );
      expect(calls, 2);
      LiveApiModelsService.invalidateCache();
    });

    test('http error detail does not leak the api key', () async {
      final client = MockClient((request) async => http.Response('{}', 401));
      LiveApiModelsService.invalidateCache();
      final result = await LiveApiModelsService.fetchLiveModels(
        apiKey: 'AIza-super-secret-key',
        client: client,
      );
      expect(result.error, LiveApiModelsError.http);
      expect(result.detail, isNotNull);
      expect(result.detail, isNot(contains('AIza-super-secret-key')));
      LiveApiModelsService.invalidateCache();
    });
  });
}
