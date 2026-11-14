import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/models/answer_review.dart';
import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/mcp_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/agent/subagent.dart';
import 'package:OmniChat/core/services/agent/subagent_profiles.dart';
import 'package:OmniChat/features/home/widgets/addons_menu.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// Minimal SettingsProvider double: only the switches AddonsMenuContent reads.
class _FakeSettingsProvider extends ChangeNotifier implements SettingsProvider {
  bool subagentEnabled = true;

  @override
  bool get planningEnabled => true;

  @override
  AnswerReviewMode get answerReviewMode => AnswerReviewMode.smart;

  @override
  bool isWorkspaceToolEnabled(String toolName) =>
      toolName == spawnSubagentToolName ? subagentEnabled : true;

  @override
  Future<void> setWorkspaceToolEnabled(String toolName, bool enabled) async {
    if (toolName != spawnSubagentToolName) return;
    subagentEnabled = enabled;
    notifyListeners();
  }

  @override
  List<SubagentProfile> get subagentProfiles => SubagentProfiles.builtIns;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Empty MCP list keeps the menu's MCP group in its "No servers" state.
class _FakeMcpProvider extends ChangeNotifier implements McpProvider {
  @override
  List<McpServerConfig> get servers => const <McpServerConfig>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAssistantProvider extends ChangeNotifier
    implements AssistantProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpMenu(
  WidgetTester tester,
  _FakeSettingsProvider settings, {
  ValueChanged<String>? onDelegateProfile,
}) async {
  tester.view.physicalSize = const Size(420, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final mcp = _FakeMcpProvider();
  final assistant = _FakeAssistantProvider();
  addTearDown(mcp.dispose);
  addTearDown(assistant.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ChangeNotifierProvider<McpProvider>.value(value: mcp),
        ChangeNotifierProvider<AssistantProvider>.value(value: assistant),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: SingleChildScrollView(
            child: AddonsMenuContent(
              assistantId: null,
              onDelegateProfile: onDelegateProfile,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _withPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Subagents lives in Advanced Features', (tester) async {
    final settings = _FakeSettingsProvider();
    addTearDown(settings.dispose);
    await _pumpMenu(tester, settings);

    final builtInY = tester.getTopLeft(find.text('Built-in Tools')).dy;
    final advancedY = tester.getTopLeft(find.text('Advanced Features')).dy;
    final subagentsY = tester.getTopLeft(find.text('Subagents')).dy;
    final reviewY = tester.getTopLeft(find.text('Self-Review')).dy;

    expect(builtInY, lessThan(advancedY));
    expect(subagentsY, greaterThan(advancedY));
    expect(subagentsY, lessThan(reviewY));

    expect(find.text('Write Todos'), findsOneWidget);
    expect(find.text('Ask User'), findsOneWidget);
    expect(find.byIcon(Lucide.UserRoundGroup), findsOneWidget);
    expect(find.byIcon(Lucide.Bot), findsNothing);
  });

  testWidgets('the subagent row opens a separate desktop dialog', (
    tester,
  ) async {
    await _withPlatform(TargetPlatform.windows, () async {
      final settings = _FakeSettingsProvider();
      addTearDown(settings.dispose);
      await _pumpMenu(tester, settings);

      // The toggle and profiles are not expanded inline.
      expect(find.text('Enable subagents'), findsNothing);
      expect(find.text('Explore'), findsNothing);

      await tester.tap(find.text('Subagents'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Enable subagents'), findsOneWidget);
      expect(find.text('Explore'), findsOneWidget);
      expect(find.text('General'), findsOneWidget);
      expect(find.byIcon(Lucide.toggleRight), findsOneWidget);
      expect(find.byIcon(Lucide.Bot), findsNothing);
      expect(find.byIcon(Lucide.UserRoundCheck), findsOneWidget);
      expect(find.byIcon(Lucide.UserRoundSearch), findsOneWidget);
    });
  });

  testWidgets('the subagent menu uses a bottom sheet on mobile', (
    tester,
  ) async {
    await _withPlatform(TargetPlatform.android, () async {
      final settings = _FakeSettingsProvider();
      addTearDown(settings.dispose);
      await _pumpMenu(tester, settings);

      await tester.tap(find.text('Subagents'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Enable subagents'), findsOneWidget);
      expect(find.text('Explore'), findsOneWidget);
    });
  });

  testWidgets('picking a profile from the subagent menu delegates it', (
    tester,
  ) async {
    final settings = _FakeSettingsProvider();
    addTearDown(settings.dispose);
    String? picked;
    await _pumpMenu(tester, settings, onDelegateProfile: (id) => picked = id);

    await tester.tap(find.text('Subagents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Explore'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(picked, 'explore');
    expect(find.text('Enable subagents'), findsNothing);
  });

  testWidgets('the subagent menu can disable the feature', (tester) async {
    await _withPlatform(TargetPlatform.windows, () async {
      final settings = _FakeSettingsProvider();
      addTearDown(settings.dispose);
      await _pumpMenu(tester, settings);
      await tester.tap(find.text('Subagents'));
      await tester.pumpAndSettle();
      expect(settings.subagentEnabled, isTrue);

      await tester.tap(find.text('Enable subagents'));
      await tester.pumpAndSettle();

      expect(settings.subagentEnabled, isFalse);
      expect(
        find.text('Pick a profile to insert an @mention.'),
        findsOneWidget,
      );
    });
  });

  testWidgets('dismissing the subagent menu does not delegate', (tester) async {
    await _withPlatform(TargetPlatform.windows, () async {
      final settings = _FakeSettingsProvider();
      addTearDown(settings.dispose);
      String? picked;
      await _pumpMenu(tester, settings, onDelegateProfile: (id) => picked = id);
      await tester.tap(find.text('Subagents'));
      await tester.pumpAndSettle();

      Navigator.of(tester.element(find.text('Enable subagents'))).pop();
      await tester.pumpAndSettle();

      expect(picked, isNull);
      expect(find.text('Enable subagents'), findsNothing);
    });
  });

  testWidgets('collapsed summaries keep the x/2 counts and review mode', (
    tester,
  ) async {
    final settings = _FakeSettingsProvider();
    addTearDown(settings.dispose);
    await _pumpMenu(tester, settings);

    await tester.tap(find.text('Built-in Tools'));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);

    await tester.tap(find.text('Advanced Features'));
    await tester.pumpAndSettle();
    expect(find.text('2/2 · Smart'), findsOneWidget);
    expect(find.text('Subagents'), findsNothing);
  });
}
