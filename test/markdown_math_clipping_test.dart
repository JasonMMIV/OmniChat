import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
import 'package:OmniChat/shared/markdown/markdown_math.dart';
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

Future<void> _pumpMd(WidgetTester tester, SettingsProvider sp, String text, {bool isStreaming = false}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: sp,
      child: MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: MarkdownWithCodeHighlight(text: text, isStreaming: isStreaming),
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

  testWidgets('ScrollableBlockMath keeps vertical padding inside the scroll viewport', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        // Column supplies unbounded height to the scroll view (the real chat
        // layout), so the viewport shrink-wraps to content + padding instead
        // of filling a bounded test surface.
        home: Scaffold(
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 320,
                child: ScrollableBlockMath(
                  verticalPadding: 6,
                  child: SizedBox(width: 80, height: 40, child: ColoredBox(color: Colors.blue)),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final scrollFinder = find.byType(SingleChildScrollView);
    expect(scrollFinder, findsOneWidget);
    final scroll = tester.widget<SingleChildScrollView>(scrollFinder);
    expect(scroll.scrollDirection, Axis.horizontal);

    // The padding must be a DESCENDANT of the scroll view; if it wraps the
    // scroll view instead, tall glyph overpaint is clipped by the viewport.
    final paddingFinder = find.descendant(of: scrollFinder, matching: find.byType(Padding)).first;
    final padding = tester.widget<Padding>(paddingFinder);
    expect(padding.padding, const EdgeInsets.symmetric(vertical: 6));

    // Viewport grows by the padding (40 + 6 + 6), leaving glyph ink room.
    expect(tester.getSize(scrollFinder).height, 52);
  });

  testWidgets('```math fence uses the shared scroll container', (tester) async {
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, '```math\n\\frac{a}{b}\n```');
    expect(tester.takeException(), isNull);
    expect(find.byType(ScrollableBlockMath), findsOneWidget);

    await _pumpMd(tester, sp, '```latex\n\\frac{a}{b}\n```');
    expect(tester.takeException(), isNull);
    expect(find.byType(ScrollableBlockMath), findsOneWidget);

    // Partial math waits for the completed frame instead of re-parsing on
    // every streaming tick.
    await _pumpMd(tester, sp, '```math\n\\frac{a}{b}\n```', isStreaming: true);
    expect(find.byType(ScrollableBlockMath), findsNothing);

    await sp.setEnableMathRendering(false);
    await _pumpMd(tester, sp, '```math\n\\frac{a}{b}\n```');
    expect(tester.takeException(), isNull);
    expect(find.byType(ScrollableBlockMath), findsNothing);
  });

  testWidgets('invalid math fence falls back to a copyable code block', (tester) async {
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, '```math\n\\invalid{tex\n```');
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(ScrollableBlockMath), findsNothing);
    expect(find.text('math'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.textContaining('invalid', findRichText: true), findsOneWidget);
  });

  testWidgets('block math in markdown uses the shared scroll container', (tester) async {
    final sp = await _loadedProvider();
    await _pumpMd(tester, sp, r'$$\frac{a}{b}$$');

    expect(find.byType(ScrollableBlockMath), findsOneWidget);

    final paddingInside = find.descendant(of: find.byType(ScrollableBlockMath), matching: find.byType(Padding));
    final paddings = tester.widgetList<Padding>(paddingInside);
    expect(
      paddings.any((p) => p.padding == const EdgeInsets.symmetric(vertical: 6)),
      isTrue,
      reason: 'The 6px vertical padding must sit inside the shared viewport.',
    );
  });
}
