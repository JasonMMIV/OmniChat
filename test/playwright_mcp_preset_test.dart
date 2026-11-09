import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/providers/mcp_provider.dart';
import 'package:OmniChat/core/services/mcp/playwright_mcp_preset.dart';

void main() {
  group('PlaywrightMcpPreset.launchSpec', () {
    test('windows wraps npx in cmd /c (npx is a batch shim)', () {
      final spec = PlaywrightMcpPreset.launchSpec(isWindows: true);
      expect(spec.command, 'cmd');
      expect(spec.args, <String>['/c', 'npx', '-y', '@playwright/mcp@latest']);
    });

    test('posix launches npx directly', () {
      final spec = PlaywrightMcpPreset.launchSpec(isWindows: false);
      expect(spec.command, 'npx');
      expect(spec.args, <String>['-y', '@playwright/mcp@latest']);
    });

    test('display name is stable (used as the pre-filled server name)', () {
      expect(PlaywrightMcpPreset.serverName, 'Playwright');
    });
  });

  group('parseStdioArgs', () {
    test('splits on whitespace', () {
      expect(
        parseStdioArgs('-y @playwright/mcp@latest --browser chrome'),
        <String>['-y', '@playwright/mcp@latest', '--browser', 'chrome'],
      );
    });

    test('keeps quoted spans together and strips the quotes', () {
      expect(parseStdioArgs('--caps "tab,vision"  -y'), <String>[
        '--caps',
        'tab,vision',
        '-y',
      ]);
    });

    test('blank input yields an empty list', () {
      expect(parseStdioArgs('   '), isEmpty);
      expect(parseStdioArgs(''), isEmpty);
    });
  });

  group('McpStdioDiagnostics.describeConnectError', () {
    test('ProcessException names the executable and points at Node.js', () {
      final msg = McpStdioDiagnostics.describeConnectError(
        const ProcessException('npx', [
          '-y',
          '@playwright/mcp@latest',
        ], 'No such file or directory'),
        command: 'npx',
      );
      expect(msg, contains("'npx'"));
      expect(msg, contains('Node.js'));
      expect(msg, contains('No such file or directory'));
    });

    test('TimeoutException gets the first-download hint', () {
      final msg = McpStdioDiagnostics.describeConnectError(
        TimeoutException('Initialize request timed out'),
        command: 'cmd',
      );
      expect(msg.toLowerCase(), contains('timed out'));
      expect(msg, contains('request timeout'));
    });

    test('string-shaped timeouts are classified the same way', () {
      final msg = McpStdioDiagnostics.describeConnectError(
        StateError('Request timed out while waiting for initialize'),
        command: 'npx',
      );
      expect(msg.toLowerCase(), contains('timed out'));
    });

    test('process exiting during startup points at the terminal', () {
      final msg = McpStdioDiagnostics.describeConnectError(
        Exception('Connection closed before handshake completed'),
        command: 'cmd',
      );
      expect(msg, contains('exited during startup'));
      expect(msg, contains('terminal'));
    });

    test('unknown errors pass through unchanged', () {
      final msg = McpStdioDiagnostics.describeConnectError(
        Exception('something odd happened'),
      );
      expect(msg, contains('something odd happened'));
    });

    test('missing command falls back to generic wording', () {
      final msg = McpStdioDiagnostics.describeConnectError(
        const ProcessException('', [], 'Cannot find file'),
      );
      expect(msg, contains('the configured command'));
    });
  });

  /// Locks the exact copyWith call the STDIO save path in the server edit
  /// sheet relies on (clearing an emptied working directory).
  group('McpServerConfig.copyWith (STDIO save contract)', () {
    test('clearWorkingDirectory nulls the field; json round-trip drops it', () {
      final cfg = McpServerConfig(
        id: 's',
        enabled: true,
        name: 'n',
        transport: McpTransportType.stdio,
        command: 'npx',
        args: const ['-y', '@playwright/mcp@latest'],
        workingDirectory: r'D:\old',
      );
      final cleared = cfg.copyWith(
        transport: McpTransportType.stdio,
        command: 'npx',
        args: const <String>[],
        env: const <String, String>{},
        workingDirectory: null,
        clearWorkingDirectory: true,
      );
      expect(cleared.workingDirectory, isNull);
      expect(cleared.command, 'npx');

      final json = cleared.toJson();
      expect(json.containsKey('workingDirectory'), isFalse);
      expect(McpServerConfig.fromJson(json).workingDirectory, isNull);
    });

    test('keeping a filled working directory round-trips', () {
      final cfg = McpServerConfig(
        id: 's',
        enabled: true,
        name: 'n',
        transport: McpTransportType.stdio,
        command: 'cmd',
        args: const ['/c', 'npx'],
        workingDirectory: r'D:\site',
      );
      final json = cfg.toJson();
      final restored = McpServerConfig.fromJson(json);
      expect(restored.workingDirectory, r'D:\site');
      expect(restored.args, <String>['/c', 'npx']);
      expect(restored.transport, McpTransportType.stdio);
    });
  });
}
