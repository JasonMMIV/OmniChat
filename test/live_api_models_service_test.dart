import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:OmniChat/core/services/live/live_api_models_service.dart';

void main() {
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
  });
}
