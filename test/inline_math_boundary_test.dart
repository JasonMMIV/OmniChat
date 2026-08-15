import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
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

Finder _mathFinder() => find.byType(Math);

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

  group('preprocessFences boundary-aware dollar math scanner', () {
    test(r'currency "Price is $5 and total is $10" is NOT converted to math',
        () {
      const input = r'Price is $5 and total is $10';
      final out = _pre(input);
      expect(out, isNot(contains(r'\(')));
      expect(out, contains(r'$5'));
      expect(out, contains(r'$10'));
    });

    test(r'unmatched single currency dollar is left alone', () {
      const input = r'价格 $10 不渲染';
      final out = _pre(input);
      expect(out, isNot(contains(r'\(')));
      expect(out, contains(r'$10'));
    });

    test(r'closing dollar before a letter does not close math ($x$5)', () {
      final out = _pre(r'$x$5');
      expect(out, isNot(contains(r'\(')));
      expect(out, contains(r'$x$5'));
    });

    test(r'CJK-adjacent math converts: 范围$\pm 2$', () {
      final out = _pre(r'范围$\pm 2$');
      expect(out, contains(r'\(\pm 2\)'));
    });

    test(r'full-width punctuation adjacency converts: 标点：$x+y$。', () {
      final out = _pre(r'标点：$x+y$。');
      expect(out, contains(r'\(x+y\)'));
    });

    test(r'Latin-letter-adjacent math stays literal: abc$x$', () {
      final out = _pre(r'abc$x$');
      expect(out, isNot(contains(r'\(')));
      expect(out, contains(r'abc$x$'));
    });

    test(r'space-separated math converts: a $x$ b', () {
      final out = _pre(r'a $x$ b');
      expect(out, contains(r'\(x\)'));
    });

    test(r'consecutive inline math $a$$b$ converts both', () {
      final out = _pre(r'$a$$b$');
      expect(out, contains(r'\(a\)\(b\)'));
    });

    test(r'escaped dollar \$5 is not treated as math', () {
      final out = _pre(r'cost is \$5 and \$10');
      expect(out, isNot(contains(r'\(')));
      expect(out, contains(r'\$5'));
    });

    test('math body over 512 chars is not converted', () {
      final long = 'x' * 600;
      final out = _pre('\$$long\$');
      expect(out, isNot(contains(r'\(')));
    });

    test(r'pipe in prose math converts (pipes allowed outside tables)', () {
      final out = _pre(r'prose $P(A|B)$ here');
      expect(out, contains(r'\(P(A|B)\)'));
    });

    test(r'pipe in table-row math is left for per-cell handling', () {
      const input = r'| $P(A|B)$ | $q$ |';
      final out = _pre(input);
      // On a table row the `|` is a column separator, so the span stays as-is;
      // EscapeAwareTableMd splits per-cell and the render-time dollar component
      // renders it (pipes allowed there).
      expect(out, isNot(contains(r'\(P(A|B)\)')));
      expect(out, contains(r'$P(A|B)$'));
    });

    test(r'escaped pipes in math convert: $\|x\|=1$', () {
      final out = _pre(r'$\|x\|=1$');
      expect(out, contains(r'\(\|x\|=1\)'));
    });

    test(r'display math $$...$$ is untouched', () {
      final out = _pre(r'$$E=mc^2$$');
      expect(out, contains(r'$$E=mc^2$$'));
    });

    test(r'math does not cross newlines', () {
      final out = _pre('\$x\ny\$');
      expect(out, isNot(contains(r'\(')));
    });
  });

  group('MarkdownWithCodeHighlight rendering', () {
    testWidgets(r'currency renders literally with no math widget',
        (tester) async {
      final sp = await _loadedProvider();
      await _pumpMd(tester, sp, r'Price is $5 and total is $10');
      expect(_mathFinder(), findsNothing);
      expect(find.textContaining(r'$5', findRichText: true), findsOneWidget);
      expect(find.textContaining(r'$10', findRichText: true), findsOneWidget);
    });

    testWidgets(r'CJK-adjacent math renders as math', (tester) async {
      final sp = await _loadedProvider();
      await _pumpMd(tester, sp, r'已知 $q$ 是多项式。');
      expect(_mathFinder(), findsOneWidget);
      expect(find.textContaining(r'$q$', findRichText: true), findsNothing);
    });

    testWidgets(r'table cell math with pipes renders as math', (tester) async {
      final sp = await _loadedProvider();
      await _pumpMd(
        tester,
        sp,
        '| 公式 | 值 |\n|---|---|\n| \$P(A|B)\$ | \$q\$ |',
      );
      expect(_mathFinder(), findsNWidgets(2));
      expect(find.textContaining(r'$P(A', findRichText: true), findsNothing);
      // Table structure intact: header cells present.
      expect(find.textContaining('公式', findRichText: true), findsOneWidget);
      expect(find.textContaining('值', findRichText: true), findsOneWidget);
    });

    testWidgets(r'list item math with pipes renders as math', (tester) async {
      final sp = await _loadedProvider();
      await _pumpMd(tester, sp, r'- Bayes 公式：$P(A|B) = \frac{P(B|A)P(A)}{P(B)}$');
      expect(_mathFinder(), findsOneWidget);
      expect(find.textContaining(r'$P(A|B)', findRichText: true), findsNothing);
    });

    testWidgets('plain table still renders correctly', (tester) async {
      final sp = await _loadedProvider();
      await _pumpMd(tester, sp, '| a | b |\n|---|---|\n| 1 | 2 |');
      expect(find.byType(Table), findsOneWidget);
      // Scope to cell contents: the toolbar labels ('Table'/'Export Markdown')
      // also contain 'a'.
      final cells = find.descendant(of: find.byType(Table), matching: find.byType(EditableText));
      expect(cells, findsNWidgets(4));
      expect(
        find.descendant(
          of: find.byType(Table),
          matching: find.textContaining('a', findRichText: true),
        ),
        findsOneWidget,
      );
    });
  });
}
