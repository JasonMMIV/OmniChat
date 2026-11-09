import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/mcp_provider.dart';

Map<String, dynamic> _server({
  required String id,
  required List<Map<String, dynamic>> tools,
}) => {
      'id': id,
      'enabled': true,
      'name': id == 'image_search' ? 'Image_Search' : 'Third_Party',
      'transport': 'inmemory',
      'tools': tools,
    };

Map<String, dynamic> _tool(String name, {bool enabled = true}) => {
      'enabled': enabled,
      'name': name,
    };

Future<String?> _storedRaw() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString('mcp_servers_v1');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('migrateBuiltinImageSearchToolName', () {
    test('renames the built-in tool and preserves a disabled toggle',
        () async {
      final raw = jsonEncode(<Map<String, dynamic>>[
        _server(
          id: 'image_search',
          tools: [_tool('image_search', enabled: false)],
        ),
      ]);
      SharedPreferences.setMockInitialValues({'mcp_servers_v1': raw});

      await McpProvider.migrateBuiltinImageSearchToolName();

      final stored = jsonDecode((await _storedRaw())!) as List;
      final tools = (stored.first as Map)['tools'] as List;
      expect(tools, hasLength(1));
      expect((tools.first as Map)['name'], 'illustrate');
      expect((tools.first as Map)['enabled'], isFalse);
    });

    test('is idempotent and does not rewrite an already migrated list',
        () async {
      final raw = jsonEncode(<Map<String, dynamic>>[
        _server(
          id: 'image_search',
          tools: [_tool('illustrate', enabled: false)],
        ),
      ]);
      SharedPreferences.setMockInitialValues({'mcp_servers_v1': raw});

      await McpProvider.migrateBuiltinImageSearchToolName();

      expect(await _storedRaw(), raw);
    });

    test('skips when both legacy and new names are present', () async {
      final raw = jsonEncode(<Map<String, dynamic>>[
        _server(
          id: 'image_search',
          tools: [
            _tool('image_search', enabled: false),
            _tool('illustrate'),
          ],
        ),
      ]);
      SharedPreferences.setMockInitialValues({'mcp_servers_v1': raw});

      await McpProvider.migrateBuiltinImageSearchToolName();

      expect(await _storedRaw(), raw);
    });

    test('never touches a third-party server exposing image_search', () async {
      final raw = jsonEncode(<Map<String, dynamic>>[
        _server(
          id: 'third_party',
          tools: [_tool('image_search', enabled: false)],
        ),
      ]);
      SharedPreferences.setMockInitialValues({'mcp_servers_v1': raw});

      await McpProvider.migrateBuiltinImageSearchToolName();

      expect(await _storedRaw(), raw);
    });

    test('handles a server without a tools list safely', () async {
      final raw = jsonEncode(<Map<String, dynamic>>[
        {
          'id': 'image_search',
          'enabled': true,
          'name': 'Image_Search',
          'transport': 'inmemory',
        },
      ]);
      SharedPreferences.setMockInitialValues({'mcp_servers_v1': raw});

      await McpProvider.migrateBuiltinImageSearchToolName();

      expect(await _storedRaw(), raw);
    });

    test('ignores malformed JSON safely', () async {
      SharedPreferences.setMockInitialValues({'mcp_servers_v1': '{not json'});

      await McpProvider.migrateBuiltinImageSearchToolName();

      expect(await _storedRaw(), '{not json');
    });

    test('no-ops when prefs are empty', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      await McpProvider.migrateBuiltinImageSearchToolName();

      expect(await _storedRaw(), isNull);
    });
  });
}
