// ProcessGroupCard widget tests — PLAN_PROCESS_FOLDING.md Phase 2. Pins the
// shell contract: the label flips 處理中.../Working… → 已完成/Worked on the
// live verdict, the toggle callback fires from the header, the body rows
// follow the open state, the elapsed timer renders fixed spans once finished
// and the zh_Hant wording matches the user-facing spec.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/chat/widgets/process_group_card.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

Widget _wrap(
  Widget child, {
  Locale locale = const Locale('en'),
}) {
  // IosCardPress reads SettingsProvider inside its gesture handler — provide
  // one, mirroring the ai_team_proposals_section_test.dart setup.
  return ChangeNotifierProvider<SettingsProvider>.value(
    value: SettingsProvider(),
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      theme: ThemeData.light(),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  testWidgets(
      'finished group: Worked label, body visible when open, hidden when closed',
      (tester) async {
    var toggles = 0;
    await tester.pumpWidget(_wrap(
      ProcessGroupCard(
        live: false,
        open: true,
        onToggle: () => toggles++,
        children: const [Text('ROW-1'), Text('ROW-2')],
      ),
    ));
    await tester.pump();

    expect(find.text('Worked'), findsOneWidget);
    expect(find.text('Working...'), findsNothing);
    expect(find.text('ROW-1'), findsOneWidget);
    expect(find.text('ROW-2'), findsOneWidget);

    await tester.tap(find.text('Worked'));
    await tester.pump();
    expect(toggles, 1);

    // Closed → body rows gone (AnimatedSize collapse), header stays.
    await tester.pumpWidget(_wrap(
      ProcessGroupCard(
        live: false,
        open: false,
        children: const [Text('ROW-1')],
      ),
    ));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('ROW-1'), findsNothing);
    expect(find.text('Worked'), findsOneWidget);
  });

  testWidgets(
      'live group: Working... label + bounce dots, animates without settling',
      (tester) async {
    final base = DateTime(2026, 10, 5, 12, 0, 0);
    await tester.pumpWidget(_wrap(
      ProcessGroupCard(
        live: true,
        open: true,
        startAt: base,
        children: const [Text('ROW-1')],
      ),
    ));
    // Fixed DateTime.now() anchors only the *initial* elapsed text; keep the
    // assertion on the label + dots instead of the moving number.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Working...'), findsOneWidget);
    expect(find.text('Worked'), findsNothing);
    expect(
      find.byKey(const ValueKey('process-group-dots')),
      findsOneWidget,
    );
    expect(find.text('ROW-1'), findsOneWidget);

    // The repeating dots/shimmer/ticker must never fail pump with a timeout.
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Working...'), findsOneWidget);
  });

  testWidgets('elapsed timer renders the fixed span once finished',
      (tester) async {
    final base = DateTime(2026, 10, 5, 12, 0, 0);
    await tester.pumpWidget(_wrap(
      ProcessGroupCard(
        live: false,
        open: false,
        startAt: base,
        finishedAt: base.add(const Duration(milliseconds: 1500)),
      ),
    ));
    await tester.pump();

    expect(find.text('(1.5s)'), findsOneWidget);
  });

  testWidgets('no startAt → no elapsed text even while live', (tester) async {
    await tester.pumpWidget(_wrap(
      ProcessGroupCard(live: true, open: false),
    ));
    await tester.pump();

    expect(find.text('Working...'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('process-group-dots')),
      findsOneWidget,
    );
    // No "(x.xs)" elapsed text anywhere.
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').startsWith('('),
      ),
      findsNothing,
    );
  });

  testWidgets('zh_Hant wording: 處理中... while live, 已完成 when finished',
      (tester) async {
    final base = DateTime(2026, 10, 5, 12, 0, 0);
    await tester.pumpWidget(_wrap(
      ProcessGroupCard(
        live: true,
        open: false,
        startAt: base,
        finishedAt: null,
      ),
      // The app resolves zh_Hant via the script code (settings_provider.dart
      // `_appLocale` → Locale.fromSubtags(zh, Hant)); a bare zh_TW locale
      // falls to the base zh class (simplified).
      locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    ));
    await tester.pump();
    expect(find.text('處理中...'), findsOneWidget);

    await tester.pumpWidget(_wrap(
      ProcessGroupCard(
        live: false,
        open: false,
        startAt: base,
        finishedAt: base.add(const Duration(milliseconds: 800)),
      ),
      locale: const Locale('zh', 'TW'),
    ));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('處理中...'), findsNothing);
  });
}
