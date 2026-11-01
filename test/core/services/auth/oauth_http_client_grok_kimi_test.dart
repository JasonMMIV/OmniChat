// M6 wire contracts: Grok gets the CLI token header and encrypted reasoning
// replay; Kimi gets device identity headers, plus x-api-key and a clamped
// thinking budget on the Anthropic Messages surface.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/auth/oauth_http_client.dart';
import 'package:OmniChat/core/services/auth/provider_oauth_service.dart';

class _FakeService extends ProviderOAuthService {
  _FakeService() : super.testing();

  final credentials = ProviderOAuthCredentials(
    accessToken: 'oauth-token',
    refreshToken: 'refresh-token',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    sessionId: 'session-1',
    deviceId: 'device-1',
  );

  @override
  Future<OAuthAccessToken> resolve(
    ProviderConfig config, {
    bool forceRefresh = false,
  }) async => OAuthAccessToken(
    token: credentials.accessToken,
    sessionId: credentials.sessionId,
    credentials: credentials,
  );
}

ProviderConfig _config(OAuthProvider provider) => ProviderConfig.oauthAccount(
  id: provider.displayName,
  name: provider.displayName,
  provider: provider,
);

void main() {
  test('Grok adds xAI headers and encrypted reasoning replay', () async {
    http.Request? seen;
    final inner = MockClient((request) async {
      seen = request;
      return http.Response('{}', 200);
    });
    final client = OAuthHttpClient(
      inner: inner,
      config: _config(OAuthProvider.grok),
      service: _FakeService(),
    );

    await client.post(
      Uri.parse('https://api.x.ai/v1/responses'),
      headers: <String, String>{'x-api-key': 'must-be-removed'},
      body: jsonEncode(<String, dynamic>{
        'model': 'grok-4',
        'stream': true,
        'store': true,
        'reasoning': <String, dynamic>{'effort': 'high', 'summary': 'auto'},
        'include': <String>['web_search_call.action.sources'],
      }),
    );

    expect(seen, isNotNull);
    expect(seen!.headers['Authorization'], 'Bearer oauth-token');
    expect(seen!.headers['X-XAI-Token-Auth'], 'xai-grok-cli');
    expect(seen!.headers.containsKey('x-api-key'), isFalse);
    final body = jsonDecode(seen!.body) as Map<String, dynamic>;
    expect(body['store'], isFalse);
    expect(body['reasoning'], <String, dynamic>{'effort': 'high'});
    expect((body['include'] as List).toSet(), <String>{
      'web_search_call.action.sources',
      'reasoning.encrypted_content',
    });
  });

  test('Kimi OpenAI-protocol requests carry only device headers', () async {
    http.Request? seen;
    final inner = MockClient((request) async {
      seen = request;
      return http.Response('{}', 200);
    });
    final client = OAuthHttpClient(
      inner: inner,
      config: _config(OAuthProvider.kimi),
      service: _FakeService(),
    );

    await client.post(
      Uri.parse('https://api.kimi.com/coding/v1/chat/completions'),
      body: jsonEncode(<String, dynamic>{'model': 'kimi-k2.5'}),
    );

    expect(seen!.headers['Authorization'], 'Bearer oauth-token');
    expect(seen!.headers['X-Msh-Platform'], 'kimi_cli');
    expect(seen!.headers['X-Msh-Device-Name'], 'OmniChat');
    expect(seen!.headers['X-Msh-Device-Id'], 'device-1');
    expect(seen!.headers.containsKey('x-api-key'), isFalse);
  });

  test(
    'Kimi Anthropic-protocol requests add x-api-key and clamp thinking',
    () async {
      http.Request? seen;
      final inner = MockClient((request) async {
        seen = request;
        return http.Response('{}', 200);
      });
      final client = OAuthHttpClient(
        inner: inner,
        config: _config(OAuthProvider.kimi),
        service: _FakeService(),
      );

      await client.post(
        Uri.parse('https://api.kimi.com/coding/v1/messages'),
        body: jsonEncode(<String, dynamic>{
          'model': 'kimi-k3',
          'max_tokens': 1000,
          'thinking': <String, dynamic>{
            'type': 'enabled',
            'budget_tokens': 1000,
          },
        }),
      );

      expect(seen!.headers['x-api-key'], 'oauth-token');
      final body = jsonDecode(seen!.body) as Map<String, dynamic>;
      expect((body['thinking'] as Map<String, dynamic>)['budget_tokens'], 999);
    },
  );
}
