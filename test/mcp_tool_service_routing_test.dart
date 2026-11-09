import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/providers/mcp_provider.dart';
import 'package:OmniChat/core/services/mcp/mcp_tool_service.dart';

McpToolConfig _tool(String name, {bool enabled = true}) =>
    McpToolConfig(enabled: enabled, name: name);

McpServerConfig _server(String id, List<McpToolConfig> tools) => McpServerConfig(
      id: id,
      enabled: true,
      name: id,
      transport: McpTransportType.inmemory,
      tools: tools,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('McpToolService.resolveCallTarget', () {
    test('routes a stale image_search call to built-in illustrate', () {
      final builtin = _server(
        McpProvider.builtinImageSearchServerId,
        [_tool('illustrate')],
      );

      final target = McpToolService.resolveCallTarget(
        connectedServers: [builtin],
        selected: {McpProvider.builtinImageSearchServerId},
        toolName: 'image_search',
      );

      expect(target.name, 'illustrate');
      expect(target.servers.single.id, McpProvider.builtinImageSearchServerId);
    });

    test('does not route when the built-in illustrate tool is disabled', () {
      final builtin = _server(
        McpProvider.builtinImageSearchServerId,
        [_tool('illustrate', enabled: false)],
      );

      final target = McpToolService.resolveCallTarget(
        connectedServers: [builtin],
        selected: {McpProvider.builtinImageSearchServerId},
        toolName: 'image_search',
      );

      expect(target.name, 'illustrate');
      expect(target.servers, isEmpty);
    });

    test('does not hijack a third-party image_search tool', () {
      final thirdParty = _server('third_party', [_tool('image_search')]);
      final builtin = _server(
        McpProvider.builtinImageSearchServerId,
        [_tool('illustrate')],
      );

      final target = McpToolService.resolveCallTarget(
        connectedServers: [thirdParty, builtin],
        selected: {'third_party', McpProvider.builtinImageSearchServerId},
        toolName: 'image_search',
      );

      expect(target.name, 'image_search');
      expect(target.servers.single.id, 'third_party');
    });

    test('passes through a normal illustrate call', () {
      final builtin = _server(
        McpProvider.builtinImageSearchServerId,
        [_tool('illustrate')],
      );

      final target = McpToolService.resolveCallTarget(
        connectedServers: [builtin],
        selected: {McpProvider.builtinImageSearchServerId},
        toolName: 'illustrate',
      );

      expect(target.name, 'illustrate');
      expect(target.servers, hasLength(1));
    });

    test('ignores servers that are not selected', () {
      final builtin = _server(
        McpProvider.builtinImageSearchServerId,
        [_tool('illustrate')],
      );

      final target = McpToolService.resolveCallTarget(
        connectedServers: [builtin],
        selected: const <String>{},
        toolName: 'image_search',
      );

      expect(target.name, 'illustrate');
      expect(target.servers, isEmpty);
    });
  });
}
