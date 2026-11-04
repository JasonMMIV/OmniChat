import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:OmniChat/shared/widgets/markdown_callout_card.dart';
import 'package:OmniChat/shared/widgets/markdown_with_highlight.dart';
import 'package:OmniChat/shared/widgets/safe_svg_text.dart';

bool _hasStyledText(InlineSpan span, String text, bool Function(TextStyle style) test, [TextStyle? inherited]) {
  if (span is! TextSpan) return false;
  final effective = inherited == null ? span.style : inherited.merge(span.style);
  if (span.text == text && effective != null && test(effective)) {
    return true;
  }
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (_hasStyledText(child, text, test, effective)) return true;
  }
  return false;
}

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

Future<void> _pumpMarkdown(WidgetTester tester, SettingsProvider sp, String input, {bool isStreaming = true}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: sp,
      child: MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownWithCodeHighlight(text: input, isStreaming: isStreaming),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('all markdown fixtures preprocess without throwing', () {
    final dir = Directory('test/fixtures/markdown');
    expect(dir.existsSync(), isTrue, reason: 'fixture directory missing');

    final files = dir.listSync().whereType<File>().where((file) => file.path.toLowerCase().endsWith('.md')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    expect(files.length, greaterThanOrEqualTo(9));

    for (final file in files) {
      final input = file.readAsStringSync();
      for (final streaming in <bool>[false, true]) {
        final output = MarkdownWithCodeHighlight.preprocessFences(
          input,
          enableMath: true,
          enableDollarLatex: true,
          streaming: streaming,
        );
        expect(output, isNotEmpty, reason: '${file.path} (streaming=$streaming)');
      }
    }
  });

  testWidgets('renderable fixtures build without exceptions', (tester) async {
    // Mermaid/PlantUML are intentionally excluded: they spawn a real WebView
    // when not streaming, which is covered by the dedicated widget tests.
    const names = <String>[
      'alerts.md',
      'basic_cjk.md',
      'block_html.md',
      'code.md',
      'directives.md',
      'inline_html.md',
      'inline_svg.md',
      'math.md',
      'wallpaper.md',
    ];

    final sp = await _loadedProvider();
    for (final name in names) {
      final input = File('test/fixtures/markdown/$name').readAsStringSync();
      await _pumpMarkdown(tester, sp, input);
      expect(tester.takeException(), isNull, reason: name);

      // Streaming defers code highlighting; exercise the completed path too so
      // the syntax-tree cache / palette cannot regress unnoticed.
      if (name == 'code.md') {
        await _pumpMarkdown(tester, sp, input, isStreaming: false);
        expect(tester.takeException(), isNull, reason: '$name (completed)');
      }
    }
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'late frame errors');
  });

  testWidgets('GitHub alerts render chrome and body, including custom titles', (tester) async {
    final sp = await _loadedProvider();
    final input = File('test/fixtures/markdown/alerts.md').readAsStringSync();
    await _pumpMarkdown(tester, sp, input, isStreaming: false);
    expect(tester.takeException(), isNull);

    for (final title in <String>['Note', 'Tip', 'Important', 'Warning', 'Caution']) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(find.text('Custom title'), findsOneWidget);
    // The link becomes a WidgetSpan placeholder, so assert the text prefix
    // rather than the full sentence.
    expect(find.textContaining('Note body with a', findRichText: true), findsOneWidget);
    final firstItem = find.textContaining('first item', findRichText: true);
    final secondItem = find.textContaining('second item', findRichText: true);
    expect(firstItem, findsOneWidget);
    expect(secondItem, findsOneWidget);
    // Distinct widgets prove the list body did not collapse into one paragraph.
    expect(identical(tester.widget(firstItem), tester.widget(secondItem)), isFalse);
    expect(find.textContaining('Custom title body', findRichText: true), findsOneWidget);

    final disabledSelection = tester
        .widgetList<SelectionContainer>(find.byType(SelectionContainer))
        .where((widget) => widget.delegate == null);
    expect(disabledSelection, isNotEmpty);
  });

  testWidgets('inline HTML whitelist styles safe tags and drops active tags', (tester) async {
    final sp = await _loadedProvider();
    final input = File('test/fixtures/markdown/inline_html.md').readAsStringSync();
    await _pumpMarkdown(tester, sp, input, isStreaming: false);
    expect(tester.takeException(), isNull);

    final richTexts = tester.widgetList<RichText>(find.byType(RichText));
    bool hasStyle(String text, bool Function(TextStyle style) test) {
      return richTexts.any((rich) => _hasStyledText(rich.text, text, test));
    }

    expect(hasStyle('bold', (s) => s.fontWeight == FontWeight.w700), isTrue);
    expect(hasStyle('italic', (s) => s.fontStyle == FontStyle.italic), isTrue);
    expect(hasStyle('underline', (s) => s.decoration?.contains(TextDecoration.underline) ?? false), isTrue);
    expect(hasStyle('strike', (s) => s.decoration?.contains(TextDecoration.lineThrough) ?? false), isTrue);
    expect(hasStyle('mark', (s) => s.backgroundColor != null), isTrue);
    expect(hasStyle('Ctrl', (s) => s.fontFamily == 'monospace'), isTrue);
    expect(
      hasStyle('green bold span', (s) => s.fontWeight == FontWeight.w700 && s.color == const Color(0xFF007700)),
      isTrue,
    );
    expect(hasStyle('highlight span', (s) => s.backgroundColor != null), isTrue);
    expect(hasStyle('font blue', (s) => s.color == const Color(0xFF0000FF)), isTrue);
    expect(hasStyle('safe subset', (s) => s.color == const Color(0xFFCC0000)), isTrue);
    expect(hasStyle('low contrast span', (s) => s.color != null && s.color != const Color(0xFFFFFFFF)), isTrue);

    final allText = richTexts.map((rich) => rich.text.toPlainText()).join('\n');
    expect(allText, contains('anchor'));
    expect(find.text('formatted anchor'), findsOneWidget);
    expect(allText, isNot(contains('<a ')));
    expect(find.text('bad anchor'), findsOneWidget);
    expect(allText, contains('Line one'));
    expect(allText, contains('Line two'));
    expect(allText, isNot(contains('<br')));
    expect(allText, isNot(contains('<b>')));
    expect(allText, isNot(contains('<sub>')));
    expect(allText, isNot(contains('<span')));
    expect(allText, isNot(contains('<font')));
    expect(allText, isNot(contains('<script>')));
    expect(allText, isNot(contains('xss')));
    expect(allText, isNot(contains('onerror')));
  });

  testWidgets('inline SVG renders safe SVGs and rejects active content', (tester) async {
    final sp = await _loadedProvider();
    final input = File('test/fixtures/markdown/inline_svg.md').readAsStringSync();
    await _pumpMarkdown(tester, sp, input, isStreaming: false);

    expect(tester.takeException(), isNull);
    expect(find.byType(SafeSvgText), findsNWidgets(2));
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.byIcon(Icons.broken_image), findsOneWidget);

    final allText = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((rich) => rich.text.toPlainText())
        .join('\n');
    expect(allText, isNot(contains('<svg')));
    expect(allText, isNot(contains('alert(1)')));
  });

  testWidgets('block HTML renders paragraphs, lists, quotes and pre', (tester) async {
    final sp = await _loadedProvider();
    final input = File('test/fixtures/markdown/block_html.md').readAsStringSync();
    await _pumpMarkdown(tester, sp, input, isStreaming: false);

    expect(tester.takeException(), isNull);
    final allText = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((rich) => rich.text.toPlainText())
        .join('\n');
    expect(allText, contains('Paragraph with bold and green.'));
    expect(allText, contains('Safe paragraph'));
    expect(allText, contains('Div paragraph with italic.'));
    expect(allText, contains('Section paragraph.'));
    expect(allText, contains('Name'));
    expect(allText, contains('Alpha'));
    expect(allText, isNot(contains('block xss')));
    expect(allText, contains('first item'));
    expect(allText, contains('second item'));
    expect(allText, contains('one'));
    expect(allText, contains('two'));
    expect(allText, contains('outer item'));
    expect(allText, contains('inner item'));
    expect(allText, isNot(contains('</ul>')));
    expect(allText, contains('Quoted text.'));
    expect(allText, contains('code & more'));
    expect(allText, isNot(contains('<p>')));
    expect(allText, isNot(contains('<ul>')));
    expect(allText, isNot(contains('<blockquote>')));
    expect(allText, isNot(contains('<pre>')));
    expect(allText, isNot(contains('<div')));
    expect(allText, isNot(contains('<section')));
    expect(allText, isNot(contains('<table')));

    // NOTE: gpt_markdown normalizes indentation before block components see
    // it, so 4-space indented code containing block tags is not reliably
    // distinguishable here; keep it documented in the plan and use fenced code
    // when the source matters.
  });

  testWidgets('inline SVG inside a code span stays literal', (tester) async {
    final sp = await _loadedProvider();
    await _pumpMarkdown(tester, sp, '`<svg width="4" height="4"></svg>`', isStreaming: false);

    expect(tester.takeException(), isNull);
    expect(find.byType(SafeSvgText), findsNothing);
    expect(find.textContaining('<svg', findRichText: true), findsOneWidget);
  });

  testWidgets('directives render cards, custom titles, lists and fallback', (tester) async {
    final sp = await _loadedProvider();
    final input = File('test/fixtures/markdown/directives.md').readAsStringSync();
    await _pumpMarkdown(tester, sp, input, isStreaming: false);
    expect(tester.takeException(), isNull);

    // note, tip and warning are known; :::unknown preserves children without
    // drawing a fourth card.
    expect(find.byType(MarkdownCalloutCard), findsNWidgets(3));
    expect(find.text('Note'), findsOneWidget);
    expect(find.text('自訂標題'), findsOneWidget);
    expect(find.text('Warning'), findsOneWidget);

    expect(find.textContaining('Directive note body', findRichText: true), findsOneWidget);
    expect(find.textContaining('Directive tip body with', findRichText: true), findsOneWidget);
    expect(find.textContaining('Unknown directive should preserve', findRichText: true), findsOneWidget);
    expect(find.textContaining(':::unknown', findRichText: true), findsNothing);

    final firstList = find.textContaining('list item', findRichText: true).first;
    final allListItems = find.textContaining('list item', findRichText: true).evaluate().length;
    expect(allListItems, 2);
    expect(tester.widget(firstList), isNotNull);

    // A `:::` line inside a code fence must stay literal code, not a card.
    await _pumpMarkdown(tester, sp, '```\n:::note\nnot a card\n:::\n```', isStreaming: false);
    expect(tester.takeException(), isNull);
    expect(find.byType(MarkdownCalloutCard), findsNothing);
    expect(find.textContaining(':::note', findRichText: true), findsOneWidget);

    // Empty body must still render the card (no literal :::note text).
    await _pumpMarkdown(tester, sp, ':::note\n:::', isStreaming: false);
    expect(tester.takeException(), isNull);
    expect(find.byType(MarkdownCalloutCard), findsOneWidget);
    expect(find.textContaining(':::note', findRichText: true), findsNothing);

    // A directive that never closes keeps its partial card after the stream
    // finishes instead of snapping back to literal markers.
    await _pumpMarkdown(tester, sp, ':::note\npartial body', isStreaming: false);
    expect(tester.takeException(), isNull);
    expect(find.byType(MarkdownCalloutCard), findsOneWidget);
    expect(find.textContaining('partial body', findRichText: true), findsOneWidget);

    // An unclosed fence must still shield ::: lines while streaming.
    await _pumpMarkdown(tester, sp, '```\n:::note\ninside fence', isStreaming: true);
    expect(tester.takeException(), isNull);
    expect(find.byType(MarkdownCalloutCard), findsNothing);
    expect(find.textContaining(':::note', findRichText: true), findsOneWidget);

    // An unclosed directive still renders a partial card while streaming.
    await _pumpMarkdown(tester, sp, ':::note\npartial body', isStreaming: true);
    expect(tester.takeException(), isNull);
    expect(find.byType(MarkdownCalloutCard), findsOneWidget);
    expect(find.textContaining('partial body', findRichText: true), findsOneWidget);
  });
}
