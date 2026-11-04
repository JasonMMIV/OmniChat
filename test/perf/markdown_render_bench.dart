import 'dart:async';
import 'dart:io';

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

Widget _wrap(SettingsProvider sp, String text) {
  return ChangeNotifierProvider.value(
    value: sp,
    child: MaterialApp(
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: MarkdownWithCodeHighlight(text: text)),
    ),
  );
}

String _repeatTo(String unit, int targetBytes) {
  final buffer = StringBuffer();
  while (buffer.length < targetBytes) {
    buffer.write(unit);
    buffer.write('\n\n');
  }
  return buffer.toString();
}

void main() {
  final runId = Platform.environment['MARKDOWN_BENCH_RUN'];
  if (runId == null) {
    // `flutter test` still executes main(); make the default a no-op test so
    // CI never pays for the benchmark.
    test(
      'markdown render benchmark (skipped)',
      () {},
      skip: 'Set MARKDOWN_BENCH_RUN=1..5 to run',
    );
    return;
  }

  setUpAll(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('markdown render benchmark', (tester) async {
    final sp = await _loadedProvider();
    final base = File('test/fixtures/markdown/basic_cjk.md').readAsStringSync();

    for (final targetBytes in <int>[10 * 1024, 50 * 1024, 200 * 1024]) {
      final text = _repeatTo(base, targetBytes);
      final stopwatch = Stopwatch()..start();
      await tester.pumpWidget(_wrap(sp, text));
      await tester.pump();
      stopwatch.stop();
      // ignore: avoid_print
      print(
        'MARKDOWN_BENCH run=$runId bytes=$targetBytes '
        'firstPumpMs=${stopwatch.elapsedMilliseconds}',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
}
