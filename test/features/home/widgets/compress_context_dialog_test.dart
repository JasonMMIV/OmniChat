import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/features/home/pages/home_page.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

void main() {
  Widget buildTestWidget({
    Size screenSize = const Size(360, 740),
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    return MaterialApp(
      locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(
          size: screenSize,
          textScaler: textScaler,
        ),
        child: const Scaffold(
          body: CompressContextOptionsDialog(),
        ),
      ),
    );
  }

  testWidgets('直立手機畫面下壓縮上下文按鈕完整顯示', (tester) async {
    // 模擬一般 360 寬度手機直立螢幕
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildTestWidget());
    await tester.pumpAndSettle();

    // 驗證對話框寬度適配手機螢幕（360 - 40 = 320）
    final dialogFinder = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(Material),
    );
    expect(tester.getSize(dialogFinder.first).width, equals(320.0));

    // 驗證按鈕文字皆完整存在且可尋得
    expect(find.text('最開始'), findsOneWidget);
    expect(find.text('最近'), findsOneWidget);
    expect(find.text('無限制'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('開始壓縮'), findsOneWidget);
  });

  testWidgets('手機畫面配合放大字級時壓縮上下文選項正常渲染不報錯', (tester) async {
    // 模擬 360 寬度手機搭配 1.25 倍系統字級
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      buildTestWidget(textScaler: const TextScaler.linear(1.25)),
    );
    await tester.pumpAndSettle();

    expect(find.text('最開始'), findsOneWidget);
    expect(find.text('最近'), findsOneWidget);
    expect(find.text('無限制'), findsOneWidget);

    // 切換至無限制模式
    await tester.tap(find.text('無限制'));
    await tester.pumpAndSettle();

    // 切換至最近模式
    await tester.tap(find.text('最近'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
