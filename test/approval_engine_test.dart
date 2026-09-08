// P1-1 approval engine unit tests (IMPORT_PLAN_COWORK.md P1-1; ADR-A5/A8/A9).
//
// Covers the pure-Dart policy engine: the three-decision classification
// (allow / ask / deny) across the v1.5 policy sources (workspace boundary →
// ask, MCP tools → default ask, "always allow" overrides, strict mode), and
// the structured pending / denied / timeout tool-result JSON contracts.

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/approval.dart';

// Re-exported private helpers are not accessible; use the public key shapes.
String _mcpToolKey(String serverId, String toolName) =>
    'mcp:$serverId:$toolName';
String _mcpServerKey(String serverId) => 'mcp-server:$serverId';

void main() {
  group('decideApproval — workspace tools', () {
    test('inside the sandbox → allow', () {
      final d = decideApproval(const ApprovalContext(
        isWorkspaceTool: true,
        pathInsideWorkspace: true,
        resolvedPath: '/ws/notes.md',
      ));
      expect(d, equals(ApprovalDecision.allow));
    });

    test('path outside the workspace → ask (ADR-A8 v1.5)', () {
      final d = decideApproval(const ApprovalContext(
        isWorkspaceTool: true,
        pathInsideWorkspace: false,
        resolvedPath: 'D:/Reports/q3.docx',
      ));
      expect(d, equals(ApprovalDecision.ask));
    });

    test('out-of-workspace path with a persisted override → allow', () {
      final d = decideApproval(const ApprovalContext(
        isWorkspaceTool: true,
        pathInsideWorkspace: false,
        resolvedPath: 'D:/Reports/q3.docx',
        alwaysAllowedKeys: {'workspace-out:D:/Reports/q3.docx'},
      ));
      expect(d, equals(ApprovalDecision.allow));
    });

    test('strict mode degrades an out-of-workspace ask to deny', () {
      final d = decideApproval(const ApprovalContext(
        isWorkspaceTool: true,
        pathInsideWorkspace: false,
        resolvedPath: 'D:/Reports/q3.docx',
        strictMode: true,
      ));
      expect(d, equals(ApprovalDecision.deny));
    });

    test('strict mode does not deny in-sandbox calls', () {
      final d = decideApproval(const ApprovalContext(
        isWorkspaceTool: true,
        pathInsideWorkspace: true,
        strictMode: true,
      ));
      expect(d, equals(ApprovalDecision.allow));
    });
  });

  group('decideApproval — MCP tools', () {
    test('MCP tool → ask by default (v1.5 black-box policy)', () {
      final d = decideApproval(const ApprovalContext(
        isMcpTool: true,
        mcpServerId: 'srv1',
        mcpToolName: 'fetch',
      ));
      expect(d, equals(ApprovalDecision.ask));
    });

    test('per-tool override → allow', () {
      final d = decideApproval(ApprovalContext(
        isMcpTool: true,
        mcpServerId: 'srv1',
        mcpToolName: 'fetch',
        alwaysAllowedKeys: {_mcpToolKey('srv1', 'fetch')},
      ));
      expect(d, equals(ApprovalDecision.allow));
    });

    test('per-server override → allow', () {
      final d = decideApproval(ApprovalContext(
        isMcpTool: true,
        mcpServerId: 'srv1',
        mcpToolName: 'fetch',
        alwaysAllowedKeys: {_mcpServerKey('srv1')},
      ));
      expect(d, equals(ApprovalDecision.allow));
    });

    test('override for another tool does not leak', () {
      final d = decideApproval(ApprovalContext(
        isMcpTool: true,
        mcpServerId: 'srv1',
        mcpToolName: 'fetch',
        alwaysAllowedKeys: {_mcpToolKey('srv1', 'other')},
      ));
      expect(d, equals(ApprovalDecision.ask));
    });

    test('strict mode degrades an MCP ask to deny', () {
      final d = decideApproval(const ApprovalContext(
        isMcpTool: true,
        mcpServerId: 'srv1',
        mcpToolName: 'fetch',
        strictMode: true,
      ));
      expect(d, equals(ApprovalDecision.deny));
    });
  });

  group('decideApproval — other tools', () {
    test('search / memory / todo / ask_user → allow', () {
      for (final ctx in const [
        ApprovalContext(),
        ApprovalContext(isWorkspaceTool: false),
      ]) {
        expect(decideApproval(ctx), equals(ApprovalDecision.allow));
      }
    });
  });

  group('structured content contracts', () {
    test('pending content carries tool, path, outside flag and args', () {
      final json = buildApprovalPendingContent(
        toolName: 'file_write',
        resolvedPath: 'D:/Reports/q3.docx',
        outsideWorkspace: true,
        arguments: const {'path': '../q3.docx'},
      );
      final parsed = parseApprovalContent(json);
      expect(parsed, isNotNull);
      expect(parsed!['type'], equals(approvalRequiredType));
      expect(parsed['tool'], equals('file_write'));
      expect(parsed['resolved_path'], equals('D:/Reports/q3.docx'));
      expect(parsed['outside_workspace'], isTrue);
      expect(parsed['arguments'], isA<Map>());
    });

    test('denied content is a structured error the model can act on', () {
      final parsed = parseApprovalContent(
        buildApprovalDeniedContent(toolName: 'file_write'),
      );
      expect(parsed, isNotNull);
      expect(parsed!['type'], equals(approvalDeniedType));
      expect(parsed['error'], equals('approval_denied'));
    });

    test('timeout content marks approval_timeout without execution', () {
      final parsed = parseApprovalContent(
        buildApprovalTimeoutContent(toolName: 'file_write'),
      );
      expect(parsed, isNotNull);
      expect(parsed!['type'], equals(approvalRequiredType));
      expect(parsed['error'], equals('approval_timeout'));
    });

    test('non-approval content parses to null', () {
      expect(parseApprovalContent(null), isNull);
      expect(parseApprovalContent(''), isNull);
      expect(parseApprovalContent('{"type":"ask_user_pending"}'), isNull);
      expect(parseApprovalContent('not json'), isNull);
    });
  });

  group('edit preview diff', () {
    test('builds a line-based unified diff from old_text/new_text', () {
      final diff = buildEditPreviewDiff(const {
        'old_text': 'line1\nline2\nline3',
        'new_text': 'line1\nline2 changed\nline4',
      });
      expect(diff, isNotNull);
      expect(diff!, startsWith('--- a/old\n+++ b/new'));
      expect(diff!, contains('\n-line1\n-line2\n-line3'));
      expect(diff!, contains('\n+line1\n+line2 changed\n+line4'));
    });

    test('single-line replacement renders both sides', () {
      final diff = buildEditPreviewDiff(
          const {'old_text': 'foo', 'new_text': 'bar'});
      expect(diff, isNotNull);
      expect(diff!, contains('\n-foo\n+bar'));
    });

    test('null when empty or unchanged', () {
      expect(buildEditPreviewDiff(const {}), isNull);
      expect(
          buildEditPreviewDiff(const {'old_text': '', 'new_text': ''}), isNull);
      expect(buildEditPreviewDiff(
          const {'old_text': 'same', 'new_text': 'same'}), isNull);
    });

    test('pending content embeds preview_diff when provided', () {
      final json = buildApprovalPendingContent(
        toolName: 'file_edit',
        arguments: const {'old_text': 'a', 'new_text': 'b'},
        previewDiff: buildEditPreviewDiff(
            const {'old_text': 'a', 'new_text': 'b'}),
      );
      final parsed = parseApprovalContent(json);
      expect(parsed!['preview_diff'], isNotNull);
      expect(parsed['preview_diff'].toString(), contains('\n-a\n+b'));
    });
  });

  group('approval timeout', () {
    test('fresh pending never times out', () {
      expect(isApprovalTimedOut(DateTime.now().millisecondsSinceEpoch),
          isFalse);
    });

    test('old pending times out against the default window', () {
      final old = DateTime.now()
          .subtract(const Duration(minutes: 10))
          .millisecondsSinceEpoch;
      expect(isApprovalTimedOut(old), isTrue);
    });

    test('custom window is honored', () {
      final old = DateTime.now()
          .subtract(const Duration(seconds: 30))
          .millisecondsSinceEpoch;
      expect(isApprovalTimedOut(old, timeout: const Duration(minutes: 1)),
          isFalse);
      expect(isApprovalTimedOut(old, timeout: const Duration(seconds: 10)),
          isTrue);
    });

    test('null/invalid timestamps never time out (legacy events)', () {
      expect(isApprovalTimedOut(null), isFalse);
      expect(isApprovalTimedOut(0), isFalse);
      expect(isApprovalTimedOut('nope'), isFalse);
    });
  });

  group('always-allow override key decoding', () {
    test('mcp tool key decodes server + tool', () {
      final d = decodeApprovalOverrideKey('mcp:github:read_file');
      expect(d, isNotNull);
      expect(d!.kind, equals(ApprovalOverrideKind.mcpTool));
      expect(d!.serverId, equals('github'));
      expect(d!.toolName, equals('read_file'));
    });

    test('mcp server key decodes server', () {
      final d = decodeApprovalOverrideKey('mcp-server:github');
      expect(d, isNotNull);
      expect(d!.kind, equals(ApprovalOverrideKind.mcpServer));
      expect(d!.serverId, equals('github'));
      expect(d!.toolName, isNull);
    });

    test('workspace-out key decodes resolved path', () {
      final d = decodeApprovalOverrideKey('workspace-out:D:/Reports/q3.docx');
      expect(d, isNotNull);
      expect(d!.kind, equals(ApprovalOverrideKind.workspaceOut));
      expect(d!.resolvedPath, equals('D:/Reports/q3.docx'));
    });

    test('unknown shapes return null (forward compatible)', () {
      expect(decodeApprovalOverrideKey('shell:git'), isNull);
      expect(decodeApprovalOverrideKey('mcp:no-colon'), isNull);
      expect(decodeApprovalOverrideKey(''), isNull);
      expect(decodeApprovalOverrideKey('random'), isNull);
    });
  });

  group('approvalState normalization', () {
    test('valid values round-trip', () {
      expect(normalizeApprovalState(approvalStatePending),
          equals(approvalStatePending));
      expect(normalizeApprovalState(approvalStateApproved),
          equals(approvalStateApproved));
      expect(normalizeApprovalState(approvalStateDenied),
          equals(approvalStateDenied));
      expect(normalizeApprovalState(approvalStateAnswered),
          equals(approvalStateAnswered));
    });

    test('unknown/null degrades to auto', () {
      expect(normalizeApprovalState(null), equals(approvalStateAuto));
      expect(normalizeApprovalState('weird'), equals(approvalStateAuto));
    });
  });
}
