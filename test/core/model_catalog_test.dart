import 'dart:convert' as convert;

import 'package:OmniChat/core/providers/model_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/model_catalog/model_catalog.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

const String _fixture = '''
{
  "openai": {
    "models": {
      "gpt-5": {
        "limit": {"context": 400000},
        "modalities": {"input": ["text"], "output": ["text"]},
        "tool_call": false,
        "reasoning": false
      },
      "gpt-5.6": {
        "limit": {"context": 500000},
        "modalities": {"input": ["text"], "output": ["text"]}
      },
      "gpt-5.6-luna": {
        "limit": {"context": 400000, "input": 272000, "output": 128000},
        "modalities": {
          "input": ["text", "image", "pdf"],
          "output": ["text"]
        },
        "tool_call": true,
        "reasoning": true,
        "temperature": false,
        "interleaved": {"field": "reasoning_content"},
        "reasoning_options": [
          {"type": "effort", "values": ["none", "low", "medium", "high", "xhigh", "max"]},
          {"type": "budget_tokens", "min": 1024, "max": 64000}
        ],
        "canonical_model_id": "openai/gpt-5.6-luna"
      },
      "gpt-5.6-sol": {
        "limit": {"context": 400000},
        "reasoning": true,
        "reasoning_options": []
      }
    }
  },
  "openrouter": {
    "api": "https://openrouter.ai/api/v1",
    "models": {
      "openai/gpt-5.6-luna": {
        "limit": {"context": 1000000, "input": 900000, "output": 64000},
        "modalities": {"input": ["text", "image"], "output": ["text"]},
        "tool_call": true,
        "reasoning": true
      }
    }
  },
  "anthropic": {
    "api": "https://api.anthropic.com/v1",
    "models": {
      "claude-sonnet-4-5": {
        "limit": {"context": 200000, "output": 64000},
        "modalities": {"input": ["text", "image", "pdf"], "output": ["text"]},
        "tool_call": true,
        "reasoning": true,
        "temperature": true,
        "reasoning_options": [{"type": "budget_tokens", "min": 1024}],
        "canonical_model_id": "anthropic/claude-sonnet-4-5"
      }
    }
  },
  "google": {
    "api": "https://generativelanguage.googleapis.com/v1beta",
    "models": {
      "gemini-3-flash": {
        "limit": {"context": 1048576, "output": 65536},
        "modalities": {"input": ["text", "image"], "output": ["text"]},
        "tool_call": true,
        "reasoning": true,
        "reasoning_options": [{"type": "toggle"}]
      },
      "gemini-2.5-flash-image": {
        "limit": {"context": 32768, "output": 32768},
        "modalities": {
          "input": ["text", "image"],
          "output": ["text", "image"]
        },
        "tool_call": false,
        "reasoning": false
      }
    }
  }
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ModelCatalog catalog;

  setUp(() {
    catalog = ModelCatalog.fromJsonString(_fixture);
    ModelCatalog.instance = catalog;
  });

  tearDown(ModelCatalog.debugReset);

  group('lookup ladder', () {
    test('provider id + model id wins', () {
      final model = catalog.lookup(
        providerId: 'openai',
        modelId: 'gpt-5.6-luna',
      );
      expect(model, isNotNull);
      expect(model!.context, 400000);
      expect(model.input, 272000);
    });

    test('host match ignores scheme, api prefix and path', () {
      for (final host in const [
        'https://openrouter.ai/api/v1',
        'https://api.openrouter.ai/v1',
        'api.openrouter.ai',
      ]) {
        final model = catalog.lookup(
          host: host,
          modelId: 'openai/gpt-5.6-luna',
        );
        expect(model, isNotNull, reason: host);
        expect(model!.providerId, 'openrouter', reason: host);
        expect(model.context, 1000000, reason: host);
      }
    });

    test('provider hint beats host and global', () {
      final model = catalog.lookup(
        providerId: 'openai',
        host: 'https://openrouter.ai/api/v1',
        modelId: 'openai/gpt-5.6-luna',
      );
      // The openai provider has no model with the prefixed id, so the host
      // entry answers.
      expect(model!.providerId, 'openrouter');
    });

    test('global model id match', () {
      final model = catalog.lookup(modelId: 'claude-sonnet-4-5');
      expect(model, isNotNull);
      expect(model!.providerId, 'anthropic');
      expect(ModelCatalog.instance!.hasModel('CLAUDE-SONNET-4-5'), isTrue);
    });

    test('canonical alias match', () {
      final model = catalog.lookup(modelId: 'anthropic/claude-sonnet-4-5');
      expect(model, isNotNull);
      expect(model!.modelId, 'claude-sonnet-4-5');
    });

    test('normalized match strips one vendor prefix', () {
      final model = catalog.lookup(modelId: 'somevendor/gpt-5.6-luna');
      expect(model, isNotNull);
      expect(model!.modelId, 'gpt-5.6-luna');
    });

    test('variant suffix is stripped', () {
      final model = catalog.lookup(modelId: 'gpt-5.6-luna:free');
      expect(model, isNotNull);
      expect(model!.modelId, 'gpt-5.6-luna');
    });

    test('normalization keeps version dots and strips provider dots', () {
      expect(normalizeModelId('gpt-5.5'), 'gpt-5.5');
      expect(normalizeModelId('claude-sonnet-4.5'), 'claude-sonnet-4.5');
      expect(normalizeModelId('openai.gpt-5.6-luna'), 'gpt-5.6-luna');
    });

    test('version-dot ids do not normalize onto an unrelated model', () {
      // `claude-sonnet-4.5` is not in the fixture; before version dots were
      // preserved its normalized form collapsed to `5` and matched `gpt-5`.
      expect(catalog.lookup(modelId: 'claude-sonnet-4.5'), isNull);
      expect(catalog.hasModel('claude-sonnet-4.5'), isFalse);
    });

    test('no fuzzy matching: gpt-5 does not hit gpt-5.6', () {
      final model = catalog.lookup(modelId: 'gpt-5');
      expect(model!.modelId, 'gpt-5');
      expect(model.context, 400000);
      expect(catalog.lookup(modelId: 'gpt-5.6')!.modelId, 'gpt-5.6');
      expect(catalog.lookup(modelId: 'gpt-5.7'), isNull);
    });

    test('unknown model returns null', () {
      expect(catalog.lookup(modelId: 'totally-unknown'), isNull);
      expect(catalog.lookup(modelId: ''), isNull);
    });
  });

  group('capabilities', () {
    test('image input, tool and reasoning map from the catalog', () {
      final model = catalog.lookup(
        providerId: 'openai',
        modelId: 'gpt-5.6-luna',
      )!;
      expect(model.imageInput, isTrue);
      expect(model.imageOutput, isFalse);
      expect(model.toolCall, isTrue);
      expect(model.reasoning, isTrue);
    });

    test('temperature false is exposed as unsupported sampling', () {
      expect(
        catalog
            .lookup(providerId: 'openai', modelId: 'gpt-5.6-luna')!
            .temperatureSupported,
        isFalse,
      );
      expect(
        catalog
            .lookup(modelId: 'claude-sonnet-4-5')!
            .temperatureSupported,
        isTrue,
      );
    });

    test('reasoning_options effort / toggle / budget bounds', () {
      final luna =
          catalog.lookup(modelId: 'gpt-5.6-luna', providerId: 'openai')!;
      expect(
        luna.efforts,
        {'none', 'low', 'medium', 'high', 'xhigh', 'max'},
      );
      expect(luna.hasToggle, isFalse);
      expect(luna.budgetMin, 1024);
      expect(luna.budgetMax, 64000);

      final gemini = catalog.lookup(modelId: 'gemini-3-flash')!;
      expect(gemini.hasToggle, isTrue);
      expect(gemini.efforts, isEmpty);
    });

    test('empty reasoning_options means unknown, not unsupported', () {
      final sol = catalog.lookup(modelId: 'gpt-5.6-sol')!;
      expect(sol.reasoning, isTrue);
      expect(sol.efforts, isEmpty);
    });

    test('interleaved field is exposed', () {
      expect(
        catalog.lookup(modelId: 'gpt-5.6-luna')!.interleavedField,
        'reasoning_content',
      );
      expect(
        catalog.lookup(modelId: 'claude-sonnet-4-5')!.interleaved,
        isFalse,
      );
    });
  });

  group('window helpers', () {
    test('limit.input wins over limit.context', () {
      expect(
        catalog.windowTokens('gpt-5.6-luna', providerId: 'openai'),
        272000,
      );
      expect(catalog.outputTokens('gpt-5.6-luna', providerId: 'openai'), 128000);
    });

    test('context is used when input is absent', () {
      expect(catalog.windowTokens('claude-sonnet-4-5'), 200000);
    });

    test('undefined windows stay null', () {
      expect(catalog.windowTokens('missing-model'), isNull);
      expect(catalog.outputTokens('gpt-5'), isNull);
    });

    test('missing limit does not become zero', () {
      final model = catalog.lookup(modelId: 'gpt-5.6-sol')!;
      expect(model.input, isNull);
      expect(model.output, isNull);
      expect(model.effectiveInputWindow, 400000);
    });
  });

  group('provider id resolution', () {
    test('explicit provider id', () {
      expect(
        resolveCatalogProviderId(providerId: 'openrouter'),
        'openrouter',
      );
    });

    test('display name', () {
      expect(
        resolveCatalogProviderId(providerId: 'MyKey', providerName: 'Anthropic'),
        'anthropic',
      );
    });

    test('host', () {
      expect(
        resolveCatalogProviderId(
          providerId: 'my-proxy',
          host: 'https://api.openrouter.ai/v1',
          providerType: 'openai',
        ),
        'openrouter',
      );
    });

    test('transport defaults', () {
      expect(
        resolveCatalogProviderId(providerId: 'my-claude', providerType: 'claude'),
        'anthropic',
      );
      expect(
        resolveCatalogProviderId(providerId: 'my-openai', providerType: 'openai'),
        'openai',
      );
      expect(
        resolveCatalogProviderId(providerId: 'my-google', providerType: 'google'),
        'google',
      );
    });

    test('neuralwatt and unknown providers fall through', () {
      expect(
        resolveCatalogProviderId(
          providerId: 'neuralwatt',
          providerType: 'neuralwatt',
        ),
        isNull,
      );
      expect(resolveCatalogProviderId(providerId: 'whatever'), isNull);
    });

    test('returns null without a loaded catalog', () {
      ModelCatalog.debugReset();
      expect(resolveCatalogProviderId(providerId: 'openai'), isNull);
    });
  });

  group('pruning', () {
    test('keeps consumed fields and drops the rest', () {      const raw = '''
      {
        "openai": {
          "api": "https://api.openai.com/v1",
          "name": "OpenAI",
          "models": {
            "m": {
              "name": "M",
              "description": "noise",
              "cost": {"input": 1},
              "limit": {"context": 1000, "input": 900, "output": 100},
              "modalities": {"input": ["text", "image"], "output": ["text"]},
              "tool_call": true,
              "reasoning": true,
              "temperature": false,
              "interleaved": true,
              "reasoning_options": [{"type": "effort", "values": ["low"]}]
            }
          }
        }
      }
      ''';
      final pruned = pruneCatalogJson(raw);
      expect(pruned.contains('"name"'), isFalse);
      expect(pruned.contains('"cost"'), isFalse);
      expect(pruned.contains('"context":1000'), isTrue);
      expect(pruned.contains('"temperature":false'), isTrue);
      expect(pruned.contains('"interleaved":true'), isTrue);
    });
  });

  group('ModelRegistry projection', () {
    test('input/output/abilities and token limits come from the catalog', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'claude-sonnet-4-5', displayName: 'claude-sonnet-4-5'),
      );
      expect(info.type, ModelType.chat);
      expect(
        info.input,
        containsAll([Modality.text, Modality.image, Modality.pdf]),
      );
      expect(info.output, [Modality.text]);
      expect(
        info.abilities,
        containsAll([ModelAbility.tool, ModelAbility.reasoning]),
      );
      // `limit.context` / `limit.output` are carried onto ModelInfo for the
      // chip and the Token limits fields.
      expect(info.contextWindow, 200000);
      expect(info.maxOutput, 64000);
    });

    test('contextWindow prefers the catalog input cap over total context', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'gpt-5.6-luna', displayName: 'gpt-5.6-luna'),
      );
      // limit.context 400k / limit.input 272k — the chip and the ring must
      // quote the same usable-input number.
      expect(info.contextWindow, 272000);
      expect(info.maxOutput, 128000);
    });

    test('image-family early return keeps catalog token limits', () {
      final info = ModelRegistry.infer(
        ModelInfo(
          id: 'gemini-2.5-flash-image',
          displayName: 'gemini-2.5-flash-image',
        ),
      );
      expect(info.output, contains(Modality.image));
      // The image-id branch returns before the general catalog projection;
      // the limits must still come from the catalog.
      expect(info.contextWindow, 32768);
      expect(info.maxOutput, 32768);
      expect(info.abilities, isEmpty);
    });

    test('output absent in the catalog stays null', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'gpt-5', displayName: 'gpt-5'),
      );
      expect(info.contextWindow, 400000);
      expect(info.maxOutput, isNull);
      // The fixture's gpt-5 entry has no modalities — nothing may be
      // invented, but `context` must still surface.
      expect(info.input, [Modality.text]);
    });

    test('catalog miss falls back to regexes without token limits', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'totally-unknown-model', displayName: 'x'),
      );
      expect(info.input, [Modality.text]);
      expect(info.abilities, isEmpty);
      expect(info.contextWindow, isNull);
      expect(info.maxOutput, isNull);
    });

    test('user overrides win over catalog values', () {
      final base = ModelRegistry.infer(
        ModelInfo(id: 'claude-sonnet-4-5', displayName: 'claude-sonnet-4-5'),
      );
      final over = ModelRegistry.applyOverride(base, <String, dynamic>{
        'contextWindow': 123456,
        'maxOutput': 8000,
        'type': 'chat',
        'input': ['text'],
        'output': ['text'],
        'abilities': ['tool'],
        'inputV': 2,
      });
      expect(over.contextWindow, 123456);
      expect(over.maxOutput, 8000);
      expect(over.input, [Modality.text]);
      expect(over.abilities, [ModelAbility.tool]);
      // An absent key keeps the catalog-derived value.
      final partial = ModelRegistry.applyOverride(base, <String, dynamic>{
        'maxOutput': 4096,
      });
      expect(partial.contextWindow, 200000);
      expect(partial.maxOutput, 4096);
    });

    test('non-positive / malformed token overrides are ignored', () {
      final base = ModelRegistry.infer(
        ModelInfo(id: 'claude-sonnet-4-5', displayName: 'x'),
      );
      final over = ModelRegistry.applyOverride(base, <String, dynamic>{
        'contextWindow': 0,
        'maxOutput': -5,
      });
      expect(over.contextWindow, 200000);
      expect(over.maxOutput, 64000);
      final stringOver = ModelRegistry.applyOverride(base, <String, dynamic>{
        'contextWindow': '999999',
        'maxOutput': '8192',
      });
      expect(stringOver.contextWindow, 999999);
      expect(stringOver.maxOutput, 8192);
    });

    test('an explicit empty abilities list disables inferred abilities', () {
      final base = ModelRegistry.infer(
        ModelInfo(id: 'claude-sonnet-4-5', displayName: 'x'),
      );
      final over = ModelRegistry.applyOverride(base, <String, dynamic>{
        'abilities': <String>[],
      });
      // "No abilities" is a valid user choice and must not fall back to the
      // catalog's tool/reasoning flags.
      expect(over.abilities, isEmpty);
    });

    test('effectiveForModel maps apiModelId before inferring', () {
      final cfg = ProviderConfig(
        id: 'provider',
        enabled: true,
        name: 'Provider',
        apiKey: 'k',
        baseUrl: 'https://openrouter.ai/api/v1',
        providerType: ProviderKind.openai,
        models: const <String>['alias'],
        modelOverrides: <String, dynamic>{
          'alias': <String, dynamic>{
            'apiModelId': 'claude-sonnet-4-5',
            'name': 'Alias',
            'abilities': <String>[],
          },
        },
      );
      final info = ModelRegistry.effectiveForModel(cfg, 'alias');
      expect(info.contextWindow, 200000);
      expect(info.maxOutput, 64000);
      expect(info.abilities, isEmpty);
    });
  });

  // Task 4 verification: the bundled models.dev snapshot must survive the
  // same prune → parse pipeline the runtime refresh uses, and project the
  // fields the model detail sheet / chips consume.
  group('bundled snapshot', () {
    test('asset round-trips pruneCatalogJson with intact fields', () async {
      final raw = await rootBundle.loadString(
        'assets/model_catalog/models_dev.json',
      );
      expect(raw, isNotEmpty);
      final pruned = pruneCatalogJson(raw);
      final decoded = convert.jsonDecode(pruned) as Map<String, dynamic>;

      final providers = decoded.values.whereType<Map<String, dynamic>>();
      var modelCount = 0;
      for (final provider in providers) {
        final models = provider['models'];
        expect(models, isA<Map<String, dynamic>>());
        for (final model in (models as Map<String, dynamic>).values) {
          modelCount++;
          final limit = model['limit'];
          if (limit is Map) {
            for (final entry in limit.entries) {
              expect(
                const {'context', 'input', 'output'}.contains(entry.key),
                isTrue,
                reason: 'unexpected limit key ${entry.key}',
              );
              expect(
                entry.value,
                isA<int>(),
                reason: 'limit ${entry.key} must be an int',
              );
              expect(entry.value as int, greaterThan(0));
            }
          }
          final modalities = model['modalities'];
          if (modalities is Map) {
            for (final key in const ['input', 'output']) {
              final values = modalities[key];
              if (values is List) {
                for (final v in values) {
                  expect(
                    const {
                      'text',
                      'image',
                      'audio',
                      'video',
                      'pdf',
                    }.contains(v.toString()),
                    isTrue,
                    reason: 'unexpected modality $v',
                  );
                }
              }
            }
          }
          expect(
            model['tool_call'],
            anyOf(isNull, isA<bool>()),
            reason: 'tool_call must be bool or absent',
          );
          expect(
            model['reasoning'],
            anyOf(isNull, isA<bool>()),
            reason: 'reasoning must be bool or absent',
          );
        }
      }
      expect(
        modelCount,
        greaterThan(1000),
        reason: 'snapshot looks truncated',
      );
    });

    test('known models expose type/input/output/abilities/token limits', () async {
      final raw = await rootBundle.loadString(
        'assets/model_catalog/models_dev.json',
      );
      final real = ModelCatalog.fromJsonString(pruneCatalogJson(raw));
      ModelCatalog.instance = real;

      // Provider-scoped lookups: the same id also exists on aggregators, the
      // ladder only guarantees the official entry for the hinted provider.
      final claude = real.lookup(providerId: 'anthropic', modelId: 'claude-sonnet-4-5')!;
      expect(claude.context, 200000);
      expect(claude.output, 64000);
      expect(claude.toolCall, isTrue);
      expect(claude.reasoning, isTrue);
      expect(claude.inputModalities, containsAll(['text', 'image', 'pdf']));

      final gemini = real.lookup(providerId: 'google', modelId: 'gemini-2.5-pro')!;
      expect(gemini.context, 1048576);
      expect(gemini.output, 65536);
      expect(
        gemini.inputModalities,
        containsAll(['text', 'image', 'audio', 'video', 'pdf']),
      );

      final gpt5 = real.lookup(providerId: 'openai', modelId: 'gpt-5')!;
      expect(gpt5.context, 400000);
      expect(gpt5.input, 272000);
      expect(gpt5.output, 128000);
      expect(gpt5.toolCall, isTrue);

      // End-to-end: whatever entry the global ladder resolves, the
      // projection the UI consumes carries its facts verbatim.
      final picked = real.lookup(modelId: 'gemini-2.5-pro')!;
      final info = ModelRegistry.infer(
        ModelInfo(id: 'gemini-2.5-pro', displayName: 'gemini-2.5-pro'),
      );
      expect(info.contextWindow, picked.context);
      expect(info.maxOutput, picked.output);
      final pickedMods = picked.inputModalities
          .map(ModelRegistry.modalityFromCatalogValue)
          .whereType<Modality>();
      expect(pickedMods, isNotEmpty);
      for (final mod in pickedMods) {
        expect(info.input, contains(mod), reason: 'missing $mod');
      }
      expect(info.abilities, containsAll([ModelAbility.tool]));
    });
  });
}
