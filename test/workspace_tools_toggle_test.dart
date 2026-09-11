import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/models/workspace_config.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/features/home/services/tool_handler_service.dart';

/// A minimal SettingsProvider double: only the workspace-tool toggle API is
/// overridden (everything else is never touched by the pure static builder).
class _ToggleSettingsProvider extends ChangeNotifier
    implements SettingsProvider {
  _ToggleSettingsProvider({Set<String> disabled = const <String>{}})
    : _disabled = disabled;

  final Set<String> _disabled;

  @override
  bool isWorkspaceToolEnabled(String toolName) =>
      !_disabled.contains(toolName);

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

      // Re-enabling removes the name from the disabled set.
      await reloaded.setWorkspaceToolEnabled('file_read', true);
      expect(reloaded.isWorkspaceToolEnabled('file_read'), isTrue);
    });
  });

  group('ToolHandlerService.buildWorkspaceToolDefinitions', () {
    test('returns all 17 workspace tools when everything is enabled', () {
      final defs = ToolHandlerService.buildWorkspaceToolDefinitions(
        _ToggleSettingsProvider(),
        workspaceEnabled: true,
      );
      final names = defs
          .map((d) => ((d['function'] as Map)['name'] ?? '').toString())
          .toList();
      expect(names.length, 17);
      expect(names, contains('file_read'));
      expect(names, contains('file_create_pdf'));
      expect(names, contains('write_todos'));
      expect(names, contains('ask_user'));
    });

    test('a disabled tool is filtered out', () {
      final defs = ToolHandlerService.buildWorkspaceToolDefinitions(
        _ToggleSettingsProvider(disabled: {'file_read', 'ask_user'}),
        workspaceEnabled: true,
      );
      final names = defs
          .map((d) => ((d['function'] as Map)['name'] ?? '').toString())
          .toList();
      expect(names, isNot(contains('file_read')));
      expect(names, isNot(contains('ask_user')));
      expect(names.length, 15);
    });

    test('workspace disabled turns every workspace tool off', () {
      final defs = ToolHandlerService.buildWorkspaceToolDefinitions(
        _ToggleSettingsProvider(),
        workspaceEnabled: false,
      );
      expect(defs, isEmpty);
    });
  });
}
