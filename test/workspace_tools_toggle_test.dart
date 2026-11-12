import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/workspace_config.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/chat/pages/workspace_tools_page.dart';
import 'package:OmniChat/features/home/services/tool_handler_service.dart';
import 'package:OmniChat/icons/lucide_adapter.dart';
import 'package:OmniChat/l10n/app_localizations.dart';

/// A minimal SettingsProvider double: only the workspace-tool toggle API is
/// overridden (everything else is never touched by the pure static builder).
class _ToggleSettingsProvider extends ChangeNotifier
    implements SettingsProvider {
  _ToggleSettingsProvider({
    Set<String> disabled = const <String>{},
    this.planningEnabled = true,
  }) : _disabled = disabled;

  final Set<String> _disabled;

  @override
  final bool planningEnabled;

  @override
  bool isWorkspaceToolEnabled(String toolName) => !_disabled.contains(toolName);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WorkspaceConfig toggle memory', () {
    test('disabledFrom remembers and restores the prior config', () {
      const prior = WorkspaceConfig.custom('/projects/demo');
      final disabled = WorkspaceConfig.disabledFrom(prior);

      expect(disabled.mode, WorkspaceMode.disabled);
      expect(disabled.isEnabled, isFalse);
      expect(disabled.previous, prior);
      expect(disabled.restoreOnEnable, prior);

      // JSON round-trip keeps the remembered config.
      final decoded = WorkspaceConfig.fromJson(disabled.toJson());
      expect(decoded.mode, WorkspaceMode.disabled);
      expect(decoded.previous, prior);

      // A disabled config without memory restores project inheritance.
      expect(
        const WorkspaceConfig.disabled().restoreOnEnable,
        const WorkspaceConfig.inheritProject(),
      );
    });

    test('disabling twice keeps the memory chain at depth one', () {
      const prior = WorkspaceConfig.custom('/a');
      final once = WorkspaceConfig.disabledFrom(prior);
      final twice = WorkspaceConfig.disabledFrom(once);
      expect(twice.previous, prior);
      expect(twice.previous?.previous, isNull);
    });

    test('legacy disabled JSON decodes without previous', () {
      final decoded = WorkspaceConfig.fromJson(<String, dynamic>{
        'mode': 'disabled',
      });
      expect(decoded.mode, WorkspaceMode.disabled);
      expect(decoded.previous, isNull);
    });
  });

  group('SettingsProvider workspace tool toggles', () {
    testWidgets('persist disabled tools across reload', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});

      final settings = SettingsProvider();
      addTearDown(settings.dispose);
      await tester.pumpAndSettle(const Duration(milliseconds: 50));

      expect(settings.isWorkspaceToolEnabled('file_read'), isTrue);
      await settings.setWorkspaceToolEnabled('file_read', false);
      await settings.setWorkspaceToolEnabled('ask_user', false);
      expect(settings.isWorkspaceToolEnabled('file_read'), isFalse);
      expect(settings.isWorkspaceToolEnabled('ask_user'), isFalse);
      expect(settings.isWorkspaceToolEnabled('file_write'), isTrue);

      final reloaded = SettingsProvider();
      addTearDown(reloaded.dispose);
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(reloaded.isWorkspaceToolEnabled('file_read'), isFalse);
      expect(reloaded.isWorkspaceToolEnabled('ask_user'), isFalse);
      expect(reloaded.isWorkspaceToolEnabled('write_todos'), isTrue);

      // Planning is its own persisted switch, independent of the workspace
      // tool list (Phase 3-4).
      expect(settings.planningEnabled, isTrue);
      await settings.setPlanningEnabled(false);
      expect(settings.planningEnabled, isFalse);
      final reloadedPlanning = SettingsProvider();
      addTearDown(reloadedPlanning.dispose);
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(reloadedPlanning.planningEnabled, isFalse);

      // Re-enabling removes the name from the disabled set.
      await reloaded.setWorkspaceToolEnabled('file_read', true);
      expect(reloaded.isWorkspaceToolEnabled('file_read'), isTrue);
    });
  });

  group('ToolHandlerService.buildWorkspaceToolDefinitions', () {
    test('returns the 19 workspace tools when everything is enabled', () {
      final defs = ToolHandlerService.buildWorkspaceToolDefinitions(
        _ToggleSettingsProvider(),
        workspaceEnabled: true,
      );
      final names = defs
          .map((d) => ((d['function'] as Map)['name'] ?? '').toString())
          .toList();
      expect(names.length, 19);
      expect(names, contains('file_read'));
      expect(names, contains('shell_run'));
      expect(names, contains('file_create_pdf'));
      expect(names, isNot(contains('write_todos')));
      // ask_user left the workspace gate on 2026-11-10 (Add-ons menu owns it
      // now); it is offered via buildDecisionToolDefinitions regardless.
      expect(names, isNot(contains('ask_user')));
      expect(names, contains('get_console_errors'));
      expect(names, contains('file_grep'));
      expect(names, contains('file_view_image'));
    });

    test('a disabled tool is filtered out', () {
      final defs = ToolHandlerService.buildWorkspaceToolDefinitions(
        _ToggleSettingsProvider(disabled: {'file_read'}),
        workspaceEnabled: true,
      );
      final names = defs
          .map((d) => ((d['function'] as Map)['name'] ?? '').toString())
          .toList();
      expect(names, isNot(contains('file_read')));
      expect(names.length, 18);
    });

    test('workspace disabled turns every workspace tool off', () {
      final defs = ToolHandlerService.buildWorkspaceToolDefinitions(
        _ToggleSettingsProvider(),
        workspaceEnabled: false,
      );
      expect(defs, isEmpty);
    });

    test('Android shell_exec is gated by the explicit availability flag', () {
      List<String> names(List<Map<String, dynamic>> defs) => defs
          .map((d) => ((d['function'] as Map)['name'] ?? '').toString())
          .toList();

      final off = ToolHandlerService.buildWorkspaceToolDefinitions(
        _ToggleSettingsProvider(),
        workspaceEnabled: true,
        shellExecAvailable: false,
      );
      expect(names(off), isNot(contains('shell_exec')));

      final on = ToolHandlerService.buildWorkspaceToolDefinitions(
        _ToggleSettingsProvider(),
        workspaceEnabled: true,
        shellExecAvailable: true,
      );
      expect(names(on), contains('shell_exec'));
      expect(names(on).where((name) => name == 'shell_exec').length, 1);
    });
  });

  group('ToolHandlerService.buildPlanningToolDefinitions (Phase 3-4)', () {
    List<String> names(List<Map<String, dynamic>> defs) => defs
        .map((d) => ((d['function'] as Map)['name'] ?? '').toString())
        .toList();

    test('offered without a workspace (planning is conversation-level)', () {
      final defs = ToolHandlerService.buildPlanningToolDefinitions(
        _ToggleSettingsProvider(),
      );
      expect(names(defs), ['write_todos']);
    });

    test('planning switch off → no tool', () {
      final defs = ToolHandlerService.buildPlanningToolDefinitions(
        _ToggleSettingsProvider(planningEnabled: false),
      );
      expect(defs, isEmpty);
    });

    test('legacy per-tool disable still wins', () {
      final defs = ToolHandlerService.buildPlanningToolDefinitions(
        _ToggleSettingsProvider(disabled: {'write_todos'}),
      );
      expect(defs, isEmpty);
    });

    test('description carries the maintenance contract', () {
      final defs = ToolHandlerService.buildPlanningToolDefinitions(
        _ToggleSettingsProvider(),
      );
      final description =
          ((defs.single['function'] as Map)['description'] ?? '').toString();
      expect(description, contains('After completing EACH todo step'));
      expect(description, contains('rewrite'));
      expect(description, contains('COMPLETE list'));
      expect(description, contains('never drop or shorten the list'));
      expect(description, contains('todos: [] only when'));
    });
  });

  group('ToolHandlerService.buildDecisionToolDefinitions (2026-11-10)', () {
    List<String> names(List<Map<String, dynamic>> defs) => defs
        .map((d) => ((d['function'] as Map)['name'] ?? '').toString())
        .toList();

    test('offered by default — ask_user no longer needs the workspace', () {
      final defs = ToolHandlerService.buildDecisionToolDefinitions(
        _ToggleSettingsProvider(),
      );
      expect(names(defs), ['ask_user']);
    });

    test('the Add-ons (built-in tools) per-tool toggle wins', () {
      final defs = ToolHandlerService.buildDecisionToolDefinitions(
        _ToggleSettingsProvider(disabled: {'ask_user'}),
      );
      expect(defs, isEmpty);
    });
  });

  group('WorkspaceToolsPage presentation', () {
    testWidgets('shows localized names and group headers without raw ids', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      addTearDown(settings.dispose);
      await tester.pumpAndSettle(const Duration(milliseconds: 50));

      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>.value(
          value: settings,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const WorkspaceToolsPage(),
          ),
        ),
      );
      await tester.pump();

      // Section labels are uppercased by the page.
      expect(find.text('READ & INSPECT'), findsOneWidget);
      expect(find.text('Read file'), findsOneWidget);
      // Raw tool ids no longer appear under the localized names.
      expect(find.text('file_read'), findsNothing);
      expect(find.text('WRITE & EDIT'), findsOneWidget);
      expect(find.text('Edit file'), findsOneWidget);
      expect(find.text('Search contents'), findsOneWidget);
      expect(find.text('Apply patch'), findsOneWidget);
      expect(find.textContaining('file_patch'), findsNothing);
      expect(find.text('Run command'), findsOneWidget);
      expect(find.text('shell_run'), findsNothing);

      // Tool icons use the theme accent, matching the permission rows above
      // them, instead of ListTile's default grey.
      final primary = Theme.of(tester.element(find.text('Read file')))
          .colorScheme
          .primary;
      final icon = tester.widget<Icon>(find.byIcon(Lucide.FileText).first);
      expect(icon.color, primary);
    });
  });
}
