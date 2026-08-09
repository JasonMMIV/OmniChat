import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/live/live_api_models_service.dart';
import 'package:OmniChat/features/settings/pages/voice_call_settings_page.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// 與 `live_api_settings_test.dart` 相同的載入輔助：
/// 等待 SettingsProvider 的 `_load()` 完成（載入完成會 notifyListeners）。
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

Future<void> _pumpPage(WidgetTester tester, SettingsProvider sp) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<SettingsProvider>.value(
      value: sp,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const VoiceCallSettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 模擬 Gemini `/v1beta/models` 成功回應。
MockClient _modelsClient() {
  return MockClient((request) async {
    return http.Response(
      jsonEncode({
        'models': [
          {'name': 'models/gemini-3.5-live-translate-preview'},
          {'name': 'models/gemini-2.0-flash-live-preview'},
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // SettingsProvider._load 會讀 secure storage；未 mock 的 platform
    // channel 在 widget 測試中永不回傳（會卡住 _load）。
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    LiveApiModelsService.clientFactory = null;
    LiveApiModelsService.invalidateCache();
  });

  testWidgets('mobile model list selection saves to SettingsProvider',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'voice_call_mode_v1': 'liveApi',
      'live_api_key_v1': 'AIza-test',
    });
    final sp = await _loadedProvider();
    expect(sp.voiceCallMode, VoiceCallMode.liveApi);

    LiveApiModelsService.clientFactory = _modelsClient;
    await _pumpPage(tester, sp);

    // 點模型列開啟 bottom sheet
    await tester.tap(find.text('Model'));
    await tester.pumpAndSettle();

    // 清單載入完成：兩個 Live 模型可見
    expect(find.text('gemini-3.5-live-translate-preview'), findsOneWidget);
    expect(find.text('gemini-2.0-flash-live-preview'), findsOneWidget);

    // 選取後保存到 SettingsProvider，且頁面立即顯示新值
    await tester.tap(find.text('gemini-3.5-live-translate-preview'));
    await tester.pumpAndSettle();
    expect(sp.liveApiModel, 'gemini-3.5-live-translate-preview');
    expect(find.text('gemini-3.5-live-translate-preview'), findsOneWidget);
  });

  testWidgets('mobile manual model input saves to SettingsProvider',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'voice_call_mode_v1': 'liveApi',
      'live_api_key_v1': 'AIza-test',
    });
    final sp = await _loadedProvider();
    await _pumpPage(tester, sp);

    // 開啟 bottom sheet（無網路 stub → 顯示錯誤，但手動輸入列仍存在）
    await tester.tap(find.text('Model'));
    await tester.pumpAndSettle();
    expect(find.text('Enter model name manually…'), findsOneWidget);

    // 手動輸入模型名稱
    await tester.tap(find.text('Enter model name manually…'));
    await tester.pumpAndSettle();
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, 'gemini-2.0-flash-live-preview');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(sp.liveApiModel, 'gemini-2.0-flash-live-preview');
    expect(find.text('gemini-2.0-flash-live-preview'), findsOneWidget);
  });

  testWidgets('selected model persists after reopening the settings page',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'voice_call_mode_v1': 'liveApi',
      'live_api_key_v1': 'AIza-test',
      'live_api_model_v1': 'gemini-3.1-flash-live-preview',
    });
    final sp = await _loadedProvider();
    expect(sp.liveApiModel, 'gemini-3.1-flash-live-preview');

    await _pumpPage(tester, sp);
    // 模型列顯示已保存的值（重新開啟頁面仍保留）
    expect(find.text('gemini-3.1-flash-live-preview'), findsOneWidget);
  });
}
