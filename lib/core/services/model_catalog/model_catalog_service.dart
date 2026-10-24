// models.dev catalog lifetime: bundled snapshot, on-disk cache, on-demand
// refresh (plan batch 1 §6).
//
// Load order: memory → cache file → bundled asset. There is no startup
// network call and no 24h timer: refresh happens only when a provider/model is
// added or a provider model list is fetched. Failures are silent — the old
// catalog (or the snapshot) stays in use.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../utils/app_directories.dart';
import 'model_catalog.dart';

/// One HTTP result reduced to what the refresh path needs.
class CatalogHttpResponse {
  const CatalogHttpResponse({
    required this.statusCode,
    this.body = '',
    this.etag,
  });

  final int statusCode;
  final String body;
  final String? etag;
}

typedef CatalogFetcher = Future<CatalogHttpResponse> Function(
  Uri uri,
  Map<String, String> headers,
);

class ModelCatalogService {
  ModelCatalogService({
    Future<String> Function()? snapshotLoader,
    Future<Directory?> Function()? cacheDirectoryLoader,
    Future<SharedPreferences> Function()? prefsLoader,
    CatalogFetcher? fetcher,
    bool? isWeb,
  })  : _snapshotLoader = snapshotLoader ?? _loadBundledSnapshot,
        _cacheDirectoryLoader = cacheDirectoryLoader ?? _cacheDirectory,
        _prefsLoader = prefsLoader ?? SharedPreferences.getInstance,
        _fetcher = fetcher ?? _defaultFetcher,
        _isWeb = isWeb ?? kIsWeb;

  static final ModelCatalogService instance = ModelCatalogService();

  static const String snapshotAsset = 'assets/model_catalog/models_dev.json';
  static const String cacheFileName = 'model_catalog_v1.json';
  static const String fetchedAtPrefsKey = 'model_catalog_fetched_at_v1';
  static const String etagPrefsKey = 'model_catalog_etag_v1';
  static const String sourceUrl = 'https://models.dev/api.json';
  static const Duration requestTimeout = Duration(seconds: 15);

  final Future<String> Function() _snapshotLoader;
  final Future<Directory?> Function() _cacheDirectoryLoader;
  final Future<SharedPreferences> Function() _prefsLoader;
  final CatalogFetcher _fetcher;
  final bool _isWeb;

  Future<void>? _loadInflight;
  Future<ModelCatalog?>? _refreshInflight;
  bool _loaded = false;

  /// Whether any catalog (cache, snapshot, or a refresh) is loaded.
  bool get isLoaded => _loaded && ModelCatalog.instance != null;

  /// Load the catalog once: memory → cache file → bundled snapshot.
  ///
  /// Safe to call from multiple places; concurrent calls share one load.
  Future<void> ensureLoaded() {
    if (_loaded && ModelCatalog.instance != null) {
      return Future<void>.value();
    }
    return _loadInflight ??= _load().whenComplete(() => _loadInflight = null);
  }

  Future<void> _load() async {
    if (ModelCatalog.instance != null) {
      _loaded = true;
      return;
    }
    if (!_isWeb) {
      final cached = await _readCacheFile();
      if (cached != null) {
        if (await _installParsed(cached)) {
          _loaded = true;
          return;
        }
        // Corrupt or schema-incompatible cache: drop it and use the bundled
        // snapshot (plan batch 1 §6.5).
        await _deleteCacheFile();
      }
    }
    try {
      final snapshot = await _snapshotLoader();
      if (await _installParsed(snapshot)) _loaded = true;
    } catch (_) {
      // A missing/broken asset leaves the catalog unset; callers fall back to
      // the regex/1M rules exactly as before this feature existed.
    }
  }

  Future<String?> _readCacheFile() async {
    try {
      final dir = await _cacheDirectoryLoader();
      if (dir == null) return null;
      final file = File('${dir.path}/$cacheFileName');
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<bool> _installParsed(String json) async {
    try {
      final catalog = await compute(_parseCatalog, json);
      if (catalog.providerCount == 0) return false;
      ModelCatalog.instance = catalog;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Refresh when the last successful fetch is older than [days].
  ///
  /// Returns without a request when fresh or when the fetch fails.
  Future<ModelCatalog?> refreshIfStale({int days = 30, http.Client? client}) async {
    final fetchedAt = await _readFetchedAt();
    final age = DateTime.now().millisecondsSinceEpoch - fetchedAt;
    if (fetchedAt > 0 && age < days * 24 * 60 * 60 * 1000) return null;
    return refresh(client: client);
  }

  /// Make sure the catalog knows [apiModelId], fetching once when it does not.
  ///
  /// A catalog hit returns immediately — no request.
  Future<ModelCatalog?> refreshForModel(
    String apiModelId, {
    http.Client? client,
  }) async {
    final catalog = ModelCatalog.instance;
    if (catalog != null && catalog.hasModel(apiModelId)) return null;
    return refresh(client: client);
  }

  /// Force one refresh. Concurrent callers share the in-flight request.
  ///
  /// [client] lets a provider-configured proxy carry the request; it is not
  /// closed here (the caller owns it).
  Future<ModelCatalog?> refresh({http.Client? client}) {
    return _refreshInflight ??=
        _refresh(client).whenComplete(() => _refreshInflight = null);
  }

  Future<ModelCatalog?> _refresh(http.Client? client) async {
    final prefs = await _prefsLoader();
    final etag = prefs.getString(etagPrefsKey);
    final headers = <String, String>{'Accept': 'application/json'};
    if (etag != null && etag.trim().isNotEmpty) {
      headers['If-None-Match'] = etag.trim();
    }
    CatalogHttpResponse response;
    try {
      response = await _fetch(Uri.parse(sourceUrl), headers, client)
          .timeout(requestTimeout);
    } catch (_) {
      return null;
    }

    if (response.statusCode == 304) {
      await prefs.setInt(
        fetchedAtPrefsKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      return null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) return null;

    String pruned;
    try {
      // Pruning decodes the multi-megabyte upstream payload and re-encodes
      // the reduced map; keep it off the UI isolate just like the parse in
      // `_installParsed` (compute runs inline on web, which has no isolates).
      pruned = await compute(pruneCatalogJson, response.body);
    } catch (_) {
      return null;
    }
    final installed = await _installParsed(pruned);
    if (!installed) return null;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (!_isWeb) await _writeCacheFile(pruned);
    await prefs.setInt(fetchedAtPrefsKey, now);
    final newEtag = response.etag;
    if (newEtag != null && newEtag.trim().isNotEmpty) {
      await prefs.setString(etagPrefsKey, newEtag.trim());
    } else if (etag != null) {
      await prefs.remove(etagPrefsKey);
    }
    return ModelCatalog.instance;
  }

  Future<CatalogHttpResponse> _fetch(
    Uri uri,
    Map<String, String> headers,
    http.Client? client,
  ) async {
    if (client == null) return _fetcher(uri, headers);
    final response = await client.get(uri, headers: headers);
    return CatalogHttpResponse(
      statusCode: response.statusCode,
      body: response.body,
      etag: response.headers['etag'],
    );
  }

  Future<void> _deleteCacheFile() async {
    try {
      final dir = await _cacheDirectoryLoader();
      if (dir == null) return;
      final file = File('${dir.path}/$cacheFileName');
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _writeCacheFile(String contents) async {
    try {
      final dir = await _cacheDirectoryLoader();
      if (dir == null) return;
      await dir.create(recursive: true);
      final target = File('${dir.path}/$cacheFileName');
      final temp = File('${dir.path}/$cacheFileName.tmp');
      await temp.writeAsString(contents, flush: true);
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
    } catch (_) {
      // Cache is an optimization only.
    }
  }

  Future<int> _readFetchedAt() async {
    try {
      final prefs = await _prefsLoader();
      return prefs.getInt(fetchedAtPrefsKey) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Test/debug helper: forget the loaded state (does not touch the disk).
  @visibleForTesting
  void debugReset() {
    _loaded = false;
    _loadInflight = null;
    _refreshInflight = null;
    ModelCatalog.debugReset();
  }

  static Future<String> _loadBundledSnapshot() async {
    final data = await rootBundle.load(snapshotAsset);
    return utf8.decode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      allowMalformed: true,
    );
  }

  static Future<Directory?> _cacheDirectory() async {
    try {
      return await AppDirectories.getCacheDirectory();
    } catch (_) {
      return null;
    }
  }

  static Future<CatalogHttpResponse> _defaultFetcher(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final client = http.Client();
    try {
      final response = await client.get(uri, headers: headers);
      return CatalogHttpResponse(
        statusCode: response.statusCode,
        body: response.body,
        etag: response.headers['etag'],
      );
    } finally {
      client.close();
    }
  }
}

ModelCatalog _parseCatalog(String json) => ModelCatalog.fromJsonString(json);
