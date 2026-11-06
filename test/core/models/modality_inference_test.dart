// Multimodal capability layer tests (plan Phase A1/A2).
//
// The catalog already publishes audio/video/pdf input modalities; these tests
// pin that `CatalogModel` keeps them, that `ModelRegistry` projects them into
// `Modality`, and that the single override parser preserves them instead of
// collapsing unknown values to `text`.

import 'package:OmniChat/core/providers/model_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/model_catalog/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

const String _fixture = '''
{
  "google": {
    "api": "https://generativelanguage.googleapis.com/v1beta",
    "models": {
      "gemini-4-pro": {
        "limit": {"context": 1000000},
        "modalities": {
          "input": ["text", "image", "audio", "video", "pdf"],
          "output": ["text", "audio"]
        },
        "tool_call": true,
        "reasoning": true
      }
    }
  },
  "anthropic": {
    "api": "https://api.anthropic.com/v1",
    "models": {
      "claude-fable-5": {
        "limit": {"context": 200000},
        "modalities": {"input": ["text", "image", "pdf"], "output": ["text"]}
      }
    }
  }
}
''';

void main() {
  setUp(() {
    ModelCatalog.loadFromJsonString(_fixture);
  });

  tearDown(ModelCatalog.debugReset);

  test('catalog keeps the raw input modality set', () {
    final model = ModelCatalog.instance!.lookup(modelId: 'gemini-4-pro')!;
    expect(
      model.inputModalities,
      containsAll(<String>['text', 'image', 'audio', 'video', 'pdf']),
    );
  });

  test('registry projects audio/video/pdf from the catalog', () {
    final info = ModelRegistry.infer(
      ModelInfo(id: 'gemini-4-pro', displayName: 'gemini-4-pro'),
    );
    expect(info.input, containsAll(<Modality>[
      Modality.text,
      Modality.image,
      Modality.audio,
      Modality.video,
      Modality.pdf,
    ]));
    // Output audio must NOT be projected: it would imply native chat audio
    // output, which no transport supports.
    expect(info.output, isNot(contains(Modality.audio)));
  });

  test('registry projection is provider-scoped for aliases', () {
    final cfg = ProviderConfig(
      id: 'my-anthropic',
      enabled: true,
      name: 'my-anthropic',
      apiKey: '',
      baseUrl: 'https://api.anthropic.com/v1',
      providerType: ProviderKind.claude,
      models: const ['claude-fable-5'],
    );
    final info = ModelRegistry.inferForProvider(
      ModelInfo(id: 'claude-fable-5', displayName: 'claude-fable-5'),
      cfg,
    );
    expect(info.input, contains(Modality.pdf));
    expect(info.input, isNot(contains(Modality.audio)));
  });

  test('regex fallback fills audio/pdf/video on a catalog miss', () {
    final audio = ModelRegistry.infer(
      ModelInfo(id: 'qwen2.5-omni-plus', displayName: 'qwen'),
    );
    expect(audio.input, contains(Modality.audio));

    final claude = ModelRegistry.infer(
      ModelInfo(id: 'claude-sonnet-9', displayName: 'claude'),
    );
    expect(claude.input, contains(Modality.pdf));

    final gemini = ModelRegistry.infer(
      ModelInfo(id: 'gemini-9-flash', displayName: 'gemini'),
    );
    expect(gemini.input, contains(Modality.pdf));
    expect(gemini.input, contains(Modality.video));
  });

  test('applyOverride preserves audio/video/pdf and drops unknown values', () {
    final base = ModelInfo(
      id: 'm',
      displayName: 'm',
      input: const [Modality.text],
      output: const [Modality.text],
    );
    final info = ModelRegistry.applyOverride(base, const <String, dynamic>{
      'input': ['text', 'audio', 'pdf', 'bogus'],
      'output': ['text'],
      'abilities': ['tool', 'reasoning'],
    });
    expect(info.input, <Modality>[Modality.text, Modality.audio, Modality.pdf]);
    expect(info.input, isNot(contains(Modality.image)));
    expect(info.abilities, containsAll(<ModelAbility>[
      ModelAbility.tool,
      ModelAbility.reasoning,
    ]));
  });

  test('legacy override keeps newly projected modalities', () {
    final base = ModelInfo(
      id: 'm',
      displayName: 'm',
      input: const [
        Modality.text,
        Modality.image,
        Modality.audio,
        Modality.pdf,
      ],
    );
    // Pre-multimodal save: input: ['text','image'] only.
    final legacy = ModelRegistry.applyOverride(base, const <String, dynamic>{
      'input': ['text', 'image'],
    });
    expect(legacy.input, containsAll(<Modality>[
      Modality.text,
      Modality.image,
      Modality.audio,
      Modality.pdf,
    ]));

    // Versioned save: explicit removal is respected.
    final current = ModelRegistry.applyOverride(base, const <String, dynamic>{
      'input': ['text', 'image'],
      'inputV': ModelRegistry.inputOverrideVersion,
    });
    expect(current.input, <Modality>[Modality.text, Modality.image]);
  });

  test('legacy override survives a model-detail load/save round trip', () {
    final base = ModelInfo(
      id: 'm',
      displayName: 'm',
      input: const [
        Modality.text,
        Modality.image,
        Modality.audio,
        Modality.pdf,
      ],
    );
    // 1. Load: migration adds the new dimensions.
    final loaded = ModelRegistry.applyOverride(base, const <String, dynamic>{
      'input': ['text', 'image'],
    });
    expect(loaded.input, containsAll(<Modality>[Modality.audio, Modality.pdf]));

    // 2. Save: the sheet writes the migrated list + inputV:2.
    final saved = <String, dynamic>{
      'input': loaded.input.map(ModelRegistry.modalityToCatalogValue).toList(),
      'inputV': ModelRegistry.inputOverrideVersion,
    };

    // 3. Reopen: the explicit list is now authoritative.
    final reopened = ModelRegistry.applyOverride(base, saved);
    expect(reopened.input, loaded.input);
  });

  test('modality values map 1:1 to catalog strings', () {
    for (final modality in Modality.values) {
      expect(
        ModelRegistry.modalityFromCatalogValue(
          ModelRegistry.modalityToCatalogValue(modality),
        ),
        modality,
      );
    }
    expect(ModelRegistry.modalityFromCatalogValue('nope'), isNull);
    expect(ModelRegistry.parseModalities(const ['nope']), isNull);
  });
}
