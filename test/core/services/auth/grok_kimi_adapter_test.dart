// M6 adapters: RFC 8628 device-code login, refresh rotation, model sync and
// usage parsing for Grok (xAI) and Kimi Code. No network: MockClient serves
// the fixed endpoints, so the tests assert the exact form/headers they send.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/services/auth/provider_oauth_adapter.dart';

http.Response _json(Map<String, dynamic> data, {int status = 200}) =>
    http.Response(
      jsonEncode(data),
      status,
      headers: const <String, String>{'content-type': 'application/json'},
    );

Map<String, dynamic> _form(http.Request request) =>
    Uri.splitQueryString(request.body);

void main() {
  group('Grok', () {
    test('device-code login adds the userinfo identity', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/oauth2/device/code':
            return _json(<String, dynamic>{
              'device_code': 'device-1',
              'user_code': 'ABCD-EFGH',
              'verification_uri': 'https://x.ai/device',
              'expires_in': 60,
              'interval': 1,
            });
          case '/oauth2/token':
            return _json(<String, dynamic>{
              'access_token': 'grok-access',
              'refresh_token': 'grok-refresh',
              'expires_in': 3600,
              'scope': 'openid profile email',
            });
          case '/oauth2/userinfo':
            return _json(<String, dynamic>{
              'sub': 'grok-user',
              'email': 'grok@example.com',
            });
          default:
            return _json(<String, dynamic>{}, status: 404);
        }
      });

      final controller = OAuthLoginController(provider: OAuthProvider.grok);
      final credentials = await GrokOAuthAdapter().login(
        controller: controller,
        client: client,
        launchBrowser: (_) async => true,
        sessionId: 'session-1',
      );

      expect(credentials.accessToken, 'grok-access');
      expect(credentials.refreshToken, 'grok-refresh');
      expect(credentials.accountId, 'grok-user');
      expect(credentials.email, 'grok@example.com');
      expect(controller.userCode, 'ABCD-EFGH');
      expect(controller.status, 'done');

      final start = requests.firstWhere(
        (r) => r.url.path == '/oauth2/device/code',
      );
      final startForm = _form(start);
      expect(startForm['client_id'], ProviderOAuthConstants.grokClientId);
      expect(startForm['scope'], ProviderOAuthConstants.grokScope);
      final poll = requests.firstWhere((r) => r.url.path == '/oauth2/token');
      expect(
        _form(poll)['grant_type'],
        'urn:ietf:params:oauth:grant-type:device_code',
      );
      expect(_form(poll)['device_code'], 'device-1');
    });

    test('refresh sends the rotating token and keeps the fallback', () async {
      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return _json(<String, dynamic>{
          'access_token': 'new-access',
          'expires_in': 3600,
        });
      });
      final stored = ProviderOAuthCredentials(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
        sessionId: 'session-1',
        accountId: 'grok-user',
      );
      final refreshed = await GrokOAuthAdapter().refresh(
        credentials: stored,
        client: client,
      );
      expect(refreshed.accessToken, 'new-access');
      expect(refreshed.refreshToken, 'old-refresh');
      expect(refreshed.accountId, 'grok-user');
      expect(_form(seen)['grant_type'], 'refresh_token');
      expect(_form(seen)['refresh_token'], 'old-refresh');
    });

    test('model sync merges both catalogs and drops media models', () async {
      final client = MockClient((request) async {
        if (request.url.host == 'cli-chat-proxy.grok.com') {
          return _json(<String, dynamic>{
            'data': <Map<String, dynamic>>[
              <String, dynamic>{
                'model': 'grok-4',
                'display_name': 'Grok 4',
                'reasoningEfforts': <String>['low', 'high'],
              },
              <String, dynamic>{'model': 'grok-imagine'},
            ],
          });
        }
        return _json(<String, dynamic>{
          'data': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'grok-4', 'display_name': 'Grok 4 API'},
            <String, dynamic>{'id': 'grok-3'},
          ],
        });
      });
      final entries = await GrokOAuthAdapter().fetchModels(
        credentials: ProviderOAuthCredentials(
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          sessionId: 's',
        ),
        client: client,
      );
      expect(
        entries.map((e) => e.id),
        containsAll(<String>['grok-4', 'grok-3']),
      );
      expect(entries.map((e) => e.id), isNot(contains('grok-imagine')));
      expect(entries.firstWhere((e) => e.id == 'grok-4').reasoning, isTrue);
    });

    test('usage prefers the weekly credits window', () async {
      final client = MockClient((request) async {
        return _json(<String, dynamic>{
          'config': <String, dynamic>{
            'creditUsagePercent': 42,
            'currentPeriod': <String, dynamic>{
              'type': 'weekly',
              'start': '2026-10-01T00:00:00Z',
              'end': '2026-11-08T00:00:00Z',
            },
            'planName': 'SuperGrok',
            'isUnifiedBillingUser': false,
          },
        });
      });
      final usage = await GrokOAuthAdapter().fetchUsage(
        credentials: ProviderOAuthCredentials(
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          sessionId: 's',
        ),
        client: client,
      );
      expect(usage.planType, 'SuperGrok');
      expect(usage.windows.single.kind, 'weekly');
      expect(usage.windows.single.percent, 42);
    });
  });

  group('Kimi', () {
    test('device-code login carries the CLI device headers', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/api/oauth/device_authorization':
            return _json(<String, dynamic>{
              'device_code': 'kimi-device',
              'user_code': 'KIMI-CODE',
              'verification_uri': 'https://kimi.com/device',
              'expires_in': 60,
              'interval': 1,
            });
          case '/api/oauth/token':
            return _json(<String, dynamic>{
              'access_token': 'kimi-access',
              'refresh_token': 'kimi-refresh',
              'expires_in': 3600,
            });
          default:
            return _json(<String, dynamic>{}, status: 404);
        }
      });

      final controller = OAuthLoginController(provider: OAuthProvider.kimi);
      final credentials = await KimiOAuthAdapter().login(
        controller: controller,
        client: client,
        launchBrowser: (_) async => true,
        sessionId: 'session-kimi',
      );
      expect(credentials.accessToken, 'kimi-access');
      expect(credentials.deviceId, isNotNull);
      expect(credentials.deviceId!.length, 32);
      expect(controller.userCode, 'KIMI-CODE');

      final start = requests.firstWhere(
        (r) => r.url.path == '/api/oauth/device_authorization',
      );
      expect(start.headers['X-Msh-Platform'], 'kimi_cli');
      expect(start.headers['X-Msh-Device-Name'], 'OmniChat');
      expect(start.headers['X-Msh-Device-Id'], credentials.deviceId);
      final poll = requests.firstWhere((r) => r.url.path == '/api/oauth/token');
      expect(poll.headers['X-Msh-Device-Id'], credentials.deviceId);
      expect(poll.headers['Authorization'], isNull);
    });

    test(
      'model sync keeps the catalog protocol and reasoning abilities',
      () async {
        final client = MockClient((request) async {
          return _json(<String, dynamic>{
            'data': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'kimi-k2.5',
                'display_name': 'Kimi K2.5',
                'protocol': null,
                'supports_reasoning': true,
                'supports_tool_use': true,
                'supports_vision': true,
              },
              <String, dynamic>{
                'id': 'kimi-k3',
                'protocol': 'anthropic',
                'supports_thinking_type': 'only',
              },
            ],
          });
        });
        final entries = await KimiOAuthAdapter().fetchModels(
          credentials: ProviderOAuthCredentials(
            accessToken: 'a',
            refreshToken: 'r',
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
            sessionId: 's',
            deviceId: 'device',
          ),
          client: client,
        );
        final k25 = entries.firstWhere((e) => e.id == 'kimi-k2.5');
        final k3 = entries.firstWhere((e) => e.id == 'kimi-k3');
        expect(k25.protocol, 'openai');
        expect(k25.reasoning, isTrue);
        expect(k25.vision, isTrue);
        expect(k3.protocol, 'anthropic');
        expect(k3.reasoning, isTrue);
      },
    );

    test('usage maps used/limit and remaining windows', () async {
      final client = MockClient((request) async {
        return _json(<String, dynamic>{
          'usage': <String, dynamic>{'used': 25, 'limit': 100},
          'totalQuota': <String, dynamic>{'remaining': 40, 'limit': 100},
        });
      });
      final usage = await KimiOAuthAdapter().fetchUsage(
        credentials: ProviderOAuthCredentials(
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          sessionId: 's',
          deviceId: 'device',
        ),
        client: client,
      );
      expect(usage.windows, hasLength(2));
      expect(usage.windows[0].percent, 25);
      expect(usage.windows[1].percent, 60);
    });
  });
}
