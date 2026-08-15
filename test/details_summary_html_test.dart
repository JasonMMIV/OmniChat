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

String _pre(String input) => MarkdownWithCodeHighlight.preprocessFences(
      input,
      enableMath: true,
      enableDollarLatex: true,
    );

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  group('preprocessFences masks <details>/<summary> inside fenced code', () {
    test('fenced tag starts are masked; prose details stays intact', () {
      const input = '```html\n'
          '<details>\n'
          '<summary>x</summary>\n'
          '</details>\n'
          '```\n\n'
          '<details>\n'
          '<summary>prose</summary>\n'
          'body\n'
          '</details>';
      final out = _pre(input);
      // Fenced starts masked (mask + tag name without the leading '<').
      expect(
        out,
        contains(
          '${MarkdownWithCodeHighlight.fencedHtmlTagStartMask}details',
        ),
      );
      // Prose details block is untouched.
      expect(out, contains('<details>\n<summary>prose</summary>'));
      // Round-trip restores the original fenced content.
      final restored = MarkdownWithCodeHighlight.unmaskFencedHtmlTagStarts(out);
      expect(restored, contains('<details>\n<summary>x</summary>'));
    });

    test('non-details HTML tags inside fenced code are not masked', () {
      const input = '```html\n<div>hi</div>\n```';
      final out = _pre(input);
      expect(out, contains('<div>hi</div>'));
      expect(out, isNot(contains(MarkdownWithCodeHighlight.fencedHtmlTagStartMask)));
    });
  });

  group('MarkdownWithCodeHighlight details/summary + anchors', () {
    testWidgets('<details> renders collapsible, collapsed by default',
        (tester) async {
      final sp = await _loadedProvider();
      await _pumpMd(
        tester,
        sp,
        '<details>\n<summary>More info</summary>\n\nhidden body text\n</details>',
      );
      expect(find.text('More info'), findsOneWidget);
      // Collapsed: body not visible.
      expect(find.textContaining('hidden body text'), findsNothing);

      await tester.tap(find.text('More info'));
      await tester.pumpAndSettle();
      expect(find.textContaining('hidden body text'), findsOneWidget);
    });

    testWidgets('<details open> renders expanded by default', (tester) async {
      final sp = await _loadedProvider();
      await _pumpMd(
        tester,
        sp,
        '<details open>\n<summary>Visible</summary>\n\nshown body\n</details>',
      );
      expect(find.text('Visible'), findsOneWidget);
      expect(find.textContaining('shown body'), findsOneWidget);
    });

    testWidgets('nested <details> renders both summaries', (tester) async {
      final sp = await _loadedProvider();
      await _pumpMd(
        tester,
        sp,
        '<details>\n<summary>Outer</summary>\n\n<details>\n<summary>Inner</summary>\ninner body\n</details>\n</details>',
      );
      expect(find.text('Outer'), findsOneWidget);
      // Inner summary may be inside the collapsed outer body.
      await tester.tap(find.text('Outer'));
      await tester.pumpAndSettle();
      expect(find.text('Inner'), findsOneWidget);
      await tester.tap(find.text('Inner'));
      await tester.pumpAndSettle();
      expect(find.textContaining('inner body'), findsOneWidget);
    });

    testWidgets('fenced code containing <details> stays literal code',
        (tester) async {
      final sp = await _loadedProvider();
      await _pumpMd(
        tester,
        sp,
        '```html\n<details>\n<summary>Code</summary>\n</details>\n```',
      );
      // The code content renders literally (mask restored at render time).
      expect(
        find.textContaining('<summary>Code</summary>', findRichText: true),
        findsOneWidget,
      );
      // It must not be rendered as a collapsible details header.
      expect(find.text('Code'), findsNothing);
    });

    testWidgets('raw <a href> renders as a tappable link', (tester) async {
      final sp = await _loadedProvider();
      await _pumpMd(
        tester,
        sp,
        'See <a href="https://example.com">example</a> now',
      );
      expect(find.text('example'), findsOneWidget);
    });
  });
}
