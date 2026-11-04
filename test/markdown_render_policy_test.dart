import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/l10n/app_localizations.dart';
import 'package:OmniChat/shared/markdown/markdown_render_policy.dart';
import 'package:OmniChat/shared/widgets/markdown_callout_card.dart';
import 'package:OmniChat/shared/widgets/markdown_with_highlight.dart';

const _richMarkdown = '''
> [!NOTE]
> Alert body.

:::tip
Directive body.
:::

**standard bold**

<p>html block</p>

<details><summary>More</summary>hidden</details>

<script>alert(1)</script>
''';

Widget _host(MarkdownRenderPolicy policy) {
  return ChangeNotifierProvider<SettingsProvider>.value(
    value: SettingsProvider(),
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: MarkdownWithCodeHighlight(text: _richMarkdown, renderPolicy: policy),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('standard policy keeps rich document syntax literal', (tester) async {
    await tester.pumpWidget(_host(MarkdownRenderPolicy.standard));
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownCalloutCard), findsNothing);
    expect(find.textContaining('standard bold'), findsWidgets);
    expect(find.textContaining('[!NOTE]'), findsWidgets);
    expect(find.textContaining(':::tip'), findsWidgets);
    expect(find.textContaining('<p>'), findsWidgets);
    expect(find.textContaining('<details>'), findsWidgets);
    expect(find.textContaining('\uE002'), findsNothing);
    expect(find.textContaining('alert(1)'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('full policy still renders alert and directive cards', (tester) async {
    await tester.pumpWidget(_host(MarkdownRenderPolicy.full));
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownCalloutCard), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
