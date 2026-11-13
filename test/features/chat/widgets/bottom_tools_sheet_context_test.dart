import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/instruction_injection_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/desktop/desktop_context_menu.dart';
import 'package:OmniChat/features/chat/widgets/bottom_tools_sheet.dart';
import 'package:OmniChat/features/home/services/context_usage_service.dart';
import 'package:OmniChat/features/home/widgets/context_usage_ring.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

Future<void> _pumpSheet(
  WidgetTester tester, {
  required List<DesktopContextMenuItem> overflowItems,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider(create: (_) => InstructionInjectionProvider()),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: BottomToolsSheet(overflowItems: overflowItems),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('overflow context row is not duplicated by a fixed row', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      overflowItems: [
        DesktopContextMenuItem(
          icon: Lucide.workflow,
          label: 'Context Management',
          onTap: () {},
        ),
      ],
    );

    // The sheet used to append a hard-coded context row at the very bottom
    // in addition to the overflow item, producing two identical entries.
    expect(find.text('Context Management'), findsOneWidget);
  });

  testWidgets('has no fixed context row when the action is not overflowed', (
    tester,
  ) async {
    await _pumpSheet(tester, overflowItems: const <DesktopContextMenuItem>[]);

    expect(find.text('Context Management'), findsNothing);
  });

  testWidgets('overflow context row renders the usage ring', (tester) async {
    final usage = ValueNotifier<ContextUsageSnapshot?>(
      const ContextUsageSnapshot(
        usedTokens: 6600,
        maxTokens: 512000,
        measured: true,
        estimated: false,
      ),
    );
    addTearDown(usage.dispose);

    await _pumpSheet(
      tester,
      overflowItems: [
        DesktopContextMenuItem(
          label: 'Context Management',
          iconBuilder: (color) => ContextUsageButtonIcon(
            usage: usage,
            loading: false,
            color: color,
          ),
          onTap: () {},
        ),
      ],
    );

    expect(find.byType(ContextUsageButtonIcon), findsOneWidget);
  });
}
