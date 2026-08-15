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

/// Builds a fenced code block whose first line is unique per test so the
/// static content-addressed state map never leaks between tests.
String _longCode(String lang, String firstLine, int lines) {
  final buffer = StringBuffer('```$lang\n$firstLine\n');
  for (int i = 1; i < lines; i++) {
    buffer.writeln('    line_$i = $i');
  }
  buffer.write('```');
  return buffer.toString();
}

const _expandedKey = ValueKey('code-expanded');

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('auto-collapses a long code block per setting', (tester) async {
    final sp = await _loadedProvider();
    sp.setAutoCollapseCodeBlock(true);
    sp.setAutoCollapseCodeBlockLines(2);

    await _pumpMd(tester, sp, _longCode('python', 'def alpha_function(a):', 8));
    // Long block with auto-collapse on: body hidden.
    expect(find.byKey(_expandedKey), findsNothing);
  });

  testWidgets('manual expansion survives content growth during streaming', (tester) async {
    final sp = await _loadedProvider();
    sp.setAutoCollapseCodeBlock(true);
    sp.setAutoCollapseCodeBlockLines(2);

    final base = _longCode('python', 'def beta_function(a):', 8);
    await _pumpMd(tester, sp, base);
    expect(find.byKey(_expandedKey), findsNothing);

    // Manually expand via the header (language label is inside the InkWell).
    await tester.tap(find.text('python'));
    await tester.pumpAndSettle();
    expect(find.byKey(_expandedKey), findsOneWidget);

    // Streaming: same language + same 16-char anchor, but content grew.
    final grown = _longCode('python', 'def beta_function(a):', 20);
    await _pumpMd(tester, sp, grown);
    // Key unchanged -> manual choice retained.
    expect(find.byKey(_expandedKey), findsOneWidget);
  });

  testWidgets('manual choice is restored after widget recreation (scroll virtualization)', (tester) async {
    final sp = await _loadedProvider();
    sp.setAutoCollapseCodeBlock(true);
    sp.setAutoCollapseCodeBlockLines(2);

    await _pumpMd(tester, sp, _longCode('python', 'def gamma_function(a):', 8));
    expect(find.byKey(_expandedKey), findsNothing);

    await tester.tap(find.text('python'));
    await tester.pumpAndSettle();
    expect(find.byKey(_expandedKey), findsOneWidget);

    // Fully dispose the widget tree (simulates scrolling a message out of view).
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    // Recreate from scratch: the static content-addressed map must restore it.
    await _pumpMd(tester, sp, _longCode('python', 'def gamma_function(a):', 8));
    expect(find.byKey(_expandedKey), findsOneWidget);
  });

  testWidgets('two blocks with different prefixes keep independent state', (tester) async {
    final sp = await _loadedProvider();
    sp.setAutoCollapseCodeBlock(true);
    sp.setAutoCollapseCodeBlockLines(2);

    final both = '${_longCode('python', 'def delta_function(a):', 8)}\n\n'
        '${_longCode('python', 'def epsilon_function(x):', 8)}';
    await _pumpMd(tester, sp, both);
    expect(find.byKey(_expandedKey), findsNothing);

    // Expand the first block only.
    await tester.tap(find.text('python').first);
    await tester.pumpAndSettle();

    // Only one expanded body exists: the second block (different 16-char
    // anchor, never toggled) is still collapsed (shows the collapsed preview).
    expect(find.byKey(_expandedKey), findsOneWidget);
    expect(find.byKey(const ValueKey('code-collapsed')), findsOneWidget);
  });
}
