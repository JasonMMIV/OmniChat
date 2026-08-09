import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/live/live_tools.dart';

/// 與 `live_api_settings_test.dart` 相同的載入輔助。
Future<SettingsProvider> _loadedProvider() async {
  final sp = SettingsProvider();
  final done = Completer<void>();
  void listener() {
    if (!done.isCompleted) done.complete();
  }

  sp.addListener(listener);
  await done.future.timeout(const Duration(seconds: 10));
  sp.removeListener(listener);
  return sp;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('builtInLiveTools 宣告', () {
    test('含 get_current_datetime 與 search_web 兩個工具', () {
      final names = <String>[];
      for (final tool in builtInLiveTools) {
        final fns = (tool['functionDeclarations'] as List);
        for (final fn in fns) {
          names.add((fn as Map)['name'] as String);
        }
      }
      expect(
        names,
        containsAll(<String>['get_current_datetime', 'search_web']),
      );
    });

    test('search_web 宣告 query 為必填 STRING 參數', () {
      final tool = builtInLiveTools.firstWhere(
        (t) => ((t['functionDeclarations'] as List).first as Map)['name'] ==
            'search_web',
      );
      final fn = (tool['functionDeclarations'] as List).first as Map;
      final params = fn['parameters'] as Map;
      expect(params['type'], 'OBJECT');
      expect((params['required'] as List), <String>['query']);
      final query = (params['properties'] as Map)['query'] as Map;
      expect(query['type'], 'STRING');
    });
  });

  group('runBuiltInLiveTool', () {
    test('get_current_datetime 回傳完整日期時間欄位', () async {
      final result =
          await runBuiltInLiveTool('get_current_datetime', <String, dynamic>{});
      expect(result['iso8601'], isA<String>());
      expect(result['date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      expect(result['time'], matches(RegExp(r'^\d{2}:\d{2}:\d{2}$')));
      expect(result['weekday'], isA<int>());
      expect(result.containsKey('error'), isFalse);
    });

    test('未知工具回傳 error', () async {
      final result = await runBuiltInLiveTool('nope', <String, dynamic>{});
      expect(result['error'], contains('unknown tool'));
    });

    test('search_web 缺少 query 回傳 error', () async {
      final result = await runBuiltInLiveTool('search_web', <String, dynamic>{});
      expect(result['error'], contains('non-empty query'));
    });

    test('search_web 沒有 settings 回傳 error（不呼叫搜尋）', () async {
      var called = false;
      final result = await runBuiltInLiveTool(
        'search_web',
        <String, dynamic>{'query': 'flutter'},
        searchExecutor: (_) async {
          called = true;
          return '{}';
        },
      );
      expect(result['error'], contains('requires settings'));
      expect(called, isFalse);
    });

    test('search_web 以注入 executor 回傳並解析 JSON 結果', () async {
      final sp = await _loadedProvider();
      final queries = <String>[];
      final result = await runBuiltInLiveTool(
        'search_web',
        <String, dynamic>{'query': '  最新 Gemini 新聞  '},
        settings: sp,
        searchExecutor: (q) async {
          queries.add(q);
          return jsonEncode(<String, dynamic>{
            'answer': '摘要',
            'items': <Map<String, dynamic>>[
              <String, dynamic>{
                'title': '標題',
                'url': 'https://example.com',
                'snippet': '片段',
              },
            ],
          });
        },
      );
      expect(queries, <String>['最新 Gemini 新聞']); // query 已 trim
      expect(result['answer'], '摘要');
      expect((result['items'] as List).single['title'], '標題');
    });

    test('search_web 執行器回傳非 JSON（錯誤文字）時原樣回傳 error', () async {
      final sp = await _loadedProvider();
      final result = await runBuiltInLiveTool(
        'search_web',
        <String, dynamic>{'query': 'flutter'},
        settings: sp,
        searchExecutor: (_) async => 'Search failed: network down',
      );
      expect(result['error'], 'Search failed: network down');
    });

    test('search_web 執行器拋錯時 error 內含例外訊息', () async {
      final sp = await _loadedProvider();
      final result = await runBuiltInLiveTool(
        'search_web',
        <String, dynamic>{'query': 'flutter'},
        settings: sp,
        searchExecutor: (_) async => throw Exception('boom'),
      );
      expect(result['error'], contains('boom'));
    });
  });
}
