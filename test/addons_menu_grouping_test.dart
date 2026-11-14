import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:OmniChat/core/models/answer_review.dart';
import 'package:OmniChat/core/providers/assistant_provider.dart';
import 'package:OmniChat/core/providers/mcp_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/agent/subagent_profiles.dart';
import 'package:OmniChat/features/home/widgets/addons_menu.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// Minimal SettingsProvider double: only the switches AddonsMenuContent reads.
class _FakeSettingsProvider extends ChangeNotifier implements SettingsProvider {
  @override
  bool get planningEnabled => true;

  @override
  AnswerReviewMode get answerReviewMode => AnswerReviewMode.smart;

  @override
  bool isWorkspaceToolEnabled(String toolName) => true;

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
  _FakeSettingsProvider settings,
) async {
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
        home: const Scaffold(
          body: SingleChildScrollView(
            child: AddonsMenuContent(assistantId: null),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
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
    expect(find.byIcon(Lucide.Bot), findsOneWidget);
  });

  testWidgets('the subagent row expands into a switch and profile list', (
    tester,
  ) async {
    final settings = _FakeSettingsProvider();
    addTearDown(settings.dispose);
    await _pumpMenu(tester, settings);

    await tester.tap(find.text('Subagents'));
    await tester.pumpAndSettle();

    expect(find.text('Enable subagents'), findsOneWidget);
    expect(find.text('Explore'), findsOneWidget);
    expect(find.text('General'), findsOneWidget);
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
