import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 取得 Live API 模型清單的結果。
class LiveApiModelsResult {
  const LiveApiModelsResult({required this.models, this.error});

  final List<String> models;
  final LiveApiModelsError? error;

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
/// 記憶體快取 5 分鐘，換 key 時以 [invalidateCache] 清除。
class LiveApiModelsService {
  LiveApiModelsService._();

  static const Duration _timeout = Duration(seconds: 15);
  static const Duration _cacheTtl = Duration(minutes: 5);

  static List<String>? _cache;
  static DateTime? _cacheTime;

  /// 清除記憶體快取（API key 變更時呼叫）。
  static void invalidateCache() {
    _cache = null;
    _cacheTime = null;
  }

  /// 由 WebSocket baseUrl 推導 REST models 端點主機；無法解析時回退官方主機。
  static Uri modelsUri(String? baseUrl) {
    final uri = Uri.tryParse(baseUrl ?? '');
    final host = (uri != null &&
            uri.host.isNotEmpty &&
            (uri.scheme == 'https' || uri.scheme == 'wss'))
        ? uri.host
        : 'generativelanguage.googleapis.com';
    return Uri.parse('https://$host/v1beta/models');
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
      );
    }
    if (!forceRefresh && _cache != null && _cacheTime != null) {
      final age = DateTime.now().difference(_cacheTime!);
      if (age < _cacheTtl) {
        return LiveApiModelsResult(models: _cache!);
      }
    }
    final c = client ?? http.Client();
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
          return const LiveApiModelsResult(
            models: <String>[],
            error: LiveApiModelsError.http,
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
        );
      }
      _cache = models;
      _cacheTime = DateTime.now();
      return LiveApiModelsResult(models: models);
    } catch (_) {
      return const LiveApiModelsResult(
        models: <String>[],
        error: LiveApiModelsError.network,
      );
    } finally {
      if (client == null) c.close();
    }
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
