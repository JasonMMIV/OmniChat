import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

Future<void> _pumpMd(WidgetTester tester, SettingsProvider sp, String text) async {
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: sp,
      child: MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(body: MarkdownWithCodeHighlight(text: text)),
      ),
    ),
  );
  await tester.pump();
}

const _tableMd = '| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| Bob | 25 |';

/// Installs an in-memory clipboard so [Clipboard.setData]/[Clipboard.getData]
/// resolve immediately in the test environment (the platform channel has no
/// host implementation under flutter test and would otherwise hang).
void _mockClipboard(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        _copied = (call.arguments as Map)['text'] as String?;
        return null;
      }
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': _copied};
      }
      return null;
    },
  );
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('renders a toolbar with label, copy and export actions', (tester) async {
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, _tableMd);

    // Toolbar label (en locale).
    expect(find.text('Table'), findsOneWidget);
    // Copy and export actions.
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Export Markdown'), findsOneWidget);
  });

  testWidgets('copy button writes the rebuilt markdown table to the clipboard', (tester) async {
    _mockClipboard(tester);
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, _tableMd);

    await tester.tap(find.text('Copy'));
    // Let the snackbar enter/exit animations finish before the test ends:
    // settle the entrance, fire the 3s auto-dismiss timer, then settle the exit.
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(_copied, '| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| Bob | 25 |');
  });

  testWidgets('a table with math in cells still rebuilds cleanly', (tester) async {
    _mockClipboard(tester);
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, '| X | Y |\n| --- | --- |\n| \$P(A|B)\$ | \$|x|\$ |');

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    // Pipes inside math are protected by EscapeAwareTableMd (no cell split);
    // the rebuilt markdown escapes them again so re-rendering still works.
    expect(_copied, '| X | Y |\n| --- | --- |\n| \$P(A\\|B)\$ | \$\\|x\\|\$ |');
  });
}

String? _copied;
