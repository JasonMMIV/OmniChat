// Gate 1 spike only: this test expects gpt_markdown 1.4.0 from the local,
// gitignored pubspec_overrides.yaml. It is skipped unless explicitly enabled:
//   flutter test --dart-define=GATE1_MODERN_GPT_MARKDOWN=true \
//     test/gate1_modern_spike_test.dart
// See docs/markdown_rendering_import_plan.md.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

const _gate1ModernMarkdown = bool.fromEnvironment('GATE1_MODERN_GPT_MARKDOWN');

void main() {
  testWidgets('gpt_markdown 1.4 renders HTML tables inside a Flutter Material host', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4C6FFF))),
        home: const Scaffold(
          body: GptMarkdown(
            '<table><tr><th>Name</th><th>Value</th></tr>'
            '<tr><td>Alpha</td><td>1</td></tr></table>',
            isStreaming: false,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Alpha', findRichText: true), findsOneWidget);
    expect(find.textContaining('Name', findRichText: true), findsOneWidget);
  }, skip: !_gate1ModernMarkdown);
}
