// models.dev catalog lifetime: bundled snapshot, on-disk cache, on-demand
// refresh (plan batch 1 §6).
//
// Load order: memory → cache file → bundled asset. There is no startup
// network call and no 24h timer: refresh happens only when a provider/model is
// added or a provider model list is fetched. Failures are silent — the old
// catalog (or the snapshot) stays in use.
//
// OpenCode is layered on top: `models.opencode.ai/api.json` is a
// models.dev-compatible payload with `opencode` / `opencode-go` providers.
// Only those provider entries are kept as an overlay so OpenCode's Console
// models win over the global models.dev snapshot without replacing it.
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

typedef CatalogFetcher =
    Future<CatalogHttpResponse> Function(Uri uri, Map<String, String> headers);

class ModelCatalogService {
  ModelCatalogService({
    Future<String> Function()? snapshotLoader,
    Future<String> Function()? openCodeSnapshotLoader,
    Future<Directory?> Function()? cacheDirectoryLoader,
    Future<SharedPreferences> Function()? prefsLoader,
    CatalogFetcher? fetcher,
    CatalogFetcher? openCodeFetcher,
    bool? isWeb,
  }) : _snapshotLoader = snapshotLoader ?? _loadBundledSnapshot,
       _openCodeSnapshotLoader =
           openCodeSnapshotLoader ?? _loadBundledOpenCodeSnapshot,
       _cacheDirectoryLoader = cacheDirectoryLoader ?? _cacheDirectory,
       _prefsLoader = prefsLoader ?? SharedPreferences.getInstance,
       _fetcher = fetcher ?? _defaultFetcher,
       _openCodeFetcher = openCodeFetcher ?? _defaultFetcher,
       _isWeb = isWeb ?? kIsWeb;

  static final ModelCatalogService instance = ModelCatalogService();

  static const String snapshotAsset = 'assets/model_catalog/models_dev.json';
  static const String openCodeSnapshotAsset =
      'assets/model_catalog/opencode.json';
  static const String cacheFileName = 'model_catalog_v1.json';
  static const String openCodeCacheFileName = 'opencode_catalog_v1.json';
  static const String fetchedAtPrefsKey = 'model_catalog_fetched_at_v1';
  static const String openCodeFetchedAtPrefsKey =
      'opencode_catalog_fetched_at_v1';
  static const String etagPrefsKey = 'model_catalog_etag_v1';
  static const String openCodeEtagPrefsKey = 'opencode_catalog_etag_v1';
  static const String sourceUrl = 'https://models.dev/api.json';
  static const String openCodeSourceUrl = 'https://models.opencode.ai/api.json';
  static const Set<String> openCodeProviderIds = <String>{
    'opencode',
    'opencode-go',
  };
  static const Duration requestTimeout = Duration(seconds: 15);

  final Future<String> Function() _snapshotLoader;
  final Future<String> Function() _openCodeSnapshotLoader;
  final Future<Directory?> Function() _cacheDirectoryLoader;
  final Future<SharedPreferences> Function() _prefsLoader;
  final CatalogFetcher _fetcher;
  final CatalogFetcher _openCodeFetcher;
  final bool _isWeb;

  Future<void>? _loadInflight;
  Future<ModelCatalog?>? _refreshInflight;
  Future<ModelCatalog?>? _openCodeRefreshInflight;
  bool _loaded = false;
  String? _baseJson;
  String? _overlayJson;

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
    _baseJson = await _loadSource(
      fileName: cacheFileName,
      snapshotLoader: _snapshotLoader,
    );
    if (_baseJson == null) return;
    // Install the base before touching the overlay: a slow/missing overlay
    // must never prevent the global catalog from becoming available.
    if (!await _tryInstall(_baseJson!)) {
      _baseJson = null;
      return;
    }
    _loaded = true;

    _overlayJson = await _loadSource(
      fileName: openCodeCacheFileName,
      snapshotLoader: _openCodeSnapshotLoader,
    );
    if (_overlayJson == null) return;
    if (!await _installOverlay(_overlayJson!)) {
      _overlayJson = null;
    }
  }

  Future<String?> _loadSource({
    required String fileName,
    required Future<String> Function() snapshotLoader,
  }) async {
    if (!_isWeb) {
      final cached = await _readCacheFile(fileName);
      if (cached != null) {
        if (await _canParseCatalog(cached)) return cached;
        // Corrupt or schema-incompatible cache: drop it and use the bundled
        // snapshot (plan batch 1 §6.5).
        await _deleteCacheFile(fileName);
      }
    }
    try {
      return await snapshotLoader();
    } catch (_) {
      return null;
    }
  }

  Future<bool> _canParseCatalog(String json) async {
    try {
      final catalog = await compute(_parseCatalog, json);
      return catalog.providerCount > 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _installMerged() async {
    try {
      final merged = _mergedJson();
      if (merged == null) return false;
      return await _tryInstall(merged);
    } catch (_) {
      return false;
    }
  }

  String? _mergedJson() {
    // A base catalog is mandatory. Without it an overlay-only catalog would
    // contain just `opencode`/`opencode-go` and silently degrade every other
    // provider's capability lookup.
    final base = _baseJson;
    if (base == null) return null;
    final overlay = _overlayJson;
    return overlay == null ? base : mergeCatalogJson(base, overlay);
  }

  Future<bool> _tryInstall(String json) async {
    try {
      final catalog = await compute(_parseCatalog, json);
      if (catalog.providerCount == 0) return false;
      ModelCatalog.instance = catalog;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _installBase(String json) async {
    final previous = _baseJson;
    _baseJson = json;
    if (await _installMerged()) return true;
    _baseJson = previous;
    return false;
  }

  Future<bool> _installOverlay(String json) async {
    final previous = _overlayJson;
    _overlayJson = json;
    if (await _installMerged()) return true;
    _overlayJson = previous;
    return false;
  }

  /// Refresh when the last successful fetch is older than [days].
  ///
  /// Returns without a request when fresh or when the fetch fails.
  Future<ModelCatalog?> refreshIfStale({
    int days = 30,
    http.Client? client,
  }) async {
    final fetchedAt = await _readFetchedAt(fetchedAtPrefsKey);
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

  /// Refresh the OpenCode overlay when it is older than [days] (default 1).
  Future<ModelCatalog?> refreshOpenCodeIfStale({
    int days = 1,
    http.Client? client,
  }) async {
    final fetchedAt = await _readFetchedAt(openCodeFetchedAtPrefsKey);
    final age = DateTime.now().millisecondsSinceEpoch - fetchedAt;
    if (fetchedAt > 0 && age < days * 24 * 60 * 60 * 1000) return null;
    return refreshOpenCode(client: client);
  }

  /// Refresh the OpenCode overlay when [apiModelId] is unknown for the
  /// provider-specific view. A hit returns immediately.
  Future<ModelCatalog?> refreshOpenCodeForModel(
    String apiModelId, {
    String? providerId,
    String? host,
    http.Client? client,
  }) async {
    final catalog = ModelCatalog.instance;
    if (catalog != null &&
        catalog.lookup(
              providerId: providerId,
              host: host,
              modelId: apiModelId,
            ) !=
            null) {
      return null;
    }
    return refreshOpenCode(client: client);
  }

  /// Force one refresh. Concurrent callers share the in-flight request.
  ///
  /// [client] lets a provider-configured proxy carry the request; it is not
  /// closed here (the caller owns it).
  Future<ModelCatalog?> refresh({http.Client? client}) {
    return _refreshInflight ??= _refresh(
      client,
    ).whenComplete(() => _refreshInflight = null);
  }

  /// Force one OpenCode overlay refresh.
  Future<ModelCatalog?> refreshOpenCode({http.Client? client}) {
    return _openCodeRefreshInflight ??= _refreshOpenCode(
      client,
    ).whenComplete(() => _openCodeRefreshInflight = null);
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
      response = await _fetch(
        Uri.parse(sourceUrl),
        headers,
        client,
      ).timeout(requestTimeout);
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
      // `_tryInstall` (compute runs inline on web, which has no isolates).
      pruned = await compute(pruneCatalogJson, response.body);
    } catch (_) {
      return null;
    }
    final installed = await _installBase(pruned);
    if (!installed) return null;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (!_isWeb) await _writeCacheFile(cacheFileName, pruned);
    await prefs.setInt(fetchedAtPrefsKey, now);
    final newEtag = response.etag;
    if (newEtag != null && newEtag.trim().isNotEmpty) {
      await prefs.setString(etagPrefsKey, newEtag.trim());
    } else if (etag != null) {
      await prefs.remove(etagPrefsKey);
    }
    return ModelCatalog.instance;
  }

  Future<ModelCatalog?> _refreshOpenCode(http.Client? client) async {
    final prefs = await _prefsLoader();
    final etag = prefs.getString(openCodeEtagPrefsKey);
    final headers = <String, String>{'Accept': 'application/json'};
    if (etag != null && etag.trim().isNotEmpty) {
      headers['If-None-Match'] = etag.trim();
    }
    CatalogHttpResponse response;
    try {
      response = await _fetchOpenCode(
        Uri.parse(openCodeSourceUrl),
        headers,
        client,
      ).timeout(requestTimeout);
    } catch (_) {
      return null;
    }

    if (response.statusCode == 304) {
      await prefs.setInt(
        openCodeFetchedAtPrefsKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      return null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) return null;

    String overlay;
    try {
      overlay = await compute(_pruneOpenCodeCatalog, response.body);
    } catch (_) {
      return null;
    }
    final dynamic decoded = jsonDecode(overlay);
    if (decoded is! Map || decoded.isEmpty) return null;

    final installed = await _installOverlay(overlay);
    if (!installed) return null;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (!_isWeb) await _writeCacheFile(openCodeCacheFileName, overlay);
    await prefs.setInt(openCodeFetchedAtPrefsKey, now);
    final newEtag = response.etag;
    if (newEtag != null && newEtag.trim().isNotEmpty) {
      await prefs.setString(openCodeEtagPrefsKey, newEtag.trim());
    } else if (etag != null) {
      await prefs.remove(openCodeEtagPrefsKey);
    }
    return ModelCatalog.instance;
  }

  Future<CatalogHttpResponse> _fetch(
    Uri uri,
    Map<String, String> headers,
    http.Client? client,
  ) {
    return _fetchWith(uri, headers, client, _fetcher);
  }

  Future<CatalogHttpResponse> _fetchOpenCode(
    Uri uri,
    Map<String, String> headers,
    http.Client? client,
  ) {
    return _fetchWith(uri, headers, client, _openCodeFetcher);
  }

  Future<CatalogHttpResponse> _fetchWith(
    Uri uri,
    Map<String, String> headers,
    http.Client? client,
    CatalogFetcher fetcher,
  ) async {
    if (client == null) return fetcher(uri, headers);
    final response = await client.get(uri, headers: headers);
    return CatalogHttpResponse(
      statusCode: response.statusCode,
      body: response.body,
      etag: response.headers['etag'],
    );
  }

  Future<String?> _readCacheFile(String fileName) async {
    try {
      final dir = await _cacheDirectoryLoader();
      if (dir == null) return null;
      final file = File('${dir.path}/$fileName');
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteCacheFile(String fileName) async {
    try {
      final dir = await _cacheDirectoryLoader();
      if (dir == null) return;
      final file = File('${dir.path}/$fileName');
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _writeCacheFile(String fileName, String contents) async {
    try {
      final dir = await _cacheDirectoryLoader();
      if (dir == null) return;
      await dir.create(recursive: true);
      final target = File('${dir.path}/$fileName');
      final temp = File('${dir.path}/$fileName.tmp');
      await temp.writeAsString(contents, flush: true);
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
    } catch (_) {
      // Cache is an optimization only.
    }
  }

  Future<int> _readFetchedAt(String key) async {
    try {
      final prefs = await _prefsLoader();
      return prefs.getInt(key) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Test/debug helper: forget the loaded state (does not touch the disk).
  @visibleForTesting
  void debugReset() {
    _loaded = false;
    _baseJson = null;
    _overlayJson = null;
    _loadInflight = null;
    _refreshInflight = null;
    _openCodeRefreshInflight = null;
    ModelCatalog.debugReset();
  }

  static Future<String> _loadBundledSnapshot() =>
      _loadBundledAsset(snapshotAsset);

  static Future<String> _loadBundledOpenCodeSnapshot() =>
      _loadBundledAsset(openCodeSnapshotAsset);

  static Future<String> _loadBundledAsset(String asset) async {
    final data = await rootBundle.load(asset);
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

String _pruneOpenCodeCatalog(String rawJson) =>
    _extractOpenCodeProviders(pruneCatalogJson(rawJson));

String _extractOpenCodeProviders(String prunedJson) =>
    ensureCatalogProviderAlias(
      filterCatalogProviders(
        prunedJson,
        ModelCatalogService.openCodeProviderIds,
      ),
      alias: 'opencode',
      source: 'opencode-go',
    );
