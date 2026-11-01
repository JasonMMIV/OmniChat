// The Codex fork of `generateText` (plan C1/C8): the subscription endpoint has
// no non-streaming parse path, so utility calls (title / summary / compression
// / greeting) must go through `sendMessageStream` and aggregate. This test
// drives the real transport + OAuth wrapper against a loopback server so it
// pins the whole chain, not just the shaping helpers.
//
// It also pins C15: the fallback session id is stable across calls.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/services/api/learned_context_windows.dart';
import 'package:OmniChat/core/services/api/learned_max_output_caps.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';

ProviderOAuthCredentials _credentials() => ProviderOAuthCredentials(
  accessToken: 'access-token',
  refreshToken: 'refresh-token',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
  sessionId: 'login-session',
  accountId: 'account-1',
  deviceId: 'device-1',
);

ProviderConfig _config(String baseUrl) => ProviderConfig.oauthAccount(
  id: 'ChatGPT',
  name: 'ChatGPT',
  provider: OAuthProvider.chatgpt,
  credentials: _credentials().toJson(),
  models: const <String>['gpt-5.2'],
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
      'usage': <String, dynamic>{'input_tokens': 3, 'output_tokens': 2},
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

class _CodexServer {
  _CodexServer._(this._server, this._payloads);

  final HttpServer _server;
  final List<String> _payloads;
  final List<_CapturedRequest> requests = <_CapturedRequest>[];
  int _served = 0;

  static Future<_CodexServer> start(List<String> payloads) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = _CodexServer._(server, payloads);
    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      result.requests.add(
        _CapturedRequest(request.uri, <String, String>{
          for (final name in <String>[
            'authorization',
            'chatgpt-account-id',
            'originator',
            'session_id',
            'conversation_id',
          ])
            if (request.headers.value(name) != null)
              name: request.headers.value(name)!,
        }, jsonDecode(raw) as Map<String, dynamic>),
      );
      final payload =
          result._payloads[result._served < result._payloads.length
              ? result._served
              : result._payloads.length - 1];
      result._served += 1;
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(payload);
      await request.response.close();
    });
    return result;
  }

  String get baseUrl =>
      'http://${_server.address.address}:${_server.port}/backend-api/codex';

  Future<void> close() => _server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // The test binding installs a mock HttpClient that answers every request
    // with 400. This test drives the real transport against a loopback server.
    HttpOverrides.global = null;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LearnedMaxOutputCaps.debugReset();
    LearnedContextWindows.debugReset();
  });

  test(
    'generateText on a Codex account routes through the streaming fork',
    () async {
      final server = await _CodexServer.start(<String>[_textStream('Hello')]);
      addTearDown(server.close);

      final text = await ChatApiService.generateText(
        config: _config(server.baseUrl),
        modelId: 'gpt-5.2',
        prompt: 'Summarize this conversation',
        thinkingBudget: 0,
      );

      expect(text, 'Hello');
      expect(server.requests, hasLength(1));
      final request = server.requests.single;

      // The fork always hits the Responses endpoint, never chat/completions.
      expect(request.uri.path, endsWith('/responses'));
      expect(request.body['model'], 'gpt-5.2');
      expect(request.body['stream'], isTrue);
      expect(request.body['store'], isFalse);

      // Single-round utility call: no tool loop may be entered.
      expect(request.body.containsKey('tools'), isFalse);
      expect(request.body['tool_choice'], isNull);

      // Codex shaping is applied by the wrapper on the way out.
      expect(request.body['include'], contains('reasoning.encrypted_content'));
      expect(request.body.containsKey('temperature'), isFalse);
      expect(request.body.containsKey('top_p'), isFalse);
      expect(request.body.containsKey('max_output_tokens'), isFalse);

      final input = request.body['input'] as List;
      expect(input, hasLength(1));
      expect((input.single as Map)['role'], 'user');
      expect(
        jsonEncode((input.single as Map)['content']),
        contains('Summarize this conversation'),
      );

      // Header contract: bearer auth, account id, originator and a session id.
      expect(request.headers['authorization'], 'Bearer access-token');
      expect(request.headers['chatgpt-account-id'], 'account-1');
      expect(
        request.headers['originator'],
        ProviderOAuthConstants.codexOriginator,
      );
      expect(request.headers['session_id'], isNotEmpty);
      expect(request.headers['conversation_id'], isNotEmpty);
    },
  );

  test(
    'the fallback utility session id is stable across calls (C15)',
    () async {
      final server = await _CodexServer.start(<String>[
        _textStream('One'),
        _textStream('Two'),
      ]);
      addTearDown(server.close);
      final config = _config(server.baseUrl);

      final first = await ChatApiService.generateText(
        config: config,
        modelId: 'gpt-5.2',
        prompt: 'first',
      );
      final second = await ChatApiService.generateText(
        config: config,
        modelId: 'gpt-5.2',
        prompt: 'second',
      );

      expect(first, 'One');
      expect(second, 'Two');
      expect(server.requests, hasLength(2));
      final session = server.requests.first.headers['session_id'];
      expect(session, isNotEmpty);
      expect(server.requests.last.headers['session_id'], session);
      // A random per-request id would break provider attribution and the prompt
      // cache prefix.
      expect(
        server.requests.first.headers['session_id'],
        isNot('login-session'),
      );
    },
  );
}
