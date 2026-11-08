import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/dev/dev_preview_tools.dart';
import 'package:OmniChat/core/services/dev/dev_server_service.dart';
import 'package:OmniChat/core/services/tools/tool_result_caps.dart';

void main() {
  test('tool definition exposes the documented parameters', () {
    final definition = DevPreviewTools.getConsoleErrorsDefinition();
    final function = definition['function'] as Map<String, dynamic>;
    expect(function['name'], devConsoleErrorsToolName);
    expect(function['name'], 'get_console_errors');
    final properties = ((function['parameters'] as Map)['properties'] as Map)
        .cast<String, dynamic>();
    expect(properties.keys, containsAll(<String>['levels', 'limit']));
    expect((properties['levels'] as Map)['enum'], <String>[
      'errors',
      'warnings',
      'all',
    ]);
  });

  test('returns preview_not_running when no session is open', () async {
    await DevServerService.instance.stop();
    final decoded = jsonDecode(
      DevPreviewTools.handleGetConsoleErrors(<String, dynamic>{}),
    ) as Map<String, dynamic>;
    expect(decoded['type'], 'tool_error');
    expect(decoded['error'], 'preview_not_running');
    expect(decoded['message'].toString(), contains('Preview site'));
  });

  test('reads captured console output through the tool contract', () async {
    final dir = await Directory.systemTemp.createTemp('omnichat_dev_tool_');
    await File('${dir.path}/index.html')
        .writeAsString('<html><body>tool</body></html>');
    final session = await DevServerService.instance.start(
      workspaceRoot: dir.path,
    );
    addTearDown(() async {
      await DevServerService.instance.stop();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    final client = HttpClient();
    try {
      Future<void> post(String level, String message) async {
        final request = await client.postUrl(
          Uri.parse('${session.baseUrl}/__omnichat/console'),
        );
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode(<String, dynamic>{
            'level': level,
            'message': message,
            'source': '/index.html',
            'line': 3,
          }),
        );
        final response = await request.close();
        await response.drain<void>();
      }

      await post('error', 'Uncaught TypeError: x is not a function');
      await post('warn', 'Failed to decode font');
      await post('log', 'ready');

      final errors = jsonDecode(
        DevPreviewTools.handleGetConsoleErrors(<String, dynamic>{}),
      ) as Map<String, dynamic>;
      expect(errors['type'], 'console_errors');
      expect(errors['running'], true);
      expect(errors['counts']['error'], 1);
      expect((errors['entries'] as List).length, 1);
      expect(
        (errors['entries'] as List).single['message'],
        contains('TypeError'),
      );

      final all = jsonDecode(
        DevPreviewTools.handleGetConsoleErrors(<String, dynamic>{
          'levels': 'all',
          'limit': 2,
        }),
      ) as Map<String, dynamic>;
      expect(all['returned'], 2);
      expect(all['omitted'], 1);
      final messages = (all['entries'] as List)
          .map((entry) => entry['message'])
          .toList();
      expect(messages, <String>['Failed to decode font', 'ready']);
    } finally {
      client.close(force: true);
    }
  });

  test('caps oversized console payloads at the shared tool budget', () async {
    final dir = await Directory.systemTemp.createTemp('omnichat_dev_tool_cap_');
    await File('${dir.path}/index.html')
        .writeAsString('<html><body>cap</body></html>');
    final session = await DevServerService.instance.start(
      workspaceRoot: dir.path,
    );
    addTearDown(() async {
      await DevServerService.instance.stop();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    final client = HttpClient();
    try {
      final message = 'x' * 2000;
      for (var i = 0; i < 30; i++) {
        final request = await client.postUrl(
          Uri.parse('${session.baseUrl}/__omnichat/console'),
        );
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode(<String, dynamic>{
            'level': 'error',
            'message': '$i $message',
          }),
        );
        final response = await request.close();
        await response.drain<void>();
      }
    } finally {
      client.close(force: true);
    }

    final result = DevPreviewTools.handleGetConsoleErrors(<String, dynamic>{
      'levels': 'errors',
      'limit': 100,
    });
    expect(result.length, lessThanOrEqualTo(ToolResultCaps.capThresholdChars));
    expect(result, contains(ToolResultCaps.truncationMarkerPrefix));
    expect(result, contains('Re-run the tool'));
  });
}
