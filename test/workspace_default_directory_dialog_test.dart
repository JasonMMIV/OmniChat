import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/chat/widgets/workspace_settings_dialog.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// 桌面版「預設工作目錄」視窗回歸測試：
/// 內容 sheet 的 Material 只設了上緣圓角（bottom sheet 樣式），
/// 桌面以 Dialog 呈現時必須自行指定形狀＋裁切，否則下緣會露出直角。
void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> openDialog(WidgetTester tester, TargetPlatform platform) async {
    debugDefaultTargetPlatformOverride = platform;

    final settings = SettingsProvider();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showDefaultWorkspaceDirectoryDialog(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // framework 的 invariant check 在 teardown 之前執行，必須在測試 body 內重置。
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('desktop dialog rounds all four corners uniformly', (
    tester,
  ) async {
    await openDialog(tester, TargetPlatform.windows);

    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(dialog.clipBehavior, Clip.antiAlias);
    expect(
      dialog.shape,
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    );
  });

  testWidgets('mobile keeps the bottom-sheet presentation', (tester) async {
    await openDialog(tester, TargetPlatform.android);

    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(BottomSheet), findsOneWidget);
  });
}
