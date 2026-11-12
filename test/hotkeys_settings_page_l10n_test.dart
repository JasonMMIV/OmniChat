import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/providers/hotkey_provider.dart';
import 'package:OmniChat/features/settings/pages/hotkeys_settings_page.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// 回歸測試：快捷鍵設定頁必須跟隨應用程式語言切換。
///
/// 修正前 `app_en.arb`（template ARB）裡所有快捷鍵相關訊息都是簡體中文，
/// 導致應用語言切成英文時，快捷鍵設定頁仍顯示中文。
///
/// 注意：不在測試中呼叫 [HotkeyProvider.initialize]，它會透過
/// hotkey_manager 觸發平台頻道（widget 測試沒有 plugin 實作，會卡住）。
/// 未初始化時所有快捷鍵都沒有綁定，7 列都會顯示「按下快捷鍵」佔位文字。
Widget _host(Locale locale) {
  return ChangeNotifierProvider<HotkeyProvider>(
    create: (_) => HotkeyProvider(),
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const HotkeysSettingsPage(),
    ),
  );
}

void main() {
  testWidgets('hotkeys page follows app language: en', (tester) async {
    await tester.pumpWidget(_host(const Locale('en')));
    await tester.pumpAndSettle();

    // AppBar title + pane section header.
    expect(find.text('Keyboard Shortcuts'), findsNWidgets(2));

    // Row labels (resolved via item.l10nLabelKey).
    expect(find.text('Show/Hide App'), findsOneWidget);
    expect(find.text('Close Window'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    expect(find.text('New Topic'), findsOneWidget);
    expect(find.text('Switch Model'), findsOneWidget);
    expect(find.text('Toggle Assistants Panel'), findsOneWidget);
    expect(find.text('Toggle Topics Panel'), findsOneWidget);

    // Placeholder in the shortcut editor (all bindings empty pre-init).
    expect(find.text('Press a shortcut'), findsNWidgets(7));
  });

  testWidgets('hotkeys page follows app language: zh_Hant', (tester) async {
    await tester.pumpWidget(_host(
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('快捷鍵'), findsNWidgets(2));
    expect(find.text('顯示/隱藏應用'), findsOneWidget);
    expect(find.text('關閉視窗'), findsOneWidget);
    expect(find.text('打開設定'), findsOneWidget);
    expect(find.text('新建話題'), findsOneWidget);
    expect(find.text('切換模型'), findsOneWidget);
    expect(find.text('切換專案顯示'), findsOneWidget);
    expect(find.text('切換話題顯示'), findsOneWidget);
    expect(find.text('按下快捷鍵'), findsNWidgets(7));
  });
}
