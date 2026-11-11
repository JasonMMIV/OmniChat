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
import 'package:OmniChat/l10n/app_localizations.dart';

Future<void> _pumpBar(
  WidgetTester tester, {
  required ValueListenable<ContextUsageSnapshot?>? usage,
  required VoidCallback onOpenContextManagement,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider(create: (_) => AssistantProvider()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChatInputBar(
            contextUsage: usage,
            showMoreButton: true,
            onClearContext: () {},
            onCompressContext: () {},
            onOpenContextManagement: onOpenContextManagement,
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

  testWidgets('narrow layout pins the context ring next to plus/send', (
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
}
