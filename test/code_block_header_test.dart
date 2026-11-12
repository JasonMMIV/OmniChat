import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
import 'package:OmniChat/shared/widgets/markdown_with_highlight.dart';

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

Future<void> _pumpMd(
  WidgetTester tester,
  SettingsProvider sp,
  String text, {
  Locale? locale,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: sp,
      child: MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(body: MarkdownWithCodeHighlight(text: text)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('code block language labels are vertically centered', (
    tester,
  ) async {
    final sp = await _loadedProvider();
    for (final entry in const {
      '```html\n<div>x</div>\n```': 'html',
      '```\nplain\n```': 'Code',
    }.entries) {
      await _pumpMd(tester, sp, entry.key);

      final label = find.text(entry.value);
      expect(label, findsOneWidget);

      final labelCenter = tester.getCenter(label).dy;
      final chevronCenter = tester
          .getCenter(find.byIcon(Lucide.ChevronRight))
          .dy;
      expect(labelCenter, moreOrLessEquals(chevronCenter, epsilon: 0.5));
    }
  });

  testWidgets('the fallback code block label follows the app locale', (
    tester,
  ) async {
    final sp = await _loadedProvider();
    const md = '```\nplain\n```';
    final cases = <Locale, String>{
      const Locale('en'): 'Code',
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'): '代码',
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'): '程式碼',
    };

    for (final entry in cases.entries) {
      await _pumpMd(tester, sp, md, locale: entry.key);
      expect(
        find.text(entry.value),
        findsOneWidget,
        reason: 'locale ${entry.key}',
      );
    }
  });

  testWidgets('an explicit fence language is shown verbatim', (tester) async {
    final sp = await _loadedProvider();
    await _pumpMd(
      tester,
      sp,
      '```typescript\nconst x = 1;\n```',
      locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    );

    expect(find.text('typescript'), findsOneWidget);
  });
}
