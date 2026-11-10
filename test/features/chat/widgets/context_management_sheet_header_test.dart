// ContextManagementSheet header tests (docs/context_usage_ring_plan.md v2).
//
// The sheet shows a usage header row above the options when a snapshot with a
// known window is available; while the window is unknown the header renders
// nothing and the sheet keeps its original spacing.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/chat/widgets/context_management_sheet.dart';
import 'package:OmniChat/features/home/services/context_usage_service.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// IosCardPress reads the haptics preference on tap; a minimal double keeps
/// the test independent of the full settings load (same trick as
/// todo_plan_card_test.dart).
class _FakeSettings extends ChangeNotifier implements SettingsProvider {
  @override
  bool get hapticsOnCardTap => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget wrapSheet({
  ValueListenable<ContextUsageSnapshot?>? contextUsage,
  void Function()? onCompress,
  void Function()? onClear,
}) {
  return ChangeNotifierProvider<SettingsProvider>.value(
    value: _FakeSettings(),
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ContextManagementSheet(
          contextUsage: contextUsage,
          onCompress: onCompress,
          onClear: onClear,
        ),
      ),
    ),
  );
}

const _knownWindow = ContextUsageSnapshot(
  usedTokens: 12345,
  maxTokens: 200000,
  measured: true,
  estimated: false,
);

void main() {
  testWidgets('header shows above the options when the window is known',
      (tester) async {
    await tester.pumpWidget(
      wrapSheet(contextUsage: ValueNotifier<ContextUsageSnapshot?>(_knownWindow)),
    );
    expect(find.text('12.3k / 200.0k Token'), findsOneWidget);
    expect(find.byIcon(Lucide.package2), findsOneWidget);
    expect(find.byIcon(Lucide.Eraser), findsOneWidget);
  });

  testWidgets('header is absent while the window is unknown; options intact',
      (tester) async {
    await tester.pumpWidget(
      wrapSheet(contextUsage: ValueNotifier<ContextUsageSnapshot?>(null)),
    );
    expect(find.textContaining('Token'), findsNothing);
    expect(find.byIcon(Lucide.package2), findsOneWidget);
    expect(find.byIcon(Lucide.Eraser), findsOneWidget);
  });

  testWidgets('option callbacks still fire with a header present',
      (tester) async {
    var compressed = false;
    var cleared = false;
    await tester.pumpWidget(wrapSheet(
      contextUsage: ValueNotifier<ContextUsageSnapshot?>(_knownWindow),
      onCompress: () => compressed = true,
      onClear: () => cleared = true,
    ));
    await tester.tap(find.byIcon(Lucide.package2));
    await tester.pump();
    expect(compressed, isTrue);
    await tester.tap(find.byIcon(Lucide.Eraser));
    await tester.pump();
    expect(cleared, isTrue);
  });

  testWidgets('header reacts to a notifier update while open', (tester) async {
    final notifier = ValueNotifier<ContextUsageSnapshot?>(null);
    await tester.pumpWidget(wrapSheet(contextUsage: notifier));
    expect(find.textContaining('Token'), findsNothing);

    notifier.value = _knownWindow;
    await tester.pumpAndSettle();
    expect(find.textContaining('Token'), findsOneWidget);
  });
}
