import 'dart:convert';

import '../tools/tool_result_caps.dart';
import 'dev_server_service.dart';

/// Model tool that reads console output captured by the live site preview.
///
/// P2-4 closes the "write → see it run → fix" loop: the preview page posts its
/// `console.error` / `window.onerror` output to the loopback dev server, and
/// the model can fetch those messages after editing files.
const String devConsoleErrorsToolName = 'get_console_errors';

class DevPreviewTools {
  DevPreviewTools._();

  static Map<String, dynamic> getConsoleErrorsDefinition() {
    return <String, dynamic>{
      'type': 'function',
      'function': {
        'name': devConsoleErrorsToolName,
        'description':
            'Read console errors and warnings captured from the live site preview '
            '(the same messages a developer sees in browser DevTools). Use this after '
            'writing or editing HTML/CSS/JS to check for runtime errors, failed loads '
            'or unhandled promise rejections. The preview reloads automatically after '
            'file changes; call this once the page had a moment to settle. Returns the '
            'newest entries. Read-only; requires an open site preview panel.',
        'parameters': {
          'type': 'object',
          'properties': {
            'levels': {
              'type': 'string',
              'enum': ['errors', 'warnings', 'all'],
              'description':
                  'Which captured messages to return. errors (default) = console.error '
                  'and uncaught exceptions; warnings = console.warn; all = every level '
                  'including logs.',
            },
            'limit': {
              'type': 'integer',
              'description': 'Maximum number of newest entries to return (1-100, default 20).',
            },
          },
        },
      },
    };
  }

  /// Handles a `get_console_errors` call.
  ///
  /// Returns a structured `tool_error` when no preview is open — the model
  /// should not guess console contents, and the message tells it how the user
  /// can open the panel.
  static String handleGetConsoleErrors(Map<String, dynamic> args) {
    final session = DevServerService.instance.activeSession;
    if (session == null || session.isClosed) {
      return jsonEncode(<String, dynamic>{
        'type': 'tool_error',
        'error': 'preview_not_running',
        'message':
            'The live site preview is not open, so no console output is being '
            'captured. Ask the user to open the workspace menu and choose '
            '"Preview site" (or open an HTML file in the workspace browser), '
            'then retry.',
        'tool': devConsoleErrorsToolName,
      });
    }
    final levels = (args['levels'] ?? 'errors').toString().trim();
    final rawLimit = args['limit'];
    final limit = rawLimit is num ? rawLimit.toInt() : 20;
    final payload = session.consoleErrorsJson(
      levels: levels.isEmpty ? 'errors' : levels,
      limit: limit,
    );
    return ToolResultCaps.cap(
      toolName: devConsoleErrorsToolName,
      result: payload,
    );
  }
}
