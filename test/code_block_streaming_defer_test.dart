import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
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

Future<void> _pump(
  WidgetTester tester,
  SettingsProvider sp, {
  required bool streaming,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: sp,
      child: MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: MarkdownWithCodeHighlight(
            text: '```dart\nvoid main() {}\n```',
            isStreaming: streaming,
          ),
        ),
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

  testWidgets('streaming code blocks render plain text without parsing',
      (tester) async {
    final sp = await _loadedProvider();
    await _pump(tester, sp, streaming: true);

    expect(find.byType(SelectableHighlightView), findsNothing);
    final plain = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(plain.data, contains('void main()'));
  });

  testWidgets('completed code blocks use the highlighted view', (tester) async {
    final sp = await _loadedProvider();
    await _pump(tester, sp, streaming: false);

    expect(find.byType(SelectableHighlightView), findsOneWidget);
  });
}
