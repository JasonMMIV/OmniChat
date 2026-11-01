// The single interception point (plan C1/C3/C4/C7/C8): request cloning,
// header/body shaping for both providers, one 401 refresh-and-retry, login-
// required marking, close() forwarding and pass-through for non-OAuth configs.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/auth/oauth_errors.dart';
import 'package:OmniChat/core/services/auth/oauth_http_client.dart';
import 'package:OmniChat/core/services/auth/provider_oauth_service.dart';

class _FakeService extends ProviderOAuthService {
  _FakeService() : super.testing();

  ProviderOAuthCredentials credentials = ProviderOAuthCredentials(
    accessToken: 'old-token',
    refreshToken: 'refresh-token',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    sessionId: 'login-session',
    accountId: 'acct_1',
    deviceId: 'device-1',
    extra: const <String, dynamic>{'residency': 'us', 'routingHint': 'hint'},
  );

  int refreshCalls = 0;
  bool markedLoginRequired = false;
  Object? refreshError;

  @override
  Future<OAuthAccessToken> resolve(
    ProviderConfig config, {
    bool forceRefresh = false,
  }) async => OAuthAccessToken(
    token: credentials.accessToken,
    sessionId: credentials.sessionId,
    credentials: credentials,
  );

  @override
  Future<OAuthAccessToken> forceRefresh(
    ProviderConfig config, {
    required String sessionId,
  }) async {
    refreshCalls += 1;
    final error = refreshError;
    if (error != null) throw error;
    credentials = credentials.copyWith(accessToken: 'new-token');
    return OAuthAccessToken(
      token: credentials.accessToken,
      sessionId: credentials.sessionId,
      credentials: credentials,
    );
  }

  @override
  void markLoginRequired(String providerId) {
    markedLoginRequired = true;
  }
}

ProviderConfig _claudeConfig(ProviderOAuthCredentials creds) =>
    ProviderConfig.oauthAccount(
      id: 'Claude',
      name: 'Claude',
      provider: OAuthProvider.claude,
      credentials: creds.toJson(),
    );

ProviderConfig _codexConfig(ProviderOAuthCredentials creds) =>
    ProviderConfig.oauthAccount(
      id: 'ChatGPT',
      name: 'ChatGPT',
      provider: OAuthProvider.chatgpt,
      credentials: creds.toJson(),
    );

void main() {
  tearDown(OAuthHttpClient.resetRuntimeCliVersion);

  test('Claude requests get bearer auth, beta URL and system blocks', () async {
    final service = _FakeService();
    http.Request? seen;
    final inner = MockClient((request) async {
      seen = request;
      return http.Response('ok', 200);
    });
    final client = OAuthHttpClient(
      inner: inner,
      config: _claudeConfig(service.credentials),
      service: service,
      sessionId: 'conv-1',
    );

    final request =
        http.Request('POST', Uri.parse('https://api.anthropic.com/v1/messages'))
          ..headers.addAll(<String, String>{
            'x-api-key': 'should-be-removed',
            'anthropic-beta': 'my-feature-2026',
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
          })
          ..body = jsonEncode(<String, dynamic>{
            'model': 'claude-sonnet-4-5',
            'max_tokens': 999999,
            'system': 'OmniChat system',
            'cache_control': <String, dynamic>{'type': 'ephemeral'},
            'messages': <Map<String, dynamic>>[
              <String, dynamic>{'role': 'user', 'content': 'hi'},
            ],
            'tools': <Map<String, dynamic>>[
              <String, dynamic>{'name': 'file_read'},
            ],
          });

    final response = await client.send(request);
    expect(response.statusCode, 200);
    expect(seen, isNotNull);
    expect(seen!.url.queryParameters['beta'], 'true');
    expect(seen!.headers.containsKey('x-api-key'), isFalse);
    expect(seen!.headers['authorization'], 'Bearer old-token');
    expect(seen!.headers['anthropic-beta'], contains('oauth-2025-04-20'));
    expect(seen!.headers['anthropic-beta'], contains('my-feature-2026'));
    expect(
      seen!.headers['anthropic-beta'],
      contains('extended-cache-ttl-2025-04-11'),
    );
    expect(seen!.headers['x-claude-code-session-id'], 'conv-1');

    final body = jsonDecode(seen!.body) as Map<String, dynamic>;
    expect(body['max_tokens'], ProviderOAuthConstants.claudeMaxTokensCap);
    expect(body.containsKey('cache_control'), isFalse);
    expect(body['system'], isA<List>());
    expect(jsonEncode(body['system']).contains(claudeCodeIdentityText), isTrue);
    expect((body['tools'] as List).first['name'], '_file_read');
    expect(
      jsonDecode((body['metadata'] as Map)['user_id'] as String)['device_id'],
      'device-1',
    );
  });

  test('Codex requests get subscription shape and session headers', () async {
    final service = _FakeService();
    http.Request? seen;
    final inner = MockClient((request) async {
      seen = request;
      return http.Response('ok', 200);
    });
    final client = OAuthHttpClient(
      inner: inner,
      config: _codexConfig(service.credentials),
      service: service,
      sessionId: 'conv-2',
    );

    await client.send(
      http.Request(
          'POST',
          Uri.parse('https://chatgpt.com/backend-api/codex/responses'),
        )
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(<String, dynamic>{
          'model': 'gpt-5.2',
          'input': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
          'stream': false,
          'temperature': 0.3,
          'include': <String>['web_search_call.action.sources'],
        }),
    );

    expect(seen, isNotNull);
    expect(seen!.headers['chatgpt-account-id'], 'acct_1');
    expect(seen!.headers['session_id'], 'conv-2');
    expect(seen!.headers['originator'], ProviderOAuthConstants.codexOriginator);
    final body = jsonDecode(seen!.body) as Map<String, dynamic>;
    expect(body['store'], isFalse);
    expect(body['stream'], isTrue);
    expect(body.containsKey('temperature'), isFalse);
    expect(body['include'], contains('reasoning.encrypted_content'));
    expect(body['include'], contains('web_search_call.action.sources'));
  });

  test('401 triggers one refresh and retries with the new token', () async {
    final service = _FakeService();
    final authSeen = <String?>[];
    var calls = 0;
    final inner = MockClient((request) async {
      calls += 1;
      authSeen.add(request.headers['authorization']);
      if (calls == 1) return http.Response('unauthorized', 401);
      return http.Response('ok', 200);
    });
    final client = OAuthHttpClient(
      inner: inner,
      config: _claudeConfig(service.credentials),
      service: service,
    );

    final response = await client.send(
      http.Request('POST', Uri.parse('https://api.anthropic.com/v1/messages'))
        ..body = jsonEncode(<String, dynamic>{
          'max_tokens': 100,
          'messages': <dynamic>[],
        }),
    );

    expect(response.statusCode, 200);
    expect(calls, 2);
    expect(service.refreshCalls, 1);
    expect(authSeen.first, 'Bearer old-token');
    expect(authSeen.last, 'Bearer new-token');
    expect(service.markedLoginRequired, isFalse);
  });

  test(
    'a transient refresh failure must not mark login-required (C16)',
    () async {
      final service = _FakeService()
        ..refreshError = OAuthTransportException('network down');
      final inner = MockClient(
        (request) async => http.Response('unauthorized', 401),
      );
      final client = OAuthHttpClient(
        inner: inner,
        config: _claudeConfig(service.credentials),
        service: service,
      );

      await expectLater(
        client.send(
          http.Request(
              'POST',
              Uri.parse('https://api.anthropic.com/v1/messages'),
            )
            ..body = jsonEncode(<String, dynamic>{
              'max_tokens': 100,
              'messages': <dynamic>[],
            }),
        ),
        throwsA(isA<OAuthTransportException>()),
      );
      expect(service.refreshCalls, 1);
      expect(service.markedLoginRequired, isFalse);
    },
  );

  test('a superseded session does not mark the new account (C3)', () async {
    final service = _FakeService()
      ..refreshError = OAuthSessionSupersededException(
        provider: OAuthProvider.claude,
      );
    final inner = MockClient(
      (request) async => http.Response('unauthorized', 401),
    );
    final client = OAuthHttpClient(
      inner: inner,
      config: _claudeConfig(service.credentials),
      service: service,
    );

    await expectLater(
      client.send(
        http.Request('POST', Uri.parse('https://api.anthropic.com/v1/messages'))
          ..body = jsonEncode(<String, dynamic>{
            'max_tokens': 100,
            'messages': <dynamic>[],
          }),
      ),
      throwsA(isA<OAuthSessionSupersededException>()),
    );
    expect(service.markedLoginRequired, isFalse);
  });

  test('a second 401 marks the account as requiring sign-in', () async {
    final service = _FakeService();
    var calls = 0;
    final inner = MockClient((request) async {
      calls += 1;
      return http.Response('unauthorized', 401);
    });
    final client = OAuthHttpClient(
      inner: inner,
      config: _claudeConfig(service.credentials),
      service: service,
    );

    final response = await client.send(
      http.Request('POST', Uri.parse('https://api.anthropic.com/v1/messages'))
        ..body = jsonEncode(<String, dynamic>{
          'max_tokens': 100,
          'messages': <dynamic>[],
        }),
    );

    expect(response.statusCode, 401);
    expect(calls, 2);
    expect(service.refreshCalls, 1);
    expect(service.markedLoginRequired, isTrue);
  });

  test(
    'claude_code_version_too_old retries once with the stated version',
    () async {
      final service = _FakeService();
      final userAgents = <String?>[];
      var calls = 0;
      final inner = MockClient((request) async {
        calls += 1;
        userAgents.add(request.headers['user-agent']);
        if (calls == 1) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'type': 'error',
              'error': <String, dynamic>{
                'message':
                    'claude_code_version_too_old: please upgrade to '
                    'version 2.1.300 or newer',
              },
            }),
            400,
          );
        }
        return http.Response('ok', 200);
      });
      final client = OAuthHttpClient(
        inner: inner,
        config: _claudeConfig(service.credentials),
        service: service,
      );
      final response = await client.send(
        http.Request('POST', Uri.parse('https://api.anthropic.com/v1/messages'))
          ..body = jsonEncode(<String, dynamic>{
            'max_tokens': 100,
            'messages': <dynamic>[],
          }),
      );
      expect(response.statusCode, 200);
      expect(calls, 2);
      expect(userAgents.first, contains('2.1.280'));
      expect(userAgents.last, contains('2.1.300'));
    },
  );

  test('an unrelated 400 body is replayed to the caller untouched', () async {
    final service = _FakeService();
    const errorBody = '{"error":{"message":"max_tokens is required"}}';
    final inner = MockClient((request) async => http.Response(errorBody, 400));
    final client = OAuthHttpClient(
      inner: inner,
      config: _claudeConfig(service.credentials),
      service: service,
    );
    final response = await client.send(
      http.Request('POST', Uri.parse('https://api.anthropic.com/v1/messages'))
        ..body = jsonEncode(<String, dynamic>{
          'max_tokens': 100,
          'messages': <dynamic>[],
        }),
    );
    expect(response.statusCode, 400);
    expect(await response.stream.bytesToString(), errorBody);
  });

  test('close() is forwarded to the inner client', () {
    final service = _FakeService();
    final inner = _TrackingClient();
    final client = OAuthHttpClient(
      inner: inner,
      config: _claudeConfig(service.credentials),
      service: service,
    );
    client.close();
    expect(inner.closed, isTrue);
  });

  test('non-OAuth configs pass the request through untouched', () async {
    final service = _FakeService();
    http.Request? seen;
    final inner = MockClient((request) async {
      seen = request;
      return http.Response('ok', 200);
    });
    final client = OAuthHttpClient(
      inner: inner,
      config: ProviderConfig(
        id: 'OpenAI',
        enabled: true,
        name: 'OpenAI',
        apiKey: 'sk-test',
        baseUrl: 'https://api.openai.com/v1',
      ),
      service: service,
    );
    await client.send(
      http.Request(
          'POST',
          Uri.parse('https://api.openai.com/v1/chat/completions'),
        )
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(<String, dynamic>{'a': 1}),
    );
    expect(seen!.headers['authorization'], isNull);
    expect(jsonDecode(seen!.body), <String, dynamic>{'a': 1});
  });
}

class _TrackingClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(const Stream<List<int>>.empty(), 200);

  @override
  void close() {
    closed = true;
  }
}

const String claudeCodeIdentityText =
    "You are Claude Code, Anthropic's official CLI for Claude.";
