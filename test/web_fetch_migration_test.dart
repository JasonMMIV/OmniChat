import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/mcp_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';

Future<McpProvider> _loadedMcp() async {
  final provider = McpProvider();
  final done = Completer<void>();
  void listener() {
    if (!done.isCompleted) done.complete();
  }

  provider.addListener(listener);
  await done.future.timeout(const Duration(seconds: 10));
  provider.removeListener(listener);
  return provider;
}

Map<String, dynamic> _legacyFetchEntry({required bool toolsEnabled}) => {
  'id': 'kelivo_fetch',
  'enabled': true,
  'name': '@kelivo/fetch',
  'transport': 'inmemory',
  'tools': [
    {'enabled': toolsEnabled, 'name': 'fetch_html'},
    {'enabled': toolsEnabled, 'name': 'fetch_markdown'},
    {'enabled': toolsEnabled, 'name': 'fetch_txt'},
    {'enabled': toolsEnabled, 'name': 'fetch_json'},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('applyLegacyFetchMigration', () {
    test('removes the entry and turns fetch off when all tools are off', () async {
      SharedPreferences.setMockInitialValues({
        'mcp_servers_v1': jsonEncode(<Map<String, dynamic>>[
          _legacyFetchEntry(toolsEnabled: false),
          {
            'id': 'run_js',
            'enabled': true,
            'name': 'run-javascript',
            'transport': 'inmemory',
          },
        ]),
      });

      await McpProvider.applyLegacyFetchMigration();

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('mcp_servers_v1')!;
      expect(raw, isNot(contains('kelivo_fetch')));
      expect(raw, contains('run_js'));
      expect(prefs.getBool(SettingsProvider.webFetchEnabledKey), isFalse);
    });

    test('turns fetch on when any tool is on', () async {
      SharedPreferences.setMockInitialValues({
        'mcp_servers_v1': jsonEncode(<Map<String, dynamic>>[
          _legacyFetchEntry(toolsEnabled: true),
        ]),
      });

      await McpProvider.applyLegacyFetchMigration();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(SettingsProvider.webFetchEnabledKey), isTrue);
    });

    test('new installs default to enabled', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await McpProvider.applyLegacyFetchMigration();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(SettingsProvider.webFetchEnabledKey), isTrue);
    });

    test('is idempotent', () async {
      SharedPreferences.setMockInitialValues({
        'mcp_servers_v1': jsonEncode(<Map<String, dynamic>>[
          _legacyFetchEntry(toolsEnabled: false),
        ]),
        SettingsProvider.webFetchEnabledKey: true,
      });
      await McpProvider.applyLegacyFetchMigration();
      await McpProvider.applyLegacyFetchMigration();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(SettingsProvider.webFetchEnabledKey), isFalse);
    });
  });

  group('replaceAllFromJson built-in flags', () {
    test('fetch, run_js, academic and image search stay independent', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final mcp = await _loadedMcp();

      await mcp.replaceAllFromJson(
        jsonEncode(<String, dynamic>{
          'mcpServers': <String, dynamic>{
            'kelivo_fetch': {
              'name': '@kelivo/fetch',
              'type': 'inmemory',
              'isActive': false,
            },
            'run_js': {
              'name': 'run-javascript',
              'type': 'inmemory',
              'isActive': true,
            },
            'academic_search': {
              'name': 'Academic_Search',
              'type': 'inmemory',
              'isActive': false,
            },
            'image_search': {
              'name': 'Image_Search',
              'type': 'inmemory',
              'isActive': true,
            },
          },
        }),
      );

      final byId = <String, McpServerConfig>{
        for (final server in mcp.servers) server.id: server,
      };
      expect(byId.containsKey('kelivo_fetch'), isFalse);
      expect(byId['run_js']!.enabled, isTrue);
      expect(byId['academic_search']!.enabled, isFalse);
      expect(byId['image_search']!.enabled, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(SettingsProvider.webFetchEnabledKey), isFalse);

      final exported = mcp.exportServersAsUiJson();
      expect(exported, isNot(contains('kelivo/fetch')));
    });
  });
}
