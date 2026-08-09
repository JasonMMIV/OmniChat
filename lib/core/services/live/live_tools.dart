/// Live API Function calling 內建工具。
///
/// [builtInLiveTools] 是 setup 的 `tools` 宣告（functionDeclarations）；
/// [runBuiltInLiveTool] 是對應的執行器，回傳 JSON 可序列化的結果 map。
library;

import 'dart:convert';

import '../../providers/settings_provider.dart';
import '../search/search_tool_service.dart';

/// 搜尋執行器：執行一次 web search，回傳 JSON 字串（`SearchToolService`
/// 的回傳格式）。注入 seam，供測試替換（避免真的打網路）。
typedef LiveSearchExecutor = Future<String> Function(String query);

/// 內建工具宣告（Live API setup `tools` 使用）。
///
/// 每個項目是一個 tool 物件，含 `functionDeclarations` 清單。
/// schema 的 type 使用 Gemini API 的 JSON enum 名稱（大寫）。
const List<Map<String, dynamic>> builtInLiveTools = <Map<String, dynamic>>[
  <String, dynamic>{
    'functionDeclarations': <Map<String, dynamic>>[
      <String, dynamic>{
        'name': 'get_current_datetime',
        'description': '取得目前本地日期與時間（無需參數）。',
        'parameters': <String, dynamic>{
          'type': 'OBJECT',
          'properties': <String, dynamic>{},
          'required': <String>[],
        },
      },
    ],
  },
  <String, dynamic>{
    'functionDeclarations': <Map<String, dynamic>>[
      <String, dynamic>{
        'name': 'search_web',
        'description':
            'Search the web for current information. '
            'Returns a list of results with title, URL and snippet. '
            'Use this when the user asks about recent events, facts that may '
            'have changed, or anything outside your training knowledge.',
        'parameters': <String, dynamic>{
          'type': 'OBJECT',
          'properties': <String, dynamic>{
            'query': <String, dynamic>{
              'type': 'STRING',
              'description': 'The search query to look up online',
            },
          },
          'required': <String>['query'],
        },
      },
    ],
  },
];

/// 執行內建工具。未知工具回傳 `{'error': ...}`。
///
/// - `get_current_datetime`：回傳目前日期/時間。
/// - `search_web`：以 [settings] 中選定的搜尋服務執行 web search。
///   需要 [settings]（提供已設定的搜尋服務與選定索引）；找不到時回 error。
///
/// [searchExecutor] 是注入 seam（預設走 `SearchToolService.executeSearch`），
/// 測試時可替換成 fake 避免打網路。
Future<Map<String, dynamic>> runBuiltInLiveTool(
  String name,
  Map<String, dynamic> args, {
  SettingsProvider? settings,
  LiveSearchExecutor? searchExecutor,
}) async {
  switch (name) {
    case 'get_current_datetime':
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      return <String, dynamic>{
        'iso8601': now.toIso8601String(),
        'date': '${now.year}-${two(now.month)}-${two(now.day)}',
        'time': '${two(now.hour)}:${two(now.minute)}:${two(now.second)}',
        'weekday': now.weekday, // 1=Mon .. 7=Sun
      };
    case 'search_web':
      final query = (args['query'] as String?)?.trim() ?? '';
      if (query.isEmpty) {
        return <String, dynamic>{
          'error': 'search_web requires a non-empty query',
        };
      }
      if (settings == null) {
        return <String, dynamic>{
          'error': 'search_web requires settings to resolve the search service',
        };
      }
      final exec = searchExecutor ??
          ((q) => SearchToolService.executeSearch(q, settings));
      final String raw;
      try {
        raw = await exec(query);
      } catch (e) {
        return <String, dynamic>{'error': 'search failed: $e'};
      }
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
        return <String, dynamic>{
          'error': 'search returned unexpected data',
        };
      } catch (_) {
        // 非 JSON 的錯誤文字（如網路例外）原樣回傳，模型仍能理解
        return <String, dynamic>{'error': raw};
      }
    default:
      return <String, dynamic>{'error': 'unknown tool: $name'};
  }
}
