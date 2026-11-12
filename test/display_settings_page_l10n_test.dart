import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/settings/pages/display_settings_page.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// 回歸測試：顯示設定頁的系統匣與話題面板位置選項必須跟隨應用程式語言。
///
/// 修正前 `app_en.arb`（template ARB）裡這些訊息是簡體中文，導致應用語言
/// 切成英文時，設定頁仍顯示「顯示托盤圖標」「關閉時最小化到托盤」
/// 「话题位置」等簡體中文文字。
Widget _host(Locale locale, SettingsProvider settings) {
  return ChangeNotifierProvider<SettingsProvider>.value(
    value: settings,
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const DisplaySettingsPage(),
    ),
  );
}

Future<void> _scrollTo(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(
    find.text(text),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('display settings follow app language: en', (tester) async {
    await tester.pumpWidget(_host(const Locale('en'), SettingsProvider()));
    await tester.pumpAndSettle();

    await _scrollTo(tester, 'Show tray icon');
    expect(find.text('Show tray icon'), findsOneWidget);
    expect(find.text('Minimize to tray on close'), findsOneWidget);

    await _scrollTo(tester, 'Topics Panel Position');
    expect(find.text('Topics Panel Position'), findsOneWidget);
    expect(find.text('Left'), findsOneWidget);
  });

  testWidgets('display settings follow app language: zh_Hant', (tester) async {
    await tester.pumpWidget(_host(
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      SettingsProvider(),
    ));
    await tester.pumpAndSettle();

    await _scrollTo(tester, '顯示系統匣圖示');
    expect(find.text('顯示系統匣圖示'), findsOneWidget);
    expect(find.text('關閉視窗時最小化到系統匣'), findsOneWidget);

    await _scrollTo(tester, '主題位置');
    expect(find.text('主題位置'), findsOneWidget);
    expect(find.text('左側'), findsOneWidget);
  });
}
