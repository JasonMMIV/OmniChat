import 'package:OmniChat/core/services/model_catalog/model_catalog.dart';
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
      }
    }
  }
}
''';

void main() {
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
    test('keeps consumed fields and drops the rest', () {
      const raw = '''
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
}
