import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/home/services/context_usage_service.dart';
import 'package:OmniChat/features/home/widgets/chat_input_bar.dart';
import 'package:OmniChat/features/home/widgets/context_usage_ring.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

Future<void> _pumpBar(
  WidgetTester tester, {
  required ValueListenable<ContextUsageSnapshot?>? usage,
  VoidCallback? onOpenContextManagement,
  VoidCallback? onRefreshContextUsage,
  bool showMoreButton = true,
  bool withOverflowActions = false,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider(create: (_) => AssistantProvider()),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChatInputBar(
            contextUsage: usage,
            showMoreButton: showMoreButton,
            onClearContext: () {},
            onCompressContext: () {},
            onOpenContextManagement: onOpenContextManagement,
            onRefreshContextUsage: onRefreshContextUsage,
            // Extra buttons so the wide-layout row overflows at a testable
            // window width (the default order puts `context` second-to-last).
            onStartDictation: withOverflowActions ? () {} : null,
            onPickCamera: withOverflowActions ? () {} : null,
            onPickPhotos: withOverflowActions ? () {} : null,
            onUploadFiles: withOverflowActions ? () {} : null,
            onToggleAiTeam: withOverflowActions ? () {} : null,
            onToggleInstructionInjection:
                withOverflowActions ? () {} : null,
            onOpenSkills: withOverflowActions ? () {} : null,
            onVoiceChat: withOverflowActions ? () {} : null,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('narrow layout shows the context ring in the action row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final usage = ValueNotifier<ContextUsageSnapshot?>(
      const ContextUsageSnapshot(
        usedTokens: 6600,
        maxTokens: 512000,
        measured: true,
        estimated: false,
      ),
    );
    addTearDown(usage.dispose);
    var opened = false;

    await _pumpBar(
      tester,
      usage: usage,
      onOpenContextManagement: () => opened = true,
    );

    expect(find.byType(ContextUsageButtonIcon), findsOneWidget);
    // Not pinned next to the plus button: at least one action button must sit
    // between the ring and the plus (the pinned layout kept them one spacing
    // apart, ~24px between centers).
    final ringX = tester.getCenter(find.byType(ContextUsageButtonIcon)).dx;
    final plusX = tester.getCenter(find.byIcon(Lucide.Plus)).dx;
    expect(plusX - ringX, greaterThan(40));
    await tester.tap(find.byType(ContextUsageButtonIcon));
    await tester.pump();
    expect(opened, isTrue);
  });

  testWidgets('narrow layout does not add a context button without a ring', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpBar(tester, usage: null, onOpenContextManagement: () {});

    expect(find.byType(ContextUsageButtonIcon), findsNothing);
  });

  testWidgets(
      'overflowed context action anchors the menu to the plus button',
      (tester) async {
    // Wide layout with enough buttons that `context` (second-to-last in the
    // default order) is pushed behind the `+` overflow menu. Its own anchor is
    // not mounted there, so the menu must anchor to the `+` button instead of
    // silently doing nothing.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final usage = ValueNotifier<ContextUsageSnapshot?>(
      const ContextUsageSnapshot(
        usedTokens: 6600,
        maxTokens: 512000,
        measured: true,
        estimated: false,
      ),
    );
    addTearDown(usage.dispose);
    var opened = false;

    await _pumpBar(
      tester,
      usage: usage,
      showMoreButton: false,
      withOverflowActions: true,
      onOpenContextManagement: () => opened = true,
    );

    expect(find.byType(ContextUsageButtonIcon), findsNothing);
    await tester.tap(find.byIcon(Lucide.Plus));
    await tester.pumpAndSettle();
    // The overflow row must keep the usage ring instead of the plain icon.
    expect(find.byType(ContextUsageButtonIcon), findsOneWidget);
    await tester.tap(find.text('Context Management'));
    await tester.pumpAndSettle();
    // The wide layout keeps the anchored menu (now anchored to `+`) with the
    // usage header — before the fix this tap was a silent no-op.
    expect(find.text('6.6k / 512.0k'), findsOneWidget);
    expect(find.text('Compress Context'), findsOneWidget);
    expect(find.text('Clear Context'), findsOneWidget);
    expect(opened, isFalse);
  });

  testWidgets('desktop context button refreshes usage before opening the menu', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final usage = ValueNotifier<ContextUsageSnapshot?>(
      const ContextUsageSnapshot(
        usedTokens: 6600,
        maxTokens: 512000,
        measured: true,
        estimated: false,
      ),
    );
    addTearDown(usage.dispose);
    var refreshed = false;

    await _pumpBar(
      tester,
      usage: usage,
      showMoreButton: false,
      onRefreshContextUsage: () => refreshed = true,
    );

    await tester.tap(find.byTooltip('Context Management'));
    await tester.pumpAndSettle();
    expect(refreshed, isTrue);
  });
}
