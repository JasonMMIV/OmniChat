// Wire-level tests for the Claude max_tokens negotiation inside
// `ChatApiService._sendClaudeStream`, driven through the
// `debugSendClaudeStream` seam with an injected `http.Client`.
//
// The pure decision table lives in test/claude_max_tokens_test.dart; this
// file pins the wiring: 400 → retry with the negotiated value, remembered
// ceilings, the prompt-too-long window, the pinned customBody bypass, and
// the thinking-budget clamp on the retried request.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:OmniChat/core/services/api/claude_max_tokens.dart';
import 'package:OmniChat/core/services/api/learned_context_windows.dart';
import 'package:OmniChat/core/services/api/learned_max_output_caps.dart';
import 'package:OmniChat/core/utils/reasoning_capabilities.dart';

const String _okBody =
    '{"id":"msg_test","type":"message","role":"assistant",'
    '"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn",'
    '"usage":{"input_tokens":1,"output_tokens":1}}';

const String _ceiling64000 =
    '{"type":"error","error":{"type":"invalid_request_error","message":'
    '"max_tokens: 64001 > 64000, which is the maximum allowed number of '
    'output tokens for claude-sonnet-4-5"}}';

const String _ceiling12800 =
    '{"type":"error","error":{"type":"invalid_request_error","message":'
    '"max_tokens: 12801 > 12800, which is the maximum allowed number of '
    'output tokens for claude-sonnet-4-5"}}';

const String _promptTooLong =
    '{"type":"error","error":{"type":"invalid_request_error","message":'
    '"prompt is too long: 180000 tokens > 200000 maximum"}}';

ProviderConfig _config({Map<String, dynamic>? modelOverrides}) => ProviderConfig(
  id: 'p',
  enabled: true,
  name: 'Claude',
  apiKey: 'test-key',
  baseUrl: 'https://api.anthropic.com',
  providerType: ProviderKind.claude,
  modelOverrides: modelOverrides ?? const <String, dynamic>{},
);

List<Map<String, dynamic>> _messages() => <Map<String, dynamic>>[
  <String, dynamic>{'role': 'user', 'content': 'hello'},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LearnedMaxOutputCaps.debugReset();
    LearnedContextWindows.debugReset();
  });

  test('adopts a stated ceiling, retries once, and remembers it', () async {
    final requests = <Map<String, dynamic>>[];
    var calls = 0;
    final client = MockClient((request) async {
      requests.add(jsonDecode(request.body) as Map<String, dynamic>);
      calls += 1;
      if (calls == 1) return http.Response(_ceiling64000, 400);
      return http.Response(_okBody, 200);
    });

    await ChatApiService.debugSendClaudeStream(
      client: client,
      config: _config(),
      modelId: 'claude-sonnet-4-5',
      messages: _messages(),
    ).toList();

    expect(requests, hasLength(2));
    expect(requests.first['max_tokens'], claudeMaxTokensInitial);
    expect(requests.last['max_tokens'], 64000);
    expect(
      await LearnedMaxOutputCaps.lookup('p', 'claude-sonnet-4-5'),
      64000,
      reason: 'the stated ceiling is device knowledge, not a request detail',
    );
  });

  test(
    'prompt-too-long retries with the leftover room and records the window',
    () async {
      final requests = <Map<String, dynamic>>[];
      var calls = 0;
      final client = MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        calls += 1;
        if (calls == 1) return http.Response(_promptTooLong, 400);
        return http.Response(_okBody, 200);
      });

      await ChatApiService.debugSendClaudeStream(
        client: client,
        config: _config(),
        modelId: 'claude-sonnet-4-5',
        messages: _messages(),
      ).toList();

      expect(requests, hasLength(2));
      expect(requests.first['max_tokens'], claudeMaxTokensInitial);
      expect(requests.last['max_tokens'], 20000);
      expect(
        await LearnedContextWindows.lookup('p', 'claude-sonnet-4-5'),
        200000,
        reason: 'the window is a model fact and is safe to remember',
      );
      expect(
        await LearnedMaxOutputCaps.lookup('p', 'claude-sonnet-4-5'),
        isNull,
        reason: 'per-request slack is not an output ceiling',
      );
    },
  );

  test(
    'a customBody max_tokens pins the value and disables negotiation',
    () async {
      final requests = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(_ceiling64000, 400);
      });

      await expectLater(
        ChatApiService.debugSendClaudeStream(
          client: client,
          config: _config(
            modelOverrides: <String, dynamic>{
              'claude-sonnet-4-5': <String, dynamic>{
                'body': <Map<String, String>>[
                  <String, String>{'key': 'max_tokens', 'value': '4096'},
                ],
              },
            },
          ),
          modelId: 'claude-sonnet-4-5',
          messages: _messages(),
        ).toList(),
        throwsA(isA<HttpException>()),
      );

      expect(requests, hasLength(1));
      expect(requests.single['max_tokens'], 4096);
    },
  );

  test(
    'a negotiated ceiling shrinks the thinking budget below max_tokens',
    () async {
      final requests = <Map<String, dynamic>>[];
      var calls = 0;
      final client = MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        calls += 1;
        if (calls == 1) return http.Response(_ceiling12800, 400);
        return http.Response(_okBody, 200);
      });

      await ChatApiService.debugSendClaudeStream(
        client: client,
        config: _config(),
        modelId: 'claude-sonnet-4-5',
        messages: _messages(),
        thinkingBudget: ReasoningBudget.heavy,
      ).toList();

      expect(requests, hasLength(2));
      expect(requests.first['max_tokens'], claudeMaxTokensInitial);
      expect(requests.first['thinking'], <String, dynamic>{
        'type': 'enabled',
        'budget_tokens': ReasoningBudget.heavy,
      });
      expect(requests.last['max_tokens'], 12800);
      final retriedThinking =
          requests.last['thinking'] as Map<String, dynamic>;
      expect(retriedThinking['budget_tokens'], 12799);
    },
  );

  test('an unrelated 400 surfaces unchanged', () async {
    final requests = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      requests.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response('{"message":"model: not_found"}', 400);
    });

    await expectLater(
      ChatApiService.debugSendClaudeStream(
        client: client,
        config: _config(),
        modelId: 'claude-sonnet-4-5',
        messages: _messages(),
      ).toList(),
      throwsA(isA<HttpException>()),
    );

    expect(requests, hasLength(1));
  });

  test('the learned ceiling is reused on the next call without a 400', () async {
    final requests = <Map<String, dynamic>>[];
    var calls = 0;
    final client = MockClient((request) async {
      requests.add(jsonDecode(request.body) as Map<String, dynamic>);
      calls += 1;
      if (calls == 1) return http.Response(_ceiling64000, 400);
      return http.Response(_okBody, 200);
    });

    Future<void> run() async {
      await ChatApiService.debugSendClaudeStream(
        client: client,
        config: _config(),
        modelId: 'claude-sonnet-4-5',
        messages: _messages(),
      ).toList();
    }

    await run();
    await run();

    expect(requests, hasLength(3));
    expect(requests.first['max_tokens'], claudeMaxTokensInitial);
    expect(requests[1]['max_tokens'], 64000);
    expect(
      requests[2]['max_tokens'],
      64000,
      reason: 'the second call starts from the learned ceiling',
    );
  });

  test('a ceiling stated on the final 400 is still remembered', () async {
    const ceiling32000 =
        '{"type":"error","error":{"type":"invalid_request_error","message":'
        '"max_tokens: 32001 > 32000, which is the maximum allowed number of '
        'output tokens for claude-sonnet-4-5"}}';
    const ceiling16000 =
        '{"type":"error","error":{"type":"invalid_request_error","message":'
        '"max_tokens: 16001 > 16000, which is the maximum allowed number of '
        'output tokens for claude-sonnet-4-5"}}';
    final bodies = <String>[_ceiling64000, ceiling32000, ceiling16000];
    final requests = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      requests.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(bodies[requests.length - 1], 400);
    });

    await expectLater(
      ChatApiService.debugSendClaudeStream(
        client: client,
        config: _config(),
        modelId: 'claude-sonnet-4-5',
        messages: _messages(),
      ).toList(),
      throwsA(isA<HttpException>()),
    );

    expect(requests, hasLength(3));
    expect(
      await LearnedMaxOutputCaps.lookup('p', 'claude-sonnet-4-5'),
      16000,
      reason: 'the last stated ceiling is recorded even on terminal failure',
    );
  });
}
