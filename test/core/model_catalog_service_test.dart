import 'dart:io';

import 'package:OmniChat/core/services/model_catalog/model_catalog.dart';
import 'package:OmniChat/core/services/model_catalog/model_catalog_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _fixture = '''
{
  "openai": {
    "models": {
      "gpt-5.6-luna": {
        "limit": {"context": 400000, "input": 272000, "output": 128000},
        "modalities": {"input": ["text", "image"], "output": ["text"]},
        "tool_call": true,
        "reasoning": true
      }
    }
  },
  "opencode": {
    "api": "https://opencode.ai/inference/openai/v1",
    "models": {
      "minimax-m3": {"limit": {"context": 100000}, "reasoning": true}
    }
  },
  "base-only": {
    "models": {"legacy": {"limit": {"context": 1234}}}
  }
}
''';

const String _overlayFixture = '''
{
  "opencode": {
    "api": "https://opencode.ai/inference/openai/v1",
    "models": {
      "minimax-m3": {"limit": {"context": 512000}, "reasoning": true},
      "overlay-only": {"limit": {"context": 700000}}
    }
  }
}
''';

const String _openCodeFetchFixture = '''
{
  "opencode": {
    "models": {
      "remote-only": {"limit": {"context": 777000}}
    }
  }
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory cacheDir;
  late int fetchCount;
  late int openCodeFetchCount;
  late CatalogHttpResponse Function() nextResponse;
  late CatalogHttpResponse Function() nextOpenCodeResponse;

  setUp(() async {
    cacheDir = await Directory.systemTemp.createTemp('catalog_test_');
    fetchCount = 0;
    openCodeFetchCount = 0;
    nextResponse = () => const CatalogHttpResponse(
      statusCode: 200,
      body: _fixture,
      etag: '"v1"',
    );
    nextOpenCodeResponse = () => const CatalogHttpResponse(
      statusCode: 200,
      body: _overlayFixture,
      etag: '"o1"',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ModelCatalog.debugReset();
  });

  tearDown(() async {
    ModelCatalogService.instance.debugReset();
    try {
      await cacheDir.delete(recursive: true);
    } catch (_) {}
  });

  ModelCatalogService buildService({
    Future<String> Function()? snapshotLoader,
    Future<String> Function()? openCodeSnapshotLoader,
    Future<Directory?> Function()? cacheDirectoryLoader,
  }) {
    return ModelCatalogService(
      snapshotLoader: snapshotLoader ?? () async => _fixture,
      openCodeSnapshotLoader:
          openCodeSnapshotLoader ?? () async => _overlayFixture,
      cacheDirectoryLoader: cacheDirectoryLoader ?? () async => cacheDir,
      prefsLoader: SharedPreferences.getInstance,
      isWeb: false,
      fetcher: (uri, headers) async {
        fetchCount++;
        return nextResponse();
      },
      openCodeFetcher: (uri, headers) async {
        openCodeFetchCount++;
        return nextOpenCodeResponse();
      },
    );
  }

  test('bundled snapshot asset is registered in pubspec and parses', () async {
    final service = ModelCatalogService(
      cacheDirectoryLoader: () async => null,
      prefsLoader: SharedPreferences.getInstance,
      isWeb: true,
      fetcher: (uri, headers) async {
        fetchCount++;
        return const CatalogHttpResponse(statusCode: 304);
      },
    );

    await service.ensureLoaded();

    expect(service.isLoaded, isTrue);
    // The real models.dev snapshot is large; a handful of providers is proof
    // the asset was bundled and decoded, not an empty fixture.
    expect(ModelCatalog.instance!.providerCount, greaterThan(100));
    expect(ModelCatalog.instance!.modelCount, greaterThan(1000));
    expect(fetchCount, 0);
  });

  test('loads the bundled snapshot when the cache file is corrupt', () async {
    await File(
      '${cacheDir.path}/${ModelCatalogService.cacheFileName}',
    ).writeAsString('{not json');
    final service = buildService();

    await service.ensureLoaded();

    expect(service.isLoaded, isTrue);
    expect(ModelCatalog.instance!.hasModel('gpt-5.6-luna'), isTrue);
    expect(fetchCount, 0);
    expect(
      File(
        '${cacheDir.path}/${ModelCatalogService.cacheFileName}',
      ).existsSync(),
      isFalse,
    );
  });

  test('uses a valid cache file ahead of the snapshot', () async {
    await File(
      '${cacheDir.path}/${ModelCatalogService.cacheFileName}',
    ).writeAsString('''
        {"openai": {"models": {"cached-model": {"limit": {"context": 111}}}}}
        ''');
    final service = buildService();

    await service.ensureLoaded();

    expect(ModelCatalog.instance!.hasModel('cached-model'), isTrue);
    expect(ModelCatalog.instance!.hasModel('gpt-5.6-luna'), isFalse);
  });

  test('304 updates the timestamp only, without rewriting the cache', () async {
    final cacheFile = File(
      '${cacheDir.path}/${ModelCatalogService.cacheFileName}',
    );
    await cacheFile.writeAsString(_fixture);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(ModelCatalogService.etagPrefsKey, '"old"');
    await prefs.setInt(ModelCatalogService.fetchedAtPrefsKey, 1);
    nextResponse = () => const CatalogHttpResponse(statusCode: 304);
    final service = buildService();

    final result = await service.refresh();

    expect(result, isNull);
    expect(await cacheFile.readAsString(), _fixture);
    expect(prefs.getInt(ModelCatalogService.fetchedAtPrefsKey), greaterThan(1));
    expect(prefs.getString(ModelCatalogService.etagPrefsKey), '"old"');
  });

  test('200 prunes, writes the cache atomically and stores the ETag', () async {
    final service = buildService();

    final catalog = await service.refresh();

    expect(catalog, isNotNull);
    final cacheFile = File(
      '${cacheDir.path}/${ModelCatalogService.cacheFileName}',
    );
    expect(await cacheFile.exists(), isTrue);
    final written = await cacheFile.readAsString();
    expect(written.contains('"gpt-5.6-luna"'), isTrue);
    expect(
      File(
        '${cacheDir.path}/${ModelCatalogService.cacheFileName}.tmp',
      ).existsSync(),
      isFalse,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ModelCatalogService.etagPrefsKey), '"v1"');
    expect(prefs.getInt(ModelCatalogService.fetchedAtPrefsKey), isNotNull);
  });

  test('single-flight: concurrent refreshes share one request', () async {
    final service = buildService();

    await Future.wait([
      service.refresh(),
      service.refresh(),
      service.refresh(),
    ]);

    expect(fetchCount, 1);
  });

  test('refreshForModel returns on a catalog hit without a request', () async {
    final service = buildService();
    await service.ensureLoaded();

    final result = await service.refreshForModel('gpt-5.6-luna');

    expect(result, isNull);
    expect(fetchCount, 0);
  });

  test('refreshForModel fetches on a miss', () async {
    final service = buildService();
    await service.ensureLoaded();

    final result = await service.refreshForModel('brand-new-model');

    expect(result, isNotNull);
    expect(fetchCount, 1);
  });

  test('refreshIfStale skips a fresh catalog', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      ModelCatalogService.fetchedAtPrefsKey,
      DateTime.now().millisecondsSinceEpoch,
    );
    final service = buildService();

    final result = await service.refreshIfStale(days: 30);

    expect(result, isNull);
    expect(fetchCount, 0);
  });

  test('refreshIfStale fetches an old catalog', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(ModelCatalogService.fetchedAtPrefsKey, 1);
    final service = buildService();

    final result = await service.refreshIfStale(days: 30);

    expect(result, isNotNull);
    expect(fetchCount, 1);
  });

  test('network failure keeps the previously loaded catalog', () async {
    final service = buildService();
    await service.ensureLoaded();
    nextResponse = () => const CatalogHttpResponse(statusCode: 500);

    final result = await service.refresh();

    expect(result, isNull);
    expect(ModelCatalog.instance!.hasModel('gpt-5.6-luna'), isTrue);
  });

  test('malformed 200 payload keeps the previously loaded catalog', () async {
    final service = buildService();
    await service.ensureLoaded();
    // Pruning now runs in an isolate; a non-map payload must still surface as
    // a silent null rather than propagating across the isolate boundary.
    nextResponse = () =>
        const CatalogHttpResponse(statusCode: 200, body: '[]', etag: '"v2"');

    final result = await service.refresh();

    expect(result, isNull);
    expect(ModelCatalog.instance!.hasModel('gpt-5.6-luna'), isTrue);
  });

  test(
    'ensureLoaded merges the OpenCode overlay over the base catalog',
    () async {
      final service = buildService();

      await service.ensureLoaded();

      final catalog = ModelCatalog.instance!;
      expect(
        catalog.lookup(providerId: 'opencode', modelId: 'minimax-m3')!.context,
        512000,
      );
      expect(
        catalog
            .lookup(providerId: 'opencode', modelId: 'overlay-only')!
            .context,
        700000,
      );
      expect(catalog.hasModel('legacy'), isTrue);
      expect(openCodeFetchCount, 0);
    },
  );

  test('OpenCode overlay cache wins over its bundled snapshot', () async {
    await File(
      '${cacheDir.path}/${ModelCatalogService.openCodeCacheFileName}',
    ).writeAsString('''
      {"opencode":{"models":{"minimax-m3":{"limit":{"context":999999}}}}}
      ''');
    final service = buildService();

    await service.ensureLoaded();

    expect(
      ModelCatalog.instance!
          .lookup(providerId: 'opencode', modelId: 'minimax-m3')!
          .context,
      999999,
    );
  });

  test('refreshOpenCodeIfStale fetches and stores the overlay', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(ModelCatalogService.openCodeFetchedAtPrefsKey, 1);
    final service = buildService();
    await service.ensureLoaded();
    nextOpenCodeResponse = () => const CatalogHttpResponse(
      statusCode: 200,
      body: _openCodeFetchFixture,
      etag: '"o2"',
    );

    final result = await service.refreshOpenCodeIfStale();

    expect(result, isNotNull);
    expect(openCodeFetchCount, 1);
    expect(
      ModelCatalog.instance!
          .lookup(providerId: 'opencode', modelId: 'remote-only')!
          .context,
      777000,
    );
    final overlayFile = File(
      '${cacheDir.path}/${ModelCatalogService.openCodeCacheFileName}',
    );
    expect(overlayFile.existsSync(), isTrue);
    expect(prefs.getString(ModelCatalogService.openCodeEtagPrefsKey), '"o2"');
  });

  test(
    'does not install overlay-only when the base catalog is missing',
    () async {
      final service = buildService(snapshotLoader: () async => '');

      await service.ensureLoaded();

      expect(service.isLoaded, isFalse);
      expect(ModelCatalog.instance, isNull);
    },
  );

  test('overlay failure keeps the previously loaded overlay', () async {
    final service = buildService();
    await service.ensureLoaded();
    nextOpenCodeResponse = () => const CatalogHttpResponse(statusCode: 500);

    final result = await service.refreshOpenCode();

    expect(result, isNull);
    expect(
      ModelCatalog.instance!.lookup(
        providerId: 'opencode',
        modelId: 'overlay-only',
      ),
      isNotNull,
    );
  });

  test('base refresh keeps the OpenCode overlay priority', () async {
    final service = buildService();
    await service.ensureLoaded();
    nextResponse = () => const CatalogHttpResponse(
      statusCode: 200,
      body: '{"opencode":{"models":{"minimax-m3":{"limit":{"context":123}}}}}',
      etag: '"v2"',
    );

    await service.refresh();

    expect(
      ModelCatalog.instance!
          .lookup(providerId: 'opencode', modelId: 'minimax-m3')!
          .context,
      512000,
    );
  });
}
