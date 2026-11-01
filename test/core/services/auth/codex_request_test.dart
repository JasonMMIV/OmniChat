// Codex Responses shaping (plan C8 / §8): store/stream flags, merged include,
// sampling-param stripping in every round, instruction-only fix-up and session
// headers.

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/services/auth/codex_request.dart';

CodexRequestContext _ctx() => const CodexRequestContext(
  accountId: 'acct_1',
  sessionId: 'conv_1',
  conversationId: 'conv_1',
  requestId: 'req_1',
);

void main() {
  test(
    'store=false, stream=true and encrypted reasoning include is merged',
    () {
      final body = applyCodexRequest(<String, dynamic>{
        'model': 'gpt-5.2',
        'input': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
        'temperature': 0.4,
        'top_p': 0.9,
        'max_output_tokens': 512,
        'include': <String>['web_search_call.action.sources'],
      }, ctx: _ctx());

      expect(body['store'], isFalse);
      expect(body['stream'], isTrue);
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
      expect(body.containsKey('max_output_tokens'), isFalse);
      expect(body['include'], <String>[
        'web_search_call.action.sources',
        codexReasoningInclude,
      ]);
    },
  );

  test('include is de-duplicated and not duplicated on repeat rounds', () {
    final first = applyCodexRequest(<String, dynamic>{
      'input': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': 'hi'},
      ],
      'include': <String>[codexReasoningInclude],
    }, ctx: _ctx());
    final second = applyCodexRequest(first, ctx: _ctx());
    expect(second['include'], <String>[codexReasoningInclude]);
  });

  test('instruction-only payloads gain a user input item', () {
    final body = applyCodexRequest(<String, dynamic>{
      'instructions': 'Write a short title.',
      'input': <dynamic>[],
      'stream': false,
    }, ctx: _ctx());
    expect(body.containsKey('instructions'), isFalse);
    final input = body['input'] as List;
    expect(input.length, 1);
    final item = input.first as Map;
    expect(item['role'], 'user');
    expect(
      ((item['content'] as List).first as Map)['text'],
      'Write a short title.',
    );
  });

  test('existing instructions and input are preserved', () {
    final body = applyCodexRequest(<String, dynamic>{
      'instructions': 'sys',
      'input': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': 'hi'},
      ],
    }, ctx: _ctx());
    expect(body['instructions'], 'sys');
    expect((body['input'] as List).length, 1);
  });

  test('prompt cache key follows the stable conversation session', () {
    final body = applyCodexRequest(<String, dynamic>{
      'input': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': 'hi'},
      ],
    }, ctx: _ctx());
    expect(body['prompt_cache_key'], 'conv_1');
  });

  test('more unsupported sampling params are stripped', () {
    final body = applyCodexRequest(<String, dynamic>{
      'input': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': 'hi'},
      ],
      'max_completion_tokens': 512,
      'min_p': 0.1,
      'repetition_penalty': 1.2,
      'stop': <String>['x'],
    }, ctx: _ctx());
    for (final key in <String>[
      'max_completion_tokens',
      'min_p',
      'repetition_penalty',
      'stop',
    ]) {
      expect(body.containsKey(key), isFalse, reason: key);
    }
  });

  test('dangling tool outputs and calls are repaired into a valid log', () {
    final body = applyCodexRequest(<String, dynamic>{
      'input': <dynamic>[
        <String, dynamic>{
          'type': 'function_call',
          'id': 'server-id',
          'call_id': 'call_open',
          'name': 'search',
          'arguments': '{}',
        },
        <String, dynamic>{
          'type': 'function_call_output',
          'call_id': 'call_orphan',
          'output': 'orphan result',
        },
        <String, dynamic>{'type': 'item_reference', 'id': 'ref_1'},
      ],
    }, ctx: _ctx());
    final input = body['input'] as List;
    // item_reference is dropped, and the dangling call gains an output.
    expect(input.whereType<Map>().map((e) => e['type']), <String>[
      'function_call',
      'function_call_output',
      'message',
    ]);
    final call = input[0] as Map;
    expect(call.containsKey('id'), isFalse, reason: 'server id is stripped');
    final repaired = input[1] as Map;
    expect(repaired['call_id'], 'call_open');
    expect(repaired['output'], contains('No tool output recorded'));
    final orphan = input[2] as Map;
    expect(orphan['role'], 'assistant');
    expect(orphan['content'], contains('orphan result'));
  });

  test('headers carry auth, account, version, originator and session ids', () {
    final credentials = ProviderOAuthCredentials(
      accessToken: 'tok',
      refreshToken: 'ref',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      sessionId: 'login-session',
      accountId: 'acct_1',
      extra: const <String, dynamic>{'residency': 'us', 'routingHint': 'hint'},
    );
    final headers = codexOAuthHeaders(
      credentials,
      sessionId: 'conv_9',
      conversationId: 'conv_9',
      requestId: 'req_9',
    );
    expect(headers['Authorization'], 'Bearer tok');
    expect(headers['chatgpt-account-id'], 'acct_1');
    expect(headers['originator'], ProviderOAuthConstants.codexOriginator);
    expect(headers['version'], ProviderOAuthConstants.codexClientVersion);
    expect(headers['OpenAI-Beta'], contains('responses'));
    expect(headers['session_id'], 'conv_9');
    expect(headers['conversation_id'], 'conv_9');
    expect(headers['x-client-request-id'], 'req_9');
    expect(headers['x-openai-internal-codex-residency'], 'us');
    expect(headers['x-codex-routing-hint'], 'hint');
  });
}
