// Wire-level routing tests for OAuth accounts (plan M2/C8):
//  * Codex `stream:false` callers (OCR / translation) are forced onto SSE;
//  * `include` merges with the web-search-source override on every round,
//    including the tool follow-up (`body2`);
//  * sampling params / output caps are stripped on every round;
//  * Claude OAuth drops `x-api-key`, appends `?beta=true` and turns `system`
//    into blocks.
//
// Driven through the real `sendMessageStream` + `_clientFor` + loopback server,
// so a regression in the single interception point fails here.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/services/agent/agent_loop.dart';
import 'package:OmniChat/core/services/api/learned_context_windows.dart';
import 'package:OmniChat/core/services/api/learned_max_output_caps.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';

const String _claudeIdentity =
    "You are Claude Code, Anthropic's official CLI for Claude.";

ProviderOAuthCredentials _credentials() => ProviderOAuthCredentials(
  accessToken: 'access-token',
  refreshToken: 'refresh-token',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
  sessionId: 'login-session',
  accountId: 'account-1',
  deviceId: 'device-1',
);

ProviderConfig _codexConfig(
  String baseUrl, {
  Map<String, dynamic>? overrides,
}) => ProviderConfig.oauthAccount(
  id: 'ChatGPT',
  name: 'ChatGPT',
  provider: OAuthProvider.chatgpt,
  credentials: _credentials().toJson(),
  models: const <String>['gpt-5.2'],
  modelOverrides: overrides ?? const <String, dynamic>{},
).copyWith(baseUrl: baseUrl);

ProviderConfig _claudeConfig(String baseUrl) => ProviderConfig.oauthAccount(
  id: 'Claude',
  name: 'Claude',
  provider: OAuthProvider.claude,
  credentials: _credentials().toJson(),
  models: const <String>['claude-sonnet-4-5'],
).copyWith(baseUrl: baseUrl);

ProviderConfig _grokConfig(String baseUrl) => ProviderConfig.oauthAccount(
  id: 'Grok',
  name: 'Grok',
  provider: OAuthProvider.grok,
  credentials: _credentials().toJson(),
  models: const <String>['grok-4'],
).copyWith(baseUrl: baseUrl);

ProviderConfig _kimiConfig(String baseUrl) => ProviderConfig.oauthAccount(
  id: 'Kimi',
  name: 'Kimi',
  provider: OAuthProvider.kimi,
  credentials: _credentials().toJson(),
  models: const <String>['kimi-k3'],
  modelOverrides: const <String, dynamic>{
    'kimi-k3': <String, dynamic>{'oauthProtocol': 'anthropic'},
  },
).copyWith(baseUrl: baseUrl);

String _sse(Map<String, dynamic> event) => 'data: ${jsonEncode(event)}\n\n';

String _textStream(String text) => <String>[
  _sse(<String, dynamic>{
    'type': 'response.output_item.added',
    'item': <String, dynamic>{
      'type': 'message',
      'role': 'assistant',
      'content': <dynamic>[],
    },
  }),
  _sse(<String, dynamic>{'type': 'response.output_text.delta', 'delta': text}),
  _sse(<String, dynamic>{'type': 'response.output_text.done', 'text': text}),
  _sse(<String, dynamic>{
    'type': 'response.completed',
    'response': <String, dynamic>{
      'output': <dynamic>[],
      'usage': <String, dynamic>{'input_tokens': 2, 'output_tokens': 2},
    },
  }),
  'data: [DONE]\n\n',
].join();

/// One tool round: the model asks for `lookup`, the transport executes it and
/// sends the follow-up that must keep the merged `include` list.
String _toolCallStream() => <String>[
  _sse(<String, dynamic>{
    'type': 'response.output_item.added',
    'item': <String, dynamic>{
      'type': 'function_call',
      'call_id': 'call_1',
      'name': 'lookup',
      'arguments': '',
    },
  }),
  _sse(<String, dynamic>{
    'type': 'response.function_call_arguments.delta',
    'call_id': 'call_1',
    'delta': '{"q":"test"}',
  }),
  _sse(<String, dynamic>{
    'type': 'response.function_call_arguments.done',
    'call_id': 'call_1',
    'arguments': '{"q":"test"}',
  }),
  _sse(<String, dynamic>{
    'type': 'response.output_item.done',
    'item': <String, dynamic>{
      'type': 'function_call',
      'call_id': 'call_1',
      'name': 'lookup',
      'arguments': '{"q":"test"}',
    },
  }),
  _sse(<String, dynamic>{
    'type': 'response.completed',
    'response': <String, dynamic>{
      'output': <dynamic>[
        <String, dynamic>{
          'type': 'function_call',
          'call_id': 'call_1',
          'name': 'lookup',
          'arguments': '{"q":"test"}',
        },
      ],
      'usage': <String, dynamic>{'input_tokens': 1, 'output_tokens': 1},
    },
  }),
  'data: [DONE]\n\n',
].join();

class _CapturedRequest {
  _CapturedRequest(this.uri, this.headers, this.body);

  final Uri uri;
  final Map<String, String> headers;
  final Map<String, dynamic> body;
}

class _LoopbackServer {
  _LoopbackServer._(this._server, this._payloads);

  final HttpServer _server;
  final List<String> _payloads;
  final List<_CapturedRequest> requests = <_CapturedRequest>[];
  int _served = 0;

  static Future<_LoopbackServer> start(List<String> payloads) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = _LoopbackServer._(server, payloads);
    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      final headers = <String, String>{};
      for (final name in <String>[
        'authorization',
        'x-api-key',
        'anthropic-beta',
        'chatgpt-account-id',
        'session_id',
        'x-claude-code-session-id',
        'x-msh-platform',
        'x-msh-device-name',
        'x-msh-device-id',
        'x-xai-token-auth',
        'user-agent',
      ]) {
        final value = request.headers.value(name);
        if (value != null) headers[name] = value;
      }
      result.requests.add(
        _CapturedRequest(
          request.uri,
          headers,
          raw.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(raw) as Map<String, dynamic>,
        ),
      );
      final payload =
          result._payloads[result._served < result._payloads.length
              ? result._served
              : result._payloads.length - 1];
      result._served += 1;
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = payload.startsWith('{')
          ? ContentType.json
          : ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write(payload);
      await request.response.close();
    });
    return result;
  }

  String get localBase => 'http://${_server.address.address}:${_server.port}';

  Future<void> close() => _server.close(force: true);
}

Future<String> _drain(Stream<ChatStreamChunk> stream) async {
  final buffer = StringBuffer();
  await for (final chunk in stream) {
    if (chunk.content.isNotEmpty) buffer.write(chunk.content);
  }
  return buffer.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // The test binding installs a mock HttpClient that answers every request
    // with 400. These tests deliberately drive the real transport against a
    // loopback server, so remove the override.
    HttpOverrides.global = null;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LearnedMaxOutputCaps.debugReset();
    LearnedContextWindows.debugReset();
  });

  test('Codex sendMessageStream(stream:false) is forced onto SSE', () async {
    final server = await _LoopbackServer.start(<String>[_textStream('Forged')]);
    addTearDown(server.close);

    final text = await _drain(
      ChatApiService.sendMessageStream(
        config: _codexConfig('${server.localBase}/backend-api/codex'),
        modelId: 'gpt-5.2',
        messages: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
        stream: false,
        sessionId: 'conv-1',
      ),
    );

    expect(text, 'Forged');
    expect(server.requests, hasLength(1));
    final body = server.requests.single.body;
    expect(body['stream'], isTrue);
    expect(body['store'], isFalse);
    expect(
      server.requests.single.headers['authorization'],
      'Bearer access-token',
    );
    expect(server.requests.single.headers['session_id'], 'conv-1');
  });

  test(
    'Codex tool follow-up keeps include merged and strips params (C8)',
    () async {
      final server = await _LoopbackServer.start(<String>[
        _toolCallStream(),
        _textStream('Result: ok'),
      ]);
      addTearDown(server.close);

      // P0-3: the transport is single-round; the agent-loop kernel executes
      // the tool and composes the follow-up itself.
      final textBuffer = StringBuffer();
      await for (final event in runAgentLoop(
        messages: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'search it'},
        ],
        sendRound: (msgs) async => ChatApiService.sendMessageStream(
          config: _codexConfig(
            '${server.localBase}/backend-api/codex',
            overrides: <String, dynamic>{
              'gpt-5.2': <String, dynamic>{
                'webSearch': <String, dynamic>{'include_sources': true},
              },
            },
          ),
          modelId: 'gpt-5.2',
          messages: msgs,
          temperature: 0.3,
          topP: 0.9,
          maxTokens: 500,
          sessionId: 'conv-2',
        ),
        onToolCall: (call) async => 'tool result',
      )) {
        if (event is AgentStreamEvent && event.chunk.content.isNotEmpty) {
          textBuffer.write(event.chunk.content);
        }
      }
      final text = textBuffer.toString();

      expect(text, 'Result: ok');
      expect(server.requests, hasLength(2));

      for (final request in server.requests) {
        final include = request.body['include'] as List;
        // The override's list and the OAuth list must coexist, deduplicated.
        expect(
          include.where((e) => e == 'web_search_call.action.sources'),
          hasLength(1),
        );
        expect(
          include.where((e) => e == 'reasoning.encrypted_content'),
          hasLength(1),
        );
        expect(request.body.containsKey('temperature'), isFalse);
        expect(request.body.containsKey('top_p'), isFalse);
        expect(request.body.containsKey('max_output_tokens'), isFalse);
        expect(request.headers['session_id'], 'conv-2');
      }

      final followUp = server.requests.last.body['input'] as List;
      expect(
        followUp.any(
          (item) =>
              item is Map &&
              item['type'] == 'function_call_output' &&
              item['call_id'] == 'call_1',
        ),
        isTrue,
      );
    },
  );
  test(
    'Grok uses the Responses path with CLI auth and encrypted reasoning',
    () async {
      final server = await _LoopbackServer.start(<String>[
        _textStream('Hello from Grok'),
      ]);
      addTearDown(server.close);

      final text = await _drain(
        ChatApiService.sendMessageStream(
          config: _grokConfig('${server.localBase}/v1'),
          modelId: 'grok-4',
          messages: <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
          stream: true,
          sessionId: 'conv-grok',
        ),
      );

      expect(text, 'Hello from Grok');
      expect(server.requests, hasLength(1));
      final request = server.requests.single;
      expect(request.uri.path, '/v1/responses');
      expect(request.headers['authorization'], 'Bearer access-token');
      expect(request.headers['x-xai-token-auth'], 'xai-grok-cli');
      expect(request.body['store'], isFalse);
      expect(
        (request.body['include'] as List).contains(
          'reasoning.encrypted_content',
        ),
        isTrue,
      );
    },
  );

  test(
    'Kimi resolves the Anthropic protocol to /messages and adds device auth',
    () async {
      final server = await _LoopbackServer.start(<String>[
        jsonEncode(<String, dynamic>{
          'id': 'msg_kimi',
          'type': 'message',
          'role': 'assistant',
          'content': <dynamic>[
            <String, dynamic>{'type': 'text', 'text': 'Hello from Kimi'},
          ],
          'stop_reason': 'end_turn',
          'usage': <String, dynamic>{'input_tokens': 3, 'output_tokens': 2},
        }),
      ]);
      addTearDown(server.close);

      final text = await _drain(
        ChatApiService.sendMessageStream(
          config: _kimiConfig('${server.localBase}/coding/v1'),
          modelId: 'kimi-k3',
          messages: <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
          stream: false,
          sessionId: 'conv-kimi',
        ),
      );

      expect(text, 'Hello from Kimi');
      expect(server.requests, hasLength(1));
      final request = server.requests.single;
      expect(request.uri.path, '/coding/v1/messages');
      expect(request.headers['authorization'], 'Bearer access-token');
      expect(request.headers['x-api-key'], 'access-token');
      expect(request.headers['x-msh-platform'], 'kimi_cli');
      expect(request.headers['x-msh-device-id'], 'device-1');
    },
  );

  test('Claude OAuth uses beta URL, bearer auth and system blocks', () async {
    final server = await _LoopbackServer.start(<String>[
      jsonEncode(<String, dynamic>{
        'id': 'msg_1',
        'type': 'message',
        'role': 'assistant',
        'content': <dynamic>[
          <String, dynamic>{'type': 'text', 'text': 'Hello from Claude'},
        ],
        'stop_reason': 'end_turn',
        'usage': <String, dynamic>{'input_tokens': 3, 'output_tokens': 2},
      }),
    ]);
    addTearDown(server.close);

    final text = await _drain(
      ChatApiService.sendMessageStream(
        config: _claudeConfig('${server.localBase}/v1'),
        modelId: 'claude-sonnet-4-5',
        messages: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': 'OmniChat system'},
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
        stream: false,
        sessionId: 'conv-claude',
      ),
    );

    expect(text, 'Hello from Claude');
    expect(server.requests, hasLength(1));
    final request = server.requests.single;
    expect(request.uri.path, '/v1/messages');
    expect(request.uri.queryParameters['beta'], 'true');
    expect(request.headers['authorization'], 'Bearer access-token');
    expect(request.headers.containsKey('x-api-key'), isFalse);
    expect(request.headers['anthropic-beta'], contains('oauth-2025-04-20'));
    expect(request.headers['x-claude-code-session-id'], 'conv-claude');

    final body = request.body;
    expect(body['system'], isA<List>());
    expect(jsonEncode(body['system']), contains(_claudeIdentity));
    expect(body.containsKey('cache_control'), isFalse);
    final maxTokens = body['max_tokens'] as int;
    expect(maxTokens, greaterThan(0));
    expect(maxTokens, lessThanOrEqualTo(64000));

    final metadata = body['metadata'] as Map<String, dynamic>;
    final userId = jsonDecode(metadata['user_id'] as String) as Map;
    expect(userId['device_id'], 'device-1');
    expect(userId['session_id'], 'conv-claude');
    expect(userId['account_uuid'], 'account-1');
  });
}
