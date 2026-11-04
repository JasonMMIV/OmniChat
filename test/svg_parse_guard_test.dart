import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/shared/widgets/svg_parse_guard.dart';

void main() {
  testWidgets('falls back to source when the parse misses its deadline', (tester) async {
    final never = Completer<void>();
    const svg = '<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SvgParseGuard(
            svg: svg,
            timeout: Duration.zero,
            sourceFallback: true,
            parseProbe: () => never.future,
            childBuilder: (_) => const Text('rendered svg'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(tester.takeException(), isNull);
    expect(find.text('rendered svg'), findsNothing);
    expect(find.byType(SelectableText), findsOneWidget);
    final source = tester.widget<SelectableText>(find.byType(SelectableText)).data ?? '';
    expect(source, contains('<svg'));
  });
}
