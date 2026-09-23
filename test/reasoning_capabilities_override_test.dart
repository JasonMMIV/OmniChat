import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:OmniChat/core/utils/reasoning_capabilities.dart';
import 'package:OmniChat/core/utils/reasoning_overrides.dart';

class _FakeCfg {
  final Map<String, dynamic> modelOverrides;
  const _FakeCfg(this.modelOverrides);
}

void main() {
  group('ReasoningOverride.fromMap', () {
    test('returns null for non-map payloads', () {
      expect(ReasoningOverride.fromMap(null), isNull);
      expect(ReasoningOverride.fromMap('nope'), isNull);
      expect(ReasoningOverride.fromMap(42), isNull);
    });

    test('parses a full map', () {
      final ovr = ReasoningOverride.fromMap(const {
        'v': 1,
        'efforts': ['none', 'low', 'max'],
        'offFallback': 'low',
        'supportsXhigh': false,
        'supportsMax': true,
        'thinkingAlwaysOn': true,
        'samplingRequiresNone': true,
        'adaptiveThinking': false,
      });
      expect(ovr, isNotNull);
      expect(ovr!.hasEfforts, isTrue);
      expect(ovr.efforts, {'none', 'low', 'max'});
      expect(ovr.hasOffFallback, isTrue);
      expect(ovr.offFallback, 'low');
      expect(ovr.supportsXhigh, isFalse);
      expect(ovr.supportsMax, isTrue);
      expect(ovr.thinkingAlwaysOn, isTrue);
      expect(ovr.samplingRequiresNone, isTrue);
    });

    test('is lenient: unknown effort strings dropped, empty list = no opinion',
        () {
      final junk = ReasoningOverride.fromMap(const {
        'efforts': ['ultra', '', 'LOW', 'high'],
        'offFallback': 7,
        'supportsXhigh': 'yes',
      });
      expect(junk, isNotNull);
      // 'LOW' normalizes to 'low' and 'high' kept; unknown dropped.
      expect(junk!.efforts, {'low', 'high'});
      expect(junk.hasOffFallback, isFalse);
      expect(junk.hasSupportsXhigh, isFalse);

      final empty = ReasoningOverride.fromMap(const {
        'efforts': <String>[],
      });
      expect(empty!.hasEfforts, isFalse);
      expect(empty.isEmpty, isTrue);
    });

    test('round-trips through toMap', () {
      final ovr = const ReasoningOverride(
        hasEfforts: true,
        efforts: {'none', 'low', 'medium', 'high'},
        hasOffFallback: true,
        offFallback: 'low',
        hasSupportsXhigh: true,
        supportsXhigh: false,
        hasSupportsMax: true,
        supportsMax: false,
        hasThinkingAlwaysOn: true,
        thinkingAlwaysOn: false,
        hasSamplingRequiresNone: false,
        samplingRequiresNone: false,
        hasAdaptiveThinking: false,
        adaptiveThinking: false,
      );
      final reparsed = ReasoningOverride.fromMap(ovr.toMap());
      expect(reparsed!.efforts, ovr.efforts);
      expect(reparsed.offFallback, 'low');
      expect(reparsed.supportsMax, isFalse);
      expect(reparsed.thinkingAlwaysOn, isFalse);
    });
  });

  group('mergeReasoningCapabilities', () {
    test('override fields win, untouched fields fall back to built-in', () {
      // GPT-5.6 Luna built-in: supportsMax, openAiEfforts with none,
      // offFallback 'none', samplingRequiresNone.
      final base = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'gpt-5.6-luna',
      );
      final merged = mergeReasoningCapabilities(
        base,
        ReasoningOverride.fromMap(const {
          'efforts': ['minimal', 'high'],
        }),
      );
      // efforts overridden
      expect(merged.openAiEfforts, {'minimal', 'high'});
      // With efforts declared, tier display derives from the set: Luna's
      // built-in max support no longer applies ('max' not in the set).
      expect(merged.supportsMax, isFalse);
      // untouched non-tier fields inherit built-in values
      expect(merged.samplingRequiresNone, base.samplingRequiresNone);
      expect(merged.openAiOffFallback, base.openAiOffFallback);
    });

    test('null/empty override returns built-in untouched', () {
      final base = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'gpt-5.4',
      );
      expect(
        identical(
          mergeReasoningCapabilities(base, null),
          base,
        ),
        isTrue,
      );
      final emptyOvr = ReasoningOverride.fromMap(const <String, dynamic>{});
      expect(
        identical(
          mergeReasoningCapabilities(base, emptyOvr),
          base,
        ),
        isTrue,
      );
    });

    test('unknown model gains capabilities from override', () {
      final merged = resolveReasoningCapabilities(
        ReasoningTransport.openAi,
        'brand-new-model-9000',
        override: ReasoningOverride.fromMap(const {
          'efforts': ['low', 'medium', 'high', 'xhigh', 'max'],
          'offFallback': 'low',
          'supportsXhigh': true,
          'supportsMax': true,
          'thinkingAlwaysOn': true,
        }),
      );
      expect(merged.supportsXhigh, isTrue);
      expect(merged.supportsMax, isTrue);
      expect(merged.thinkingAlwaysOn, isTrue);
      expect(merged.openAiEfforts, {'low', 'medium', 'high', 'xhigh', 'max'});
      // Off remaps to the floor instead of being dropped.
      expect(merged.normalizeOpenAiEffort('off'), 'low');
      expect(merged.normalizeOpenAiEffort('xhigh'), 'xhigh');
      // A value outside the declared set (and outside the known ladder
      // aliases) passes through untouched — the wire decides.
      expect(merged.normalizeOpenAiEffort('minimal'), 'minimal');
    });

    test('manual check of xhigh/max effort shows the tier tiles', () {
      // Regression: the manual-customization UI only edits the effort set,
      // while the budget sheet / popover tiles are gated on supportsXhigh /
      // supportsMax. An efforts-bearing override must derive those flags
      // from the set or manually checked tiers never appear.
      final merged = resolveReasoningCapabilities(
        ReasoningTransport.openAi,
        'brand-new-model-9000',
        override: ReasoningOverride.fromMap(const {
          'efforts': ['low', 'high', 'xhigh', 'max'],
          // deliberately no supportsXhigh/supportsMax stored
        }),
      );
      expect(merged.supportsXhigh, isTrue);
      expect(merged.supportsMax, isTrue);
    });

    test('stale flags cannot desync display tiers from the effort set', () {
      final merged = resolveReasoningCapabilities(
        ReasoningTransport.openAi,
        'brand-new-model-9000',
        override: ReasoningOverride.fromMap(const {
          'efforts': ['low'],
          'supportsXhigh': true,
          'supportsMax': true,
        }),
      );
      // The set is the single source of truth once it is declared.
      expect(merged.supportsXhigh, isFalse);
      expect(merged.supportsMax, isFalse);
    });

    test('all-false flag-only map counts as no opinion', () {
      // Switching to custom mode and saving without checking anything used
      // to persist all-false flags that masked built-in capabilities.
      final base = ReasoningCapabilities.forModel(
        ReasoningTransport.openAi,
        'gpt-5.6-luna',
      );
      final merged = mergeReasoningCapabilities(
        base,
        ReasoningOverride.fromMap(const {
          'supportsXhigh': false,
          'supportsMax': false,
          'thinkingAlwaysOn': false,
          'samplingRequiresNone': false,
          'adaptiveThinking': false,
        }),
      );
      expect(identical(merged, base), isTrue);
    });
  });

  group('request shape with override', () {
    Future<Map<String, dynamic>> captureBody({
      required Map<String, dynamic> modelOverrides,
      required int thinkingBudget,
      required String modelId,
    }) async {
      final bodyCompleter = Completer<Map<String, dynamic>>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final raw = await utf8.decoder.bind(request).join();
        if (!bodyCompleter.isCompleted) {
          bodyCompleter.complete(jsonDecode(raw) as Map<String, dynamic>);
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'ok'},
              },
            ],
          }),
        );
        await request.response.close();
      });

      final cfg = ProviderConfig(
        id: 'Aggregator',
        enabled: true,
        name: 'Aggregator',
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        providerType: ProviderKind.openai,
        modelOverrides: modelOverrides,
      );
      try {
        await ChatApiService.generateText(
          config: cfg,
          modelId: modelId,
          prompt: 'hello',
          thinkingBudget: thinkingBudget,
        );
        return await bodyCompleter.future.timeout(const Duration(seconds: 2));
      } finally {
        await server.close(force: true);
      }
    }

    test('custom effort values reach the wire unclamped', () async {
      final body = await captureBody(
        modelId: 'brand-new-model-9000',
        thinkingBudget: ReasoningBudget.max,
        modelOverrides: const {
          'brand-new-model-9000': {
            'apiModelId': 'brand-new-model-9000',
            'abilities': ['reasoning'],
            'reasoning': {
              'v': 1,
              'efforts': ['low', 'medium', 'high', 'xhigh', 'max'],
              'offFallback': 'low',
              'supportsXhigh': true,
              'supportsMax': true,
            },
          },
        },
      );
      expect(body['reasoning_effort'], 'max');
    });

    test('unknown model without an override stays clamped to built-in',
        () async {
      final body = await captureBody(
        modelId: 'brand-new-model-9000',
        thinkingBudget: ReasoningBudget.max,
        modelOverrides: const {
          'brand-new-model-9000': {
            'apiModelId': 'brand-new-model-9000',
            'abilities': ['reasoning'],
          },
        },
      );
      // Built-in table has no entry for this model: xhigh/max unsupported,
      // so the request must not claim max.
      expect(body['reasoning_effort'], isNot('max'));
      expect(body['reasoning_effort'], isNot('xhigh'));
    });

    test('samplingRequiresNone strips temperature/top_p', () async {
      final body = await captureBody(
        modelId: 'brand-new-model-9000',
        thinkingBudget: ReasoningBudget.heavy,
        modelOverrides: const {
          'brand-new-model-9000': {
            'apiModelId': 'brand-new-model-9000',
            'abilities': ['reasoning'],
            'reasoning': {
              'v': 1,
              'efforts': ['low', 'high'],
              'samplingRequiresNone': true,
            },
          },
        },
      );
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
      expect(body['reasoning_effort'], 'high');
    });
  });

  group('reasoningCapabilitiesFor (SettingsProvider static)', () {
    ProviderConfig cfgWith(Map<String, dynamic> overrides) => ProviderConfig(
          id: 'Aggregator',
          enabled: true,
          name: 'Aggregator',
          apiKey: '',
          baseUrl: 'https://example.invalid/v1',
          providerType: ProviderKind.openai,
          modelOverrides: overrides,
        );

    test('null config yields unsupported', () {
      expect(
        SettingsProvider.reasoningCapabilitiesFor(null, 'whatever')
            .supportsXhigh,
        isFalse,
      );
    });

    test('uses apiModelId for capability lookup', () {
      final caps = SettingsProvider.reasoningCapabilitiesFor(
        cfgWith(const {
          'logical-key': {'apiModelId': 'gpt-5.6-luna'},
        }),
        'logical-key',
      );
      expect(caps.supportsMax, isTrue);
      expect(caps.openAiEfforts.contains('none'), isTrue);
    });

    test('override merges on top of resolved upstream model', () {
      final caps = SettingsProvider.reasoningCapabilitiesFor(
        cfgWith(const {
          'logical-key': {
            'apiModelId': 'unknown-upstream-id',
            'reasoning': {
              'v': 1,
              'efforts': ['low', 'max'],
              'supportsMax': true,
            },
          },
        }),
        'logical-key',
      );
      expect(caps.openAiEfforts, {'low', 'max'});
      expect(caps.supportsMax, isTrue);
    });
  });

  test('_FakeCfg smoke (dynamic override extraction helper)', () {
    // reasoningCapabilitiesForCall reads modelOverrides through `dynamic`
    // (avoiding a provider import cycle in reasoning_overrides.dart).
    final caps = reasoningCapabilitiesForCall(
      ReasoningTransport.openAi,
      'logical-key',
      const _FakeCfg({
        'logical-key': {
          'reasoning': {
            'v': 1,
            'efforts': ['medium', 'high'],
          },
        },
      }),
    );
    expect(caps.openAiEfforts, {'medium', 'high'});
  });

  test('transport helper resolves overrides by upstream id (reverse lookup)',
      () {
    // The Claude path passes _apiModelId(config, modelId) — the upstream id,
    // not the logical key the override map is keyed by.
    final caps = reasoningCapabilitiesForCall(
      ReasoningTransport.claude,
      'upstream-vendor-id',
      const _FakeCfg({
        'my-logical-key': {
          'apiModelId': 'upstream-vendor-id',
          'reasoning': {
            'v': 1,
            'efforts': ['low', 'high'],
          },
        },
      }),
    );
    expect(caps.openAiEfforts, {'low', 'high'});
  });
}
