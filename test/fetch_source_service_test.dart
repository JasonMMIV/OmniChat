import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/search/search_dispatch.dart';
import 'package:OmniChat/core/services/search/search_service.dart';
import 'package:OmniChat/core/services/web/fetch_core.dart';
import 'package:OmniChat/core/services/web/fetch_source_service.dart';
import 'package:OmniChat/core/services/web/provider_adapters.dart';
import 'package:OmniChat/core/services/web/ssrf_guard.dart';

Future<SettingsProvider> _settings({
  required List<SearchServiceOptions> services,
  required List<String> selected,
  required String source,
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
  await sp.setSearchServices(services);
  await sp.setSearchSelectedProviders(selected);
  await sp.setWebFetchSource(source);
  return sp;
}

FetchCore _localCore() => FetchCore(
  client: MockClient(
    (request) async => http.Response(
      'local content',
      200,
      headers: {'content-type': 'text/plain'},
    ),
  ),
  guard: SsrfGuard(
    lookup: (host) async => <InternetAddress>[
      InternetAddress('93.184.216.34'),
    ],
  ),
  sleep: (_) async {},
);

void main() {
  group('siblingFetchEndpoint', () {
    test('derives the fetch endpoint from a search endpoint', () {
      expect(
        siblingFetchEndpoint(
          'https://api.firecrawl.dev/v2/search',
          '/search',
          '/scrape',
        ).toString(),
        'https://api.firecrawl.dev/v2/scrape',
      );
    });

    test('returns null when the gateway shape is unexpected', () {
      expect(
        siblingFetchEndpoint(
          'https://gateway.example/custom/search/v1',
          '/search',
          '/scrape',
        ),
        isNull,
      );
      expect(
        siblingFetchEndpoint('not a url', '/search', '/scrape'),
        isNull,
      );
    });
  });

  group('resolve', () {
    test('follow picks the first selected provider with an adapter', () async {
      final settings = await _settings(
        services: <SearchServiceOptions>[
          BraveOptions(id: 'brave-1', apiKey: 'k'),
          TavilyOptions(id: 'tavily-1', apiKey: 'k'),
          ExaOptions(id: 'exa-1', apiKey: 'k'),
        ],
        selected: <String>['brave-1', 'tavily-1', 'exa-1'],
        source: 'follow',
      );
      final resolved = FetchSourceService().resolve(settings);
      expect(resolved.source, 'tavily');
      expect(resolved.displayName, 'Tavily');
    });

    test('explicit provider id resolves to its adapter', () async {
      final settings = await _settings(
        services: <SearchServiceOptions>[
          TavilyOptions(id: 'tavily-1', apiKey: 'k'),
          ExaOptions(id: 'exa-1', apiKey: 'k'),
        ],
        selected: <String>['tavily-1', 'exa-1'],
        source: 'exa-1',
      );
      expect(FetchSourceService().resolve(settings).source, 'exa');
    });

    test('missing or unsupported providers fall back to local', () async {
      final settings = await _settings(
        services: <SearchServiceOptions>[
          BraveOptions(id: 'brave-1', apiKey: 'k'),
        ],
        selected: <String>['brave-1'],
        source: 'follow',
      );
      expect(FetchSourceService().resolve(settings).isLocal, isTrue);

      await settings.setWebFetchSource('deleted-id');
      expect(FetchSourceService().resolve(settings).isLocal, isTrue);
    });
  });

  group('fetch', () {
    test('provider success is reported with its display name', () async {
      final settings = await _settings(
        services: <SearchServiceOptions>[
          TavilyOptions(id: 'tavily-1', apiKey: 'tvly'),
        ],
        selected: <String>['tavily-1'],
        source: 'tavily-1',
      );
      final service = FetchSourceService(
        client: MockClient((request) async {
          expect(request.url.toString(), 'https://api.tavily.com/extract');
          expect(request.headers['Authorization'], 'Bearer tvly');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['urls'], <String>['https://example.com/a']);
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'raw_content': 'provider content',
                  'title': 'Provider page',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final outcome = await service.fetch(
        request: FetchRequest(url: Uri.parse('https://example.com/a')),
        settings: settings,
        localCore: _localCore(),
      );
      expect(outcome.source, 'tavily');
      expect(outcome.sourceName, 'Tavily');
      expect(outcome.result.content, 'provider content');
      expect(outcome.result.metadata.title, 'Provider page');
      expect(outcome.escalated, isFalse);
    });

    test('provider failure falls back to local and reports the error', () async {
      final settings = await _settings(
        services: <SearchServiceOptions>[
          TavilyOptions(id: 'tavily-1', apiKey: 'tvly'),
        ],
        selected: <String>['tavily-1'],
        source: 'tavily-1',
      );
      final service = FetchSourceService(
        client: MockClient(
          (request) async => http.Response('nope', 500),
        ),
      );
      final outcome = await service.fetch(
        request: FetchRequest(url: Uri.parse('https://example.com/a')),
        settings: settings,
        localCore: _localCore(),
      );
      expect(outcome.source, 'local');
      expect(outcome.escalated, isTrue);
      expect(outcome.escalationError, contains('500'));
      expect(outcome.result.content, 'local content');
    });

    test('429 starts a cooldown and the next fetch skips the provider', () async {
      final settings = await _settings(
        services: <SearchServiceOptions>[
          TavilyOptions(id: 'tavily-1', apiKey: 'tvly'),
        ],
        selected: <String>['tavily-1'],
        source: 'tavily-1',
      );
      var providerCalls = 0;
      final cooldown = ProviderCooldown(
        duration: const Duration(seconds: 60),
      );
      final service = FetchSourceService(
        client: MockClient((request) async {
          providerCalls++;
          return http.Response('slow down', 429);
        }),
        cooldown: cooldown,
      );

      final first = await service.fetch(
        request: FetchRequest(url: Uri.parse('https://example.com/a')),
        settings: settings,
        localCore: _localCore(),
      );
      expect(first.source, 'local');
      expect(cooldown.isCoolingDown('tavily'), isTrue);

      final second = await service.fetch(
        request: FetchRequest(url: Uri.parse('https://example.com/a')),
        settings: settings,
        localCore: _localCore(),
      );
      expect(second.source, 'local');
      expect(providerCalls, 1);
    });

    test('allowEscalation=false always stays local', () async {
      final settings = await _settings(
        services: <SearchServiceOptions>[
          TavilyOptions(id: 'tavily-1', apiKey: 'tvly'),
        ],
        selected: <String>['tavily-1'],
        source: 'tavily-1',
      );
      final service = FetchSourceService(
        client: MockClient(
          (request) async => fail('provider must not be called'),
        ),
      );
      final outcome = await service.fetch(
        request: FetchRequest(
          url: Uri.parse('https://example.com/a'),
          raw: true,
        ),
        settings: settings,
        localCore: _localCore(),
        allowEscalation: false,
      );
      expect(outcome.source, 'local');
      expect(outcome.result.content, 'local content');
    });
  });
}
