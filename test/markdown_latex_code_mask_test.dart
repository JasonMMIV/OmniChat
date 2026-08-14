import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
import 'package:OmniChat/shared/widgets/markdown_with_highlight.dart';

/// 建立已載入完成的真實 SettingsProvider（_load 完成後會 notifyListeners）。
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

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  group('preprocessFences masks code dollars before LaTeX conversion', () {
    test(r'prose $...$ still converts; inline code dollars stay shielded', () {
      const input = r'use `a $b$ c` and $x^2$';
      final out = MarkdownWithCodeHighlight.preprocessFences(
        input,
        enableMath: true,
        enableDollarLatex: true,
      );
      // Prose math is still normalized to \(...\).
      expect(out, contains(r'\(x^2\)'));
      // Code dollars are masked, not converted.
      expect(out, isNot(contains(r'\(b\)')));
      expect(out, contains(MarkdownWithCodeHighlight.codeDollarMask));
      // Round-trip restores the original code content.
      expect(
        MarkdownWithCodeHighlight.unmaskCodeDollars(out),
        contains(r'a $b$ c'),
      );
    });

    test('fenced code dollars stay shielded', () {
      const input = '```dart\n\$x\$ = 5\n```\n\nprose \$y\$\n';
      final out = MarkdownWithCodeHighlight.preprocessFences(
        input,
        enableMath: true,
        enableDollarLatex: true,
      );
      expect(out, contains(r'\(y\)')); // prose converted
      expect(out, isNot(contains(r'\(x\)'))); // code not converted
      expect(
        MarkdownWithCodeHighlight.unmaskCodeDollars(out),
        contains(r'$x$ = 5'),
      );
    });

    test(r'display-math $$ inside code is not treated as a math block', () {
      const input = '```\nprint(\$\$)\n```\n\nprose \$\$E=mc^2\$\$\n';
      final out = MarkdownWithCodeHighlight.preprocessFences(
        input,
        enableMath: true,
        enableDollarLatex: true,
      );
      // The fenced line keeps its $$ intact (masked -> unmasked round trip).
      expect(
        MarkdownWithCodeHighlight.unmaskCodeDollars(out),
        contains(r'print($$)'),
      );
      // Prose display math still present.
      expect(out, contains(r'$$E=mc^2$$'));
    });

    test('masking runs even when dollar LaTeX is disabled', () {
      const input = r'`$PATH$` and plain $5';
      final out = MarkdownWithCodeHighlight.preprocessFences(
        input,
        enableMath: false,
        enableDollarLatex: false,
      );
      // No conversion anywhere, but code dollars are still shielded.
      expect(out, contains(MarkdownWithCodeHighlight.codeDollarMask));
      expect(
        MarkdownWithCodeHighlight.unmaskCodeDollars(out),
        contains(r'$PATH$'),
      );
    });

    test('prose without code is never masked', () {
      const input = r'price $5 and $x^2$ formula';
      final out = MarkdownWithCodeHighlight.preprocessFences(
        input,
        enableMath: true,
        enableDollarLatex: true,
      );
      expect(out, isNot(contains(MarkdownWithCodeHighlight.codeDollarMask)));
    });
  });

  group('MarkdownWithCodeHighlight rendering', () {
    testWidgets(r'inline code renders $ literally, prose math does not leak',
        (tester) async {
      final sp = await _loadedProvider();
      await _pumpMd(tester, sp, r'run `a $b$ c` and $x^2$');

      // Inline code content is restored exactly (mask -> unmask at render).
      expect(find.text(r'a $b$ c'), findsOneWidget);
      // The converted prose math must not leak raw \(...\) text.
      expect(find.textContaining(r'\(x^2\)'), findsNothing);
      // No mask placeholder may leak into the UI.
      expect(
        find.textContaining(MarkdownWithCodeHighlight.codeDollarMask),
        findsNothing,
      );
    });

    testWidgets(r'fenced code renders $ literally', (tester) async {
      final sp = await _loadedProvider();
      await _pumpMd(tester, sp, '```\n\$x\$ = 5\n```');

      expect(find.textContaining(r'$x$ = 5', findRichText: true), findsOneWidget);
      expect(find.textContaining(r'\(x\)'), findsNothing);
    });

    testWidgets(r'inline code renders $ literally when math is disabled',
        (tester) async {
      final sp = await _loadedProvider();
      await sp.setEnableMathRendering(false);
      await _pumpMd(tester, sp, r'keep `$PATH$` literally');

      expect(find.text(r'$PATH$'), findsOneWidget);
      expect(
        find.textContaining(MarkdownWithCodeHighlight.codeDollarMask),
        findsNothing,
      );
    });
  });
}
