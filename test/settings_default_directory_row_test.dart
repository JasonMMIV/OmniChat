import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/workspace_config.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/settings/pages/settings_page.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// 等待 `SettingsProvider._load()` 完成（載入完成會 notifyListeners）。
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

/// 手機直向（360×740 邏輯像素）下，設定頁「預設工作目錄」列必須仍顯示
/// 標籤文字。
///
/// 回歸問題：`detailText`（工作目錄路徑）在 Row 中是**非彈性子項**，會先於
/// `Expanded` 的標籤配置版面；路徑很長時會吃掉整列寬度，把標籤壓縮成 0
/// 寬度，於是只看得到路徑、看不到「預設工作目錄」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // SettingsProvider._load 會讀 secure storage；未 mock 的 platform
    // channel 在 widget 測試中永不回傳（會卡住 _load）。
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('設定頁預設工作目錄列在直向寬度下仍顯示標籤', (tester) async {
    final sp = await _loadedProvider();
    const longPath =
        'C:\\Users\\developer\\Documents\\OmniChat\\workspace\\'
        'frontend feature branch';
    await sp.setDefaultWorkspaceConfig(
      const WorkspaceConfig.custom(longPath),
    );

    // 模擬常見手機直向尺寸。
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: sp,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final labelFinder = find.text(l10n.workspaceDefaultDirectorySettings);
    expect(labelFinder, findsOneWidget);

    final labelRect = tester.getRect(labelFinder);
    final detailRect = tester.getRect(find.text(longPath));

    // 修正前：標籤被長路徑擠壓成 0 寬度而完全不顯示。
    expect(labelRect.width, greaterThan(100));

    // 路徑細節被限制在可用空間的 40% 以內：
    // 列內容寬 304（360 - ListView 左右 padding 32 - 列左右 padding 24），
    // 固定寬 64（icon 36 + 間距 12 + 箭頭 16），可用 240 → 上限 96。
    expect(detailRect.width, lessThanOrEqualTo(96.5));

    // 兩段文字都完整落在畫面內。
    final screen = Offset.zero & const Size(360, 740);
    expect(screen.contains(labelRect.center), isTrue);
    expect(screen.contains(detailRect.center), isTrue);
  });
}
