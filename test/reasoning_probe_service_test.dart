import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:OmniChat/core/providers/model_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/utils/reasoning_overrides.dart';

final _cfg = ProviderConfig(
  id: 'Aggregator',
  enabled: true,
  name: 'Aggregator',
  apiKey: 'test-key',
  baseUrl: 'http://example.invalid/v1',
  providerType: ProviderKind.openai,
);

http.Response _ok([
  Map<String, dynamic>? usage,
]) =>
    http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {'content': 'ok'},
          },
        ],
        if (usage != null) 'usage': usage,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

http.Response _reject(String body) => http.Response(body, 400);

void main() {
  test('probe classifies the ladder and derives offFallback', () async {
    final requests = <Map<String, dynamic>>[];
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      requests.add(body);
      final effort = body['reasoning_effort'] as String?;
      switch (effort) {
        case null:
        case 'none':
        case 'low':
        case 'medium':
        case 'high':
          return _ok();
        case 'xhigh':
        case 'max':
          return _reject('{"error":{"message":"reasoning_effort is not '
              'supported by this model"}}');
        default:
          return _ok();
      }
    });

    final summary = await ProviderManager.probeReasoning(
      _cfg,
      'brand-new-model',
      client: client,
    );

    expect(summary.baselineOk, isTrue);
    expect(summary.supported, ['none', 'minimal', 'low', 'medium', 'high']);
    expect(summary.unsupported, ['xhigh', 'max']);
    expect(summary.unknown, isEmpty);
    expect(summary.suggestedOffFallback, 'none');
    expect(summary.suggestedThinkingAlwaysOn, isFalse);

    // Every request must carry the 16-token cap and the upstream id.
    for (final r in requests) {
      expect(r['model'], 'brand-new-model');
      expect(r['max_tokens'], 16);
    }
    // Baseline has no effort parameter.
    expect(requests.first.containsKey('reasoning_effort'), isFalse);
  });

  test('probe reports reasoning_tokens signal when usage exposes it',
      () async {
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final effort = body['reasoning_effort'] as String?;
      if (effort == 'high') {
        return _ok({
          'completion_tokens_details': {'reasoning_tokens': 128},
        });
      }
      return _ok();
    });

    final summary = await ProviderManager.probeReasoning(
      _cfg,
      'brand-new-model',
      client: client,
      efforts: ['low', 'high'],
    );

    expect(summary.supported, ['low', 'high']);
    expect(summary.reasoningTokenEfforts, {'high'});
  });

  test('probe maps timeouts / 5xx to unknown, never auto-applied', () async {
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final effort = body['reasoning_effort'] as String?;
      if (effort == 'low') throw const SocketException('reset');
      if (effort == 'high') {
        return http.Response('upstream exploded', 503);
      }
      return _ok();
    });

    final summary = await ProviderManager.probeReasoning(
      _cfg,
      'brand-new-model',
      client: client,
      efforts: ['low', 'high'],
    );

    expect(summary.supported, isEmpty);
    expect(summary.unknown, ['low', 'high']);
    // Nothing conclusive: there is no override data to apply at all.
    expect(summary.toOverrideMap(), isNull);
  });

  test('probe retried without the token cap when the validator names it',
      () async {
    final requests = <Map<String, dynamic>>[];
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      requests.add(body);
      if (body.containsKey('max_tokens')) {
        return _reject('{"error":{"message":"max_tokens is not supported, '
            'use max_completion_tokens"}}');
      }
      return _ok();
    });

    final summary = await ProviderManager.probeReasoning(
      _cfg,
      'brand-new-model',
      client: client,
      efforts: ['low'],
    );

    expect(summary.baselineOk, isTrue);
    expect(summary.supported, ['low']);
    // Baseline renegotiated the cap key, so the ladder request used it.
    expect(requests.last['max_completion_tokens'], 16);
    expect(requests.last.containsKey('max_tokens'), isFalse);
  });

  test('probe fails fast with ReasoningProbeException on baseline failure',
      () async {
    final client = MockClient((req) async => http.Response('denied', 401));

    await expectLater(
      ProviderManager.probeReasoning(
        _cfg,
        'brand-new-model',
        client: client,
      ),
      throwsA(isA<ReasoningProbeException>()),
    );
  });

  test('probe rejects non-OpenAI transports', () async {
    final claudeCfg = ProviderConfig(
      id: 'Anthropic',
      enabled: true,
      name: 'Anthropic',
      apiKey: 'k',
      baseUrl: 'http://example.invalid',
      providerType: ProviderKind.claude,
    );
    final client = MockClient((req) async => _ok());
    await expectLater(
      ProviderManager.probeReasoning(claudeCfg, 'claude-x', client: client),
      throwsA(isA<ReasoningProbeException>()),
    );
  });

  test('probe honours cancellation between ladder steps', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return _ok();
    });

    final summary = await ProviderManager.probeReasoning(
      _cfg,
      'brand-new-model',
      client: client,
      efforts: ['none', 'low', 'medium'],
      isCancelled: () => calls >= 2,
    );

    expect(summary.cancelled, isTrue);
    // Baseline + first ladder step happened; the rest was skipped.
    expect(calls, 2);
    expect(summary.supported, ['none']);
  });

  test('toOverrideMap feeds ReasoningOverride and round-trips', () async {
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final effort = body['reasoning_effort'] as String?;
      return (effort == 'xhigh' || effort == 'max')
          ? _reject('reasoning_effort unsupported')
          : _ok();
    });

    final summary = await ProviderManager.probeReasoning(
      _cfg,
      'brand-new-model',
      client: client,
    );
    expect(summary.suggestedOffFallback, 'none');
    expect(summary.suggestedThinkingAlwaysOn, isFalse);

    final map = summary.toOverrideMap();
    expect(map, isNotNull);
    final ovr = ReasoningOverride.fromMap(map);
    expect(ovr, isNotNull);
    expect(ovr!.efforts, summary.supported.toSet());
    expect(ovr.supportsMax, isFalse);
    expect(ovr.supportsXhigh, isFalse);
    // The stored shape is exactly what modelOverrides[key]['reasoning']
    // expects: a versioned map with the efforts list.
    expect(map!['v'], 1);
    expect(map['efforts'], ['none', 'minimal', 'low', 'medium', 'high']);
  });
}
