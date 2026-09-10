import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'search_service.dart';
import 'search_dispatch.dart';
import '../../providers/settings_provider.dart';

/// Result of a dispatched search: the LLM-visible JSON plus UI-only trace
/// info (which provider actually served it and the fallback origin).
class SearchTraceResult {
  const SearchTraceResult({
    required this.json,
    this.providerName,
    this.fallbackFromName,
  });

  /// The JSON string handed to the LLM — unchanged shape from before.
  final String json;

  /// Display name of the provider that produced the result.
  final String? providerName;

  /// Display name of the originally-preferred provider when the search was
  /// switched to another provider (fallback), null otherwise.
  final String? fallbackFromName;
}

class SearchToolService {
  static const String toolName = 'search_web';
  static const String toolDescription = 'Search the web for information';

  /// App-lifecycle dispatch state (round-robin cursor + 429 cooldown table);
  /// resets on restart — same ephemeral pattern as connection test results.
  static final SearchDispatcher _dispatcher = SearchDispatcher();

  static Map<String, dynamic> getToolDefinition() {
    return {
      'type': 'function',
      'function': {
        'name': toolName,
        'description': toolDescription,
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'The search query to look up online',
            },
          },
          'required': ['query'],
        },
      },
    };
  }

  /// Execute a web search through the multi-provider dispatch engine.
  ///
  /// The signature stays unchanged so every existing call site (tool handler,
  /// live voice tools, chat turn service, AI Team) benefits automatically.
  static Future<String> executeSearch(
    String query,
    SettingsProvider settings,
  ) async {
    final trace = await executeSearchWithTrace(query, settings);
    return trace.json;
  }

  /// Same as [executeSearch] but also reports which provider served the
  /// result (and the fallback origin) for UI-only display. The returned
  /// [SearchTraceResult.json] is exactly what [executeSearch] would return.
  static Future<SearchTraceResult> executeSearchWithTrace(
    String query,
    SettingsProvider settings,
  ) async {
    try {
      final services = settings.searchServices;
      if (services.isEmpty) {
        return SearchTraceResult(
          json: jsonEncode({'error': 'No search services configured'}),
        );
      }

      // Dispatch candidates: the selected (checked) set in service-list
      // order — the first entry is the primary provider. Duplicate ids
      // (possible via JSON import / restore) are collapsed so the cooldown
      // table and attempt lookup stay unambiguous.
      final selectedIds = settings.searchSelectedProviders.toSet();
      final seenIds = <String>{};
      var candidates = <SearchServiceOptions>[
        for (final s in services)
          if (selectedIds.contains(s.id) && seenIds.add(s.id)) s,
      ];
      if (candidates.isEmpty) {
        // Defensive: the settings UI/migration never allow an empty set —
        // fall back to the legacy single index so stale data still searches.
        final idx = settings.searchServiceSelected.clamp(
          0,
          services.length - 1,
        );
        candidates = <SearchServiceOptions>[services[idx]];
      }

      final outcome = await _dispatcher.dispatch<SearchResult>(
        candidates: [
          for (final s in candidates)
            SearchDispatchCandidate(
              id: s.id,
              name: SearchService.getService(s).name,
            ),
        ],
        mode: settings.searchDispatchMode,
        attempt: (candidate) async {
          final options = candidates.firstWhere((s) => s.id == candidate.id);
          final service = SearchService.getService(options);
          return service.search(
            query: query,
            commonOptions: settings.searchCommonOptions,
            serviceOptions: options,
          );
        },
      );

      final result = outcome.value;
      if (result == null) {
        return SearchTraceResult(
          json: SearchDispatcher.buildAggregateErrorJson(outcome.failures),
        );
      }

      // Add unique IDs to each result item
      final itemsWithIds = result.items.asMap().entries.map((entry) {
        final item = entry.value;
        item.id = const Uuid().v4().substring(0, 6);
        item.index = entry.key + 1;
        return item;
      }).toList();

      // Return formatted result (identical to the previous single-provider
      // output — provider info never enters this JSON).
      return SearchTraceResult(
        json: jsonEncode({
          if (result.answer != null) 'answer': result.answer,
          'items': itemsWithIds.map((item) => item.toJson()).toList(),
        }),
        providerName: outcome.provider?.name,
        fallbackFromName: outcome.fallbackFrom?.name,
      );
    } catch (e) {
      return SearchTraceResult(json: jsonEncode({'error': 'Search failed: $e'}));
    }
  }

  static String getSystemPrompt() {
    return '''
## search_web 工具使用说明

当用户询问需要实时信息或最新数据的问题时，使用 search_web 工具进行搜索。

### 引用格式
- 搜索结果中会包含index(搜索结果序号)和id(搜索结果唯一标识符)，引用格式为：
  `具体的引用内容 [citation](index:id)`
- **引用必须紧跟在相关内容之后**，在标点符号后面，不得延后到回复结尾
- 正确格式：`... [citation](index:id)` `... [citation](index:id) [citation](index:id)`

### 使用规范
1. **使用时机**
   - 用户询问最新新闻、事件、数据
   - 需要查证事实信息
   - 需要获取技术文档、API信息等
   
2. **引用要求**
   - 使用搜索结果时必须标注引用来源
   - 每个引用的事实都要紧跟 [citation](index:id) 标记
   - 不要将所有引用集中在回答末尾

3. **回答格式示例**
   ✅ 正确：
   - 据最新报道，该事件发生在昨天下午。[citation](1:a1b2c3)
   - 技术文档显示该功能需要版本3.0以上。[citation](2:d4e5f6) 具体配置步骤如下...[citation](3:g7h8i9)
   
   ❌ 错误：
   - 据最新报道，该事件发生在昨天下午。技术文档显示该功能需要版本3.0以上。
     [citation](1:a1b2c3) [citation](2:d4e5f6)
''';
  }
}
