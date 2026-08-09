import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

/// 取得 Live API 模型清單的結果。
class LiveApiModelsResult {
  const LiveApiModelsResult({required this.models, this.error, this.detail});

  final List<String> models;
  final LiveApiModelsError? error;

  /// 真實失敗細節（HTTP 狀態碼、伺服器錯誤訊息、例外文字等），供 UI 顯示。
  final String? detail;

  bool get hasError => error != null;
}

/// 取得模型清單的失敗原因。
enum LiveApiModelsError {
  /// API key 為空。
  emptyKey,

  /// HTTP 非 200。
  http,

  /// 網路／解析失敗。
  network,

  /// 成功但沒有 Live 模型。
  empty,
}

/// 從 Gemini REST API 抓取可用 Live 模型清單的服務。
///
/// 記憶體快取 5 分鐘；快取以「API Key + endpoint」為 key 區分，
/// 換 key 或換 Base URL 時以 [invalidateCache] 清除。
class LiveApiModelsService {
  LiveApiModelsService._();

  static const Duration _timeout = Duration(seconds: 15);
  static const Duration _cacheTtl = Duration(minutes: 5);

  static final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  /// 測試用：覆寫預設 http client factory（widget 測試避免真實網路）。
  @visibleForTesting
  static http.Client Function()? clientFactory;

  /// 清除記憶體快取（API key 或 Base URL 變更時呼叫）。
  static void invalidateCache() {
    _cache.clear();
  }

  /// 標準化快取 key：normalized REST endpoint + API key。
  ///
  /// 不同 key 或不同 host/port/path 不會共用同一份快取，
  /// 切換後不會顯示舊模型的清單。
  static String _cacheKey({required String apiKey, String? baseUrl}) {
    final uri = modelsUri(baseUrl);
    final endpoint = uri.hasPort
        ? '${uri.scheme}://${uri.host}:${uri.port}${uri.path}'
        : '${uri.scheme}://${uri.host}${uri.path}';
    return '$endpoint|${apiKey.trim()}'; // key 只進 key，不進 log/error
  }

  /// 由 WebSocket baseUrl 推導 REST models 端點；無法解析時回退官方主機。
  ///
  /// - 官方主機（generativelanguage.googleapis.com）→ 根路徑
  ///   `https://{host}/v1beta/models`（無 port、無 path）。
  /// - 自訂 endpoint 保留 port，並保留 `/ws/` 之前的必要 path prefix，
  ///   例如 `wss://host:8443/v1/live` →
  ///   `https://host:8443/v1/live/v1beta/models`；
  ///   `wss://host:8443/ws/...BidiGenerateContent` →
  ///   `https://host:8443/v1beta/models`。
  static Uri modelsUri(String? baseUrl) {
    final uri = Uri.tryParse(baseUrl ?? '');
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'wss')) {
      return Uri.parse('https://generativelanguage.googleapis.com/v1beta/models');
    }
    if (uri.host == 'generativelanguage.googleapis.com') {
      return Uri.parse('https://generativelanguage.googleapis.com/v1beta/models');
    }
    // 剝離 Gemini WebSocket 服務路徑（/ws/...BidiGenerateContent），
    // 保留 gateway 的 path prefix（若存在）。
    var path = uri.path;
    final wsIndex = path.indexOf('/ws/');
    if (wsIndex >= 0) path = path.substring(0, wsIndex);
    final basePath = (path.isEmpty || path == '/') ? '' : path;
    return Uri(
      scheme: 'https',
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '$basePath/v1beta/models',
    );
  }

  static Future<LiveApiModelsResult> fetchLiveModels({
    required String apiKey,
    String? baseUrl,
    http.Client? client,
    bool forceRefresh = false,
  }) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      return const LiveApiModelsResult(
        models: <String>[],
        error: LiveApiModelsError.emptyKey,
        detail: 'API Key 為空（可能尚未寫入設定）',
      );
    }
    if (!forceRefresh) {
      final cached = _cache[_cacheKey(apiKey: key, baseUrl: baseUrl)];
      if (cached != null) {
        final age = DateTime.now().difference(cached.time);
        if (age < _cacheTtl) {
          return LiveApiModelsResult(models: cached.models);
        }
      }
    }
    final c = client ?? (clientFactory?.call() ?? http.Client());
    try {
      final names = <String>{};
      var nextPageToken = '';
      var page = 0;
      do {
        final uri = modelsUri(baseUrl).replace(queryParameters: {
          'key': key,
          if (nextPageToken.isNotEmpty) 'pageToken': nextPageToken,
          'pageSize': '100',
        });
        final resp = await c
            .get(uri, headers: const {'accept': 'application/json'})
            .timeout(_timeout);
        if (resp.statusCode != 200) {
          final serverMsg = _extractErrorMessage(resp.body);
          return LiveApiModelsResult(
            models: <String>[],
            error: LiveApiModelsError.http,
            // 顯示用 URI 不含 key query，避免 API Key 進入錯誤訊息／log。
            detail: 'HTTP ${resp.statusCode}'
                '${serverMsg.isNotEmpty ? ' — $serverMsg' : ''}'
                ' (${_uriWithoutKey(uri)})',
          );
        }
        final pageResult = parseModelsResponse(resp.body);
        names.addAll(pageResult.models);
        nextPageToken = pageResult.nextPageToken;
        page++;
      } while (nextPageToken.isNotEmpty && page < 10);
      final models = names.toList()..sort();
      if (models.isEmpty) {
        return const LiveApiModelsResult(
          models: <String>[],
          error: LiveApiModelsError.empty,
          detail: '伺服器回傳 200 但未解析到任何 Live 模型',
        );
      }
      _cache[_cacheKey(apiKey: key, baseUrl: baseUrl)] =
          _CacheEntry(models, DateTime.now());
      return LiveApiModelsResult(models: models);
    } catch (e) {
      return LiveApiModelsResult(
        models: <String>[],
        error: LiveApiModelsError.network,
        // http.ClientException 的訊息包含 request uri（含 `key` query），
        // 先遮蔽再進 detail/UI/log。
        detail: maskApiKey(e.toString(), key),
      );
    } finally {
      if (client == null) c.close();
    }
  }

  /// 顯示用 URI：移除 `key` query，避免 API Key 洩漏到錯誤訊息或 log。
  static String _uriWithoutKey(Uri uri) {
    final query = Map<String, String>.from(uri.queryParameters)..remove('key');
    return uri.replace(queryParameters: query).toString();
  }

  /// 從 Gemini 錯誤回應 JSON 取出 `error.message`。
  static String _extractErrorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final err = decoded['error'];
        if (err is Map<String, dynamic>) {
          final msg = err['message'];
          if (msg is String && msg.isNotEmpty) return msg;
        }
      }
    } catch (_) {}
    return '';
  }

  /// 單頁 `/v1beta/models` 回應解析結果。
  static ({List<String> models, String nextPageToken}) parseModelsResponse(
    String body,
  ) {
    final names = <String>{};
    String nextPageToken = '';
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        return (models: <String>[], nextPageToken: '');
      }
      final token = decoded['nextPageToken'];
      if (token is String) nextPageToken = token;
      final list = decoded['models'];
      if (list is! List) {
        return (models: <String>[], nextPageToken: nextPageToken);
      }
      for (final e in list) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final rawName = m['name'];
        if (rawName is! String) continue;
        final name = rawName.replaceFirst('models/', '');
        if (name.isEmpty) continue;
        final supportsLive = m['supportsLiveGeneration'] == true;
        final methods = m['supportedGenerationMethods'];
        final methodsList = methods is List
            ? methods.whereType<String>().toList()
            : const <String>[];
        final supportsBidi = methodsList.contains('bidiGenerateContent');
        final looksLive = name.contains('live');
        if (supportsLive ||
            supportsBidi ||
            (looksLive &&
                (methodsList.isEmpty || methodsList.contains('generateContent')))) {
          names.add(name);
        }
      }
    } catch (_) {
      return (models: <String>[], nextPageToken: '');
    }
    return (models: names.toList(), nextPageToken: nextPageToken);
  }

  /// 解析 `/v1beta/models` 回應並篩選 Live 模型。
  ///
  /// 保留 `supportsLiveGeneration == true`、`supportedGenerationMethods`
  /// 含 `bidiGenerateContent`，或名稱含 "live" 且方法（若有宣告）含
  /// `generateContent` 的模型。結果依名稱排序。
  static List<String> parseModels(String body) {
    return parseModelsResponse(body).models..sort();
  }
}

/// 將可能含 API Key 的訊息文字遮蔽（例如 `WebSocketException` /
/// `http.ClientException` 的訊息會內嵌完整 request uri，含 `?key=...`）。
///
/// key 為空時原樣回傳（無需處理）。所有會進入 log / error / UI 的文字
/// 都應先過這一層（§5.8：所有診斷資訊必須遮蔽 API Key）。
String maskApiKey(String message, String apiKey) {
  final key = apiKey.trim();
  if (key.isEmpty || message.isEmpty) return message;
  return message.replaceAll(key, '***');
}

/// 單一 (key + endpoint) 的快取項目。
class _CacheEntry {
  _CacheEntry(this.models, this.time);

  final List<String> models;
  final DateTime time;
}
