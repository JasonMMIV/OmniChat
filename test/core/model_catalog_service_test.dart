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
  }
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory cacheDir;
  late int fetchCount;
  late CatalogHttpResponse Function() nextResponse;

  setUp(() async {
    cacheDir = await Directory.systemTemp.createTemp('catalog_test_');
    fetchCount = 0;
    nextResponse = () => const CatalogHttpResponse(
          statusCode: 200,
          body: _fixture,
          etag: '"v1"',
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
    Future<Directory?> Function()? cacheDirectoryLoader,
  }) {
    return ModelCatalogService(
      snapshotLoader: snapshotLoader ?? () async => _fixture,
      cacheDirectoryLoader: cacheDirectoryLoader ?? () async => cacheDir,
      prefsLoader: SharedPreferences.getInstance,
      isWeb: false,
      fetcher: (uri, headers) async {
        fetchCount++;
        return nextResponse();
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
    await File('${cacheDir.path}/${ModelCatalogService.cacheFileName}')
        .writeAsString('{not json');
    final service = buildService();

    await service.ensureLoaded();

    expect(service.isLoaded, isTrue);
    expect(ModelCatalog.instance!.hasModel('gpt-5.6-luna'), isTrue);
    expect(fetchCount, 0);
    expect(
      File('${cacheDir.path}/${ModelCatalogService.cacheFileName}').existsSync(),
      isFalse,
    );
  });

  test('uses a valid cache file ahead of the snapshot', () async {
    await File('${cacheDir.path}/${ModelCatalogService.cacheFileName}')
        .writeAsString('''
        {"openai": {"models": {"cached-model": {"limit": {"context": 111}}}}}
        ''');
    final service = buildService();

    await service.ensureLoaded();

    expect(ModelCatalog.instance!.hasModel('cached-model'), isTrue);
    expect(ModelCatalog.instance!.hasModel('gpt-5.6-luna'), isFalse);
  });

  test('304 updates the timestamp only, without rewriting the cache', () async {
    final cacheFile =
        File('${cacheDir.path}/${ModelCatalogService.cacheFileName}');
    await cacheFile.writeAsString(_fixture);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(ModelCatalogService.etagPrefsKey, '"old"');
    await prefs.setInt(ModelCatalogService.fetchedAtPrefsKey, 1);
    nextResponse = () => const CatalogHttpResponse(statusCode: 304);
    final service = buildService();

    final result = await service.refresh();

    expect(result, isNull);
    expect(await cacheFile.readAsString(), _fixture);
    expect(
      prefs.getInt(ModelCatalogService.fetchedAtPrefsKey),
      greaterThan(1),
    );
    expect(prefs.getString(ModelCatalogService.etagPrefsKey), '"old"');
  });

  test('200 prunes, writes the cache atomically and stores the ETag', () async {
    final service = buildService();

    final catalog = await service.refresh();

    expect(catalog, isNotNull);
    final cacheFile =
        File('${cacheDir.path}/${ModelCatalogService.cacheFileName}');
    expect(await cacheFile.exists(), isTrue);
    final written = await cacheFile.readAsString();
    expect(written.contains('"gpt-5.6-luna"'), isTrue);
    expect(
      File('${cacheDir.path}/${ModelCatalogService.cacheFileName}.tmp')
          .existsSync(),
      isFalse,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ModelCatalogService.etagPrefsKey), '"v1"');
    expect(
      prefs.getInt(ModelCatalogService.fetchedAtPrefsKey),
      isNotNull,
    );
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
    nextResponse = () => const CatalogHttpResponse(
          statusCode: 200,
          body: '[]',
          etag: '"v2"',
        );

    final result = await service.refresh();

    expect(result, isNull);
    expect(ModelCatalog.instance!.hasModel('gpt-5.6-luna'), isTrue);
  });
}
