import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/model_catalog/model_catalog.dart';
import 'package:OmniChat/core/services/model_catalog/model_catalog_service.dart';
import 'package:flutter_test/flutter_test.dart';

const String _base = '''
{
  "opencode": {
    "api": "https://opencode.ai/inference/openai/v1",
    "models": {
      "minimax-m3": {"limit": {"context": 512000}, "reasoning": true},
      "zen-only": {"limit": {"context": 100000}}
    }
  },
  "opencode-go": {
    "api": "https://opencode.ai/inference/go/openai/v1",
    "models": {
      "minimax-m3": {"limit": {"context": 1000000}}
    }
  },
  "base-only": {
    "models": {"legacy": {"limit": {"context": 1234}}}
  },
  "openrouter": {
    "api": "https://openrouter.ai/api/v1",
    "models": {
      "openai/gpt-5.6-luna": {"limit": {"context": 1000000}}
    }
  }
}
''';

const String _overlay = '''
{
  "opencode": {
    "api": "https://opencode.ai/inference/openai/v1",
    "models": {
      "minimax-m3": {"limit": {"context": 600000}, "reasoning": true},
      "overlay-only": {"limit": {"context": 700000}}
    }
  },
  "opencode-go": {
    "api": "https://opencode.ai/inference/go/openai/v1",
    "models": {
      "go-only": {"limit": {"context": 800000}}
    }
  }
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ModelCatalog.instance = ModelCatalog.fromJsonString(_base);
  });

  tearDown(ModelCatalog.debugReset);

  group('OpenCode provider resolution', () {
    test('Zen and Go base URLs select distinct providers', () {
      expect(
        resolveCatalogProviderId(
          providerId: 'OpenCode Zen',
          baseUrl: 'https://opencode.ai/zen/v1',
          providerType: 'openai',
        ),
        'opencode',
      );
      expect(
        resolveCatalogProviderId(
          providerId: 'OpenCode Go',
          baseUrl: 'https://opencode.ai/zen/go/v1',
          providerType: 'openai',
        ),
        'opencode-go',
      );
    });

    test('host-only fallback stays on the Zen entry', () {
      expect(
        resolveCatalogProviderId(
          providerId: 'proxy',
          host: 'https://opencode.ai/zen/v1',
        ),
        'opencode',
      );
    });

    test('an explicit catalog id wins over the base URL path', () {
      expect(
        resolveCatalogProviderId(
          providerId: 'opencode-go',
          baseUrl: 'https://opencode.ai/zen/v1',
        ),
        'opencode-go',
      );
    });
  });

  group('catalog overlay merge', () {
    test('overlay models win and base-only entries survive', () {
      final merged = ModelCatalog.fromJsonString(
        mergeCatalogJson(_base, _overlay),
      );

      expect(
        merged.lookup(providerId: 'opencode', modelId: 'minimax-m3')!.context,
        600000,
      );
      // The Go entry is not in the overlay; the base entry must survive.
      expect(
        merged
            .lookup(providerId: 'opencode-go', modelId: 'minimax-m3')!
            .context,
        1000000,
      );
      expect(
        merged.lookup(providerId: 'opencode', modelId: 'overlay-only')!.context,
        700000,
      );
      expect(
        merged.lookup(providerId: 'opencode', modelId: 'zen-only')!.context,
        100000,
      );
      expect(merged.hasModel('legacy'), isTrue);
      // Non-OpenCode providers keep their own entry for a shared model id.
      expect(
        merged
            .lookup(providerId: 'openrouter', modelId: 'openai/gpt-5.6-luna')!
            .context,
        1000000,
      );
    });

    test('filter keeps only the requested provider entries', () {
      final filtered = filterCatalogProviders(_base, const <String>{
        'opencode',
        'opencode-go',
      });
      final decoded = jsonDecodeCatalog(filtered);

      expect(
        decoded.keys,
        unorderedEquals(<String>['opencode', 'opencode-go']),
      );
      expect(decoded.containsKey('base-only'), isFalse);
    });

    test('a missing Zen entry is aliased from the Go entry', () {
      final onlyGo = filterCatalogProviders(_base, const <String>{
        'opencode-go',
      });
      final aliased = ensureCatalogProviderAlias(
        onlyGo,
        alias: 'opencode',
        source: 'opencode-go',
      );
      final parsed = ModelCatalog.fromJsonString(aliased);

      expect(
        parsed.lookup(providerId: 'opencode', modelId: 'minimax-m3'),
        isNotNull,
      );
    });
  });

  test('the bundled OpenCode overlay resolves both presets', () async {
    // setUp installs the small fixture; clear it so ensureLoaded takes the
    // real bundled snapshot + overlay path.
    ModelCatalog.debugReset();
    final service = ModelCatalogService(
      cacheDirectoryLoader: () async => null,
      isWeb: true,
    );
    await service.ensureLoaded();

    final catalog = ModelCatalog.instance!;
    final zen = ProviderConfig.defaultsFor('OpenCode Zen');
    final go = ProviderConfig.defaultsFor('OpenCode Go');

    expect(zen.catalogProviderId, 'opencode');
    expect(go.catalogProviderId, 'opencode-go');
    expect(
      catalog.providerIds,
      containsAll(<String>['opencode', 'opencode-go']),
    );
    // `minimax-m3` is a stable id present in both OpenCode providers; the
    // fixture-based merge tests cover overlay priority without pinning
    // volatile upstream-only ids.
    expect(
      catalog.lookup(providerId: zen.catalogProviderId, modelId: 'minimax-m3'),
      isNotNull,
    );
    expect(
      catalog.lookup(providerId: go.catalogProviderId, modelId: 'minimax-m3'),
      isNotNull,
    );
  });
}
