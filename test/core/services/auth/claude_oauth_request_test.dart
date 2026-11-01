// Claude Code fingerprint layer: headers, system-block conversion, tool-name
// prefixing, max_tokens clamping, cache breakpoints and cch determinism
// (plan C4 / C7 / §8).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/services/auth/claude_oauth_request.dart';

ClaudeOAuthRequestContext _ctx({bool caching = true}) =>
    ClaudeOAuthRequestContext(
      deviceId: 'device-123',
      sessionId: 'session-456',
      accountId: 'account-789',
      promptCaching: caching,
      cacheTtl: '1h',
    );

Map<String, dynamic> _baseBody() => <String, dynamic>{
  'model': 'claude-sonnet-4-5',
  'max_tokens': 200000,
  'system': 'You are OmniChat.',
  'cache_control': <String, dynamic>{'type': 'ephemeral'},
  'messages': <Map<String, dynamic>>[
    <String, dynamic>{'role': 'user', 'content': 'hello'},
  ],
  'tools': <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'web_search',
      'input_schema': <String, dynamic>{},
    },
    <String, dynamic>{'name': 'file_read', 'input_schema': <String, dynamic>{}},
  ],
};

void main() {
  test('xxhash64 matches the published vectors', () {
    expect(xxh64Hex(utf8.encode('')), 'ef46db3751d8e999');
    expect(xxh64Hex(utf8.encode('a')), 'd24ec4f1a98c6e5b');
    expect(xxh64Hex(utf8.encode('abc')), '44bc2cf5ad770999');
  });

  test('canonical json sorts keys recursively', () {
    expect(
      canonicalJson(<String, dynamic>{
        'b': 1,
        'a': <String, dynamic>{'d': 2, 'c': 3},
      }),
      '{"a":{"c":3,"d":2},"b":1}',
    );
  });

  test(
    'system string becomes blocks and top-level cache_control is removed',
    () {
      final body = encodeClaudeOAuthRequest(_baseBody(), ctx: _ctx());
      expect(body.containsKey('cache_control'), isFalse);
      final system = body['system'] as List;
      expect(system.length, greaterThanOrEqualTo(3));
      final texts = system.map((e) => (e as Map)['text'].toString()).toList();
      expect(texts[1], claudeCodeIdentity);
      expect(texts.last, 'You are OmniChat.');
      expect((system[1] as Map)['cache_control'], <String, dynamic>{
        'type': 'ephemeral',
        'ttl': '1h',
      });
      // Billing header is the first block and carries a cch value.
      expect(texts.first, contains('x-anthropic-billing-header'));
      expect(texts.first, contains('cch='));
      expect(texts.first, contains('cc_entrypoint=cli'));
    },
  );

  test('cch is the seeded hash suffix of the exact serialized payload', () {
    final body = encodeClaudeOAuthRequest(_baseBody(), ctx: _ctx());
    final billing = ((body['system'] as List).first as Map)['text'] as String;
    final match = RegExp(r'cch=([0-9a-f]{5});').firstMatch(billing);
    expect(match, isNotNull);
    final actual = match!.group(1)!;

    // Rebuild the serialized body with the placeholder cch; everything else
    // (including the fixed key order) must be byte-identical.
    final copy = jsonDecode(jsonEncode(body)) as Map<String, dynamic>;
    ((copy['system'] as List).first as Map)['text'] = billing.replaceFirst(
      'cch=$actual',
      'cch=$claudeCchPlaceholder',
    );
    final digest = xxh64Hex(utf8.encode(jsonEncode(copy)), seed: claudeCchSeed);
    expect(actual, digest.substring(digest.length - 5));
  });

  test('billing fingerprint is stable for the same first turn', () {
    final first = claudeBillingFingerprint('hello', cliVersion: '2.1.280');
    final second = claudeBillingFingerprint('hello', cliVersion: '2.1.280');
    expect(first, second);
    expect(first, hasLength(3));
    expect(
      first,
      isNot(claudeBillingFingerprint('other', cliVersion: '2.1.280')),
    );
  });

  test('a forced tool_choice name is prefixed with the other tool names', () {
    final raw = _baseBody()
      ..['tool_choice'] = <String, dynamic>{
        'type': 'tool',
        'name': 'file_read',
      };
    final body = encodeClaudeOAuthRequest(raw, ctx: _ctx());
    expect((body['tool_choice'] as Map)['name'], '_file_read');
  });

  test('max_tokens is clamped to the OAuth ceiling', () {
    final body = encodeClaudeOAuthRequest(_baseBody(), ctx: _ctx());
    expect(body['max_tokens'], ProviderOAuthConstants.claudeMaxTokensCap);
  });

  test('thinking budget keeps the output reserve below max_tokens', () {
    final raw = _baseBody()
      ..['max_tokens'] = 16000
      ..['thinking'] = <String, dynamic>{
        'type': 'enabled',
        'budget_tokens': 15000,
      };
    final body = encodeClaudeOAuthRequest(raw, ctx: _ctx());
    final maxTokens = body['max_tokens'] as int;
    final budget = (body['thinking'] as Map)['budget_tokens'] as int;
    expect(maxTokens, 19000);
    expect(budget, lessThan(maxTokens));
    expect(maxTokens - budget, greaterThanOrEqualTo(4000));
  });

  test('thinking budget shrinks when the cap leaves under 4k of output', () {
    final raw = _baseBody()
      ..['max_tokens'] = 200000
      ..['thinking'] = <String, dynamic>{
        'type': 'enabled',
        'budget_tokens': 63000,
      };
    final body = encodeClaudeOAuthRequest(raw, ctx: _ctx());
    expect(body['max_tokens'], 64000);
    expect((body['thinking'] as Map)['budget_tokens'], 60000);
  });

  test('client tools are prefixed and server tools are untouched', () {
    final body = encodeClaudeOAuthRequest(_baseBody(), ctx: _ctx());
    final names = [
      for (final tool in body['tools'] as List) (tool as Map)['name'],
    ];
    expect(names, <String>['web_search', '_file_read']);
    expect(restoreClaudeOAuthToolName('_file_read'), 'file_read');
    expect(restoreClaudeOAuthToolName('web_search'), 'web_search');
    // A user tool that already starts with an underscore must round-trip.
    expect(
      restoreClaudeOAuthToolName(claudeOAuthToolName('_private')),
      '_private',
    );
  });

  test('historical tool_use blocks are prefixed like the tool list', () {
    final raw = _baseBody()
      ..['messages'] = <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'assistant',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'tool_use',
              'id': 'tu_1',
              'name': 'file_read',
              'input': <String, dynamic>{},
            },
          ],
        },
        <String, dynamic>{
          'role': 'user',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'tool_result',
              'tool_use_id': 'tu_1',
              'content': 'ok',
            },
          ],
        },
      ];
    final body = encodeClaudeOAuthRequest(raw, ctx: _ctx());
    final first = ((body['messages'] as List).first as Map)['content'] as List;
    expect((first.first as Map)['name'], '_file_read');
  });

  test('metadata carries device, session and account identity', () {
    final body = encodeClaudeOAuthRequest(_baseBody(), ctx: _ctx());
    final userId = jsonDecode((body['metadata'] as Map)['user_id'] as String);
    expect(userId, <String, dynamic>{
      'device_id': 'device-123',
      'session_id': 'session-456',
      'account_uuid': 'account-789',
    });
  });

  test('encoding the same raw payload twice is identical (C4)', () {
    final raw = _baseBody();
    final first = jsonEncode(encodeClaudeOAuthRequest(raw, ctx: _ctx()));
    final second = jsonEncode(encodeClaudeOAuthRequest(raw, ctx: _ctx()));
    expect(first, second);
    // And the input was not mutated.
    expect(raw['max_tokens'], 200000);
    expect(raw['cache_control'], isNotNull);
  });

  test('string user turns receive a message cache breakpoint', () {
    final raw = _baseBody()
      ..['messages'] = <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': 'first'},
        <String, dynamic>{'role': 'assistant', 'content': 'answer'},
        <String, dynamic>{'role': 'user', 'content': 'latest question'},
      ];
    final body = encodeClaudeOAuthRequest(raw, ctx: _ctx());
    final last = (body['messages'] as List).last as Map;
    expect(last['content'], isA<List>());
    final blocks = last['content'] as List;
    expect(
      blocks.any((block) => (block as Map)['cache_control'] != null),
      isTrue,
    );
  });

  test('cache breakpoints never exceed four', () {
    final messages = <Map<String, dynamic>>[
      for (var i = 0; i < 40; i++)
        <String, dynamic>{
          'role': i.isEven ? 'user' : 'assistant',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': 'm$i'},
          ],
        },
    ];
    final raw = _baseBody()..['messages'] = messages;
    final body = encodeClaudeOAuthRequest(raw, ctx: _ctx());
    var count = 0;
    for (final block in body['system'] as List) {
      if ((block as Map)['cache_control'] != null) count++;
    }
    for (final tool in body['tools'] as List) {
      if ((tool as Map)['cache_control'] != null) count++;
    }
    for (final message in body['messages'] as List) {
      for (final block in (message as Map)['content'] as List) {
        if ((block as Map)['cache_control'] != null) count++;
      }
    }
    expect(count, lessThanOrEqualTo(4));
    expect(count, greaterThan(0));
  });

  test('prompt caching off leaves no cache_control anywhere', () {
    final body = encodeClaudeOAuthRequest(
      _baseBody(),
      ctx: _ctx(caching: false),
    );
    expect(jsonEncode(body).contains('cache_control'), isFalse);
  });

  test('headers use bearer auth and beta set, never x-api-key', () {
    final creds = ProviderOAuthCredentials(
      accessToken: 'tok',
      refreshToken: 'ref',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      sessionId: 's',
    );
    final headers = claudeOAuthHeaders(creds);
    expect(headers['Authorization'], 'Bearer tok');
    expect(headers.containsKey('x-api-key'), isFalse);
    expect(headers['anthropic-beta'], contains('oauth-2025-04-20'));
    expect(headers['X-Claude-Code-Session-Id'], 's');
    expect(headers['user-agent'], startsWith('claude-cli/'));
  });

  test('messages url carries the beta flag', () {
    expect(
      claudeOAuthMessagesUrl('https://api.anthropic.com/v1').toString(),
      'https://api.anthropic.com/v1/messages?beta=true',
    );
  });

  test('claude_code_version_too_old extracts the required version', () {
    expect(
      claudeRequiredVersionFromError(
        '{"error":{"message":"claude_code_version_too_old: '
        'please upgrade to version 2.1.300 or newer"}}',
      ),
      '2.1.300',
    );
    expect(claudeRequiredVersionFromError('other error'), isNull);
  });
}
