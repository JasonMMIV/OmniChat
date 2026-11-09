import 'dart:async';
import 'dart:io';

/// P3-1 browser QA: one-tap preset for the official Playwright MCP server
/// (`@playwright/mcp`), launched over STDIO (desktop-only, like every STDIO
/// MCP server — the model drives it for screenshots / console / click checks
/// against pages served by the P2-4 dev server or any public URL).
///
/// Pure functions only: platform branching takes an explicit [isWindows]
/// flag so the whole file is unit-testable without spawning processes.
abstract final class PlaywrightMcpPreset {
  PlaywrightMcpPreset._();

  /// Display name used for the pre-filled server entry.
  static const String serverName = 'Playwright';

  /// npm package providing the Playwright MCP server.
  static const String npmPackage = '@playwright/mcp';

  /// Windows note: `npx` is a `.cmd` shim that [Process.start] cannot spawn
  /// directly, so the launch goes through `cmd /c`. Pure function of
  /// [isWindows] for testability.
  static ({String command, List<String> args}) launchSpec({bool? isWindows}) {
    final win = isWindows ?? Platform.isWindows;
    return win
        ? (
            command: 'cmd',
            args: <String>['/c', 'npx', '-y', '$npmPackage@latest'],
          )
        : (command: 'npx', args: <String>['-y', '$npmPackage@latest']);
  }
}

/// Human-readable classification for STDIO MCP connect failures. Raw
/// exception strings (e.g. `ProcessException: …`) give no actionable hint
/// for the most common case — the runtime (Node.js / npx / the package) not
/// being installed — so desktop STDIO entries surface this instead.
abstract final class McpStdioDiagnostics {
  McpStdioDiagnostics._();

  /// Maps [error] to a short, actionable description. Falls back to
  /// `error.toString()` for unrecognized shapes so no detail is lost.
  static String describeConnectError(Object error, {String? command}) {
    final cmd = (command == null || command.trim().isEmpty)
        ? 'the configured command'
        : "'${command.trim()}'";
    final runtimeHint =
        'Check that the executable exists and is on PATH '
        '(STDIO MCP servers run outside the app — e.g. the Playwright preset '
        'needs Node.js 20+ with npx), then reconnect.';

    if (error is ProcessException) {
      return 'Failed to launch $cmd: ${error.message}. $runtimeHint';
    }
    if (error is TimeoutException) {
      return 'Timed out waiting for $cmd to initialize. $runtimeHint '
          'The first launch may need to download the package — raise the MCP '
          'request timeout and try again.';
    }
    final msg = error.toString();
    final lower = msg.toLowerCase();
    if (lower.contains('timed out') || lower.contains('timeout')) {
      return 'Timed out waiting for $cmd to initialize. $runtimeHint '
          'The first launch may need to download the package — raise the MCP '
          'request timeout and try again.';
    }
    if (lower.contains('exited') ||
        lower.contains('closed') ||
        lower.contains('handshake') ||
        lower.contains('error code') ||
        lower.contains('non-zero exit')) {
      return 'The MCP server process exited during startup. $runtimeHint '
          'Run the command in a terminal to see the actual error.';
    }
    return msg;
  }
}

/// Parses a user-typed STDIO argument line into argv tokens. Tokens split on
/// whitespace; double-quoted spans stay together (quotes stripped). Blank
/// input yields an empty list. Mirrors the whitespace semantics of the JSON
/// import path (`args` is a string list there) without inventing full shell
/// quoting rules.
List<String> parseStdioArgs(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const <String>[];
  final tokenRe = RegExp(r'"([^"]*)"|(\S+)');
  return <String>[
    for (final m in tokenRe.allMatches(trimmed)) m.group(1) ?? m.group(2)!,
  ];
}
