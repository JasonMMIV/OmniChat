// P1-1 (2026-11-10): a decision may only resolve a tool event that is still
// waiting for approval. These tests lock the resolver used by
// `ChatActions.resolveApproval` so a stale card can never re-execute a tool,
// overwrite a denial, or approve the wrong call after an id rewrite.
import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/approval.dart';

Map<String, dynamic> _event({
  String id = 'call-1',
  String name = 'shell_run',
  String? approvalState,
  String? content,
  Map<String, dynamic> arguments = const <String, dynamic>{
    'command': 'git status',
  },
}) {
  return <String, dynamic>{
    'id': id,
    'name': name,
    'arguments': arguments,
    'content': content,
    if (approvalState != null) 'approvalState': approvalState,
  };
}

void main() {
  group('isApprovalPendingEvent', () {
    test('pending approvalState wins', () {
      expect(
        isApprovalPendingEvent(
          _event(
            approvalState: approvalStatePending,
            content: buildApprovalPendingContent(toolName: 'shell_run'),
          ),
        ),
        isTrue,
      );
    });

    test('legacy pending content without a state is inferred', () {
      expect(
        isApprovalPendingEvent(
          _event(content: buildApprovalPendingContent(toolName: 'shell_run')),
        ),
        isTrue,
      );
    });

    test('automatic and completed events are not pending', () {
      expect(
        isApprovalPendingEvent(
          _event(approvalState: approvalStateAuto, content: '{"ok":true}'),
        ),
        isFalse,
      );
      expect(
        isApprovalPendingEvent(
          _event(
            approvalState: approvalStateApproved,
            content: '{"exit_code":0}',
          ),
        ),
        isFalse,
      );
      expect(
        isApprovalPendingEvent(
          _event(
            approvalState: approvalStateDenied,
            content: buildApprovalDeniedContent(toolName: 'shell_run'),
          ),
        ),
        isFalse,
      );
    });

    test('a recorded timeout is terminal, not pending', () {
      expect(
        isApprovalPendingEvent(
          _event(
            approvalState: approvalStateDenied,
            content: buildApprovalTimeoutContent(toolName: 'shell_run'),
          ),
        ),
        isFalse,
      );
    });

    test('unrelated tool_error content is not pending', () {
      expect(
        isApprovalPendingEvent(
          _event(content: '{"type":"tool_error","error":"execution_error"}'),
        ),
        isFalse,
      );
    });
  });

  group('findApprovalDecisionEvent', () {
    test('exact id resolves the pending event', () {
      final pending = _event(
        id: 'call-2',
        approvalState: approvalStatePending,
        content: buildApprovalPendingContent(toolName: 'shell_run'),
      );
      final events = <Map<String, dynamic>>[
        _event(id: 'call-1', approvalState: approvalStateApproved),
        pending,
      ];
      expect(
        identical(
          findApprovalDecisionEvent(events, toolCallId: 'call-2'),
          pending,
        ),
        isTrue,
      );
    });

    test('an exact id that is already resolved never falls through', () {
      final events = <Map<String, dynamic>>[
        _event(
          id: 'call-1',
          approvalState: approvalStateDenied,
          content: buildApprovalDeniedContent(toolName: 'shell_run'),
        ),
        _event(
          id: 'call-2',
          approvalState: approvalStatePending,
          content: buildApprovalPendingContent(toolName: 'shell_run'),
        ),
      ];
      expect(
        findApprovalDecisionEvent(
          events,
          toolCallId: 'call-1',
          toolName: 'shell_run',
        ),
        isNull,
      );
    });

    test('a unique pending event is the fallback for a missing id', () {
      final pending = _event(
        id: 'provider-rewrote-this',
        approvalState: approvalStatePending,
        content: buildApprovalPendingContent(toolName: 'shell_run'),
      );
      expect(
        identical(
          findApprovalDecisionEvent(
            <Map<String, dynamic>>[pending],
            toolCallId: 'call-from-ui',
            toolName: 'shell_run',
          ),
          pending,
        ),
        isTrue,
      );
    });

    test('arguments disambiguate two pending calls of the same tool', () {
      final first = _event(
        id: 'a',
        approvalState: approvalStatePending,
        content: buildApprovalPendingContent(toolName: 'shell_run'),
        arguments: const <String, dynamic>{'command': 'git status'},
      );
      final second = _event(
        id: 'b',
        approvalState: approvalStatePending,
        content: buildApprovalPendingContent(toolName: 'shell_run'),
        arguments: const <String, dynamic>{'command': 'git diff'},
      );
      expect(
        identical(
          findApprovalDecisionEvent(
            <Map<String, dynamic>>[first, second],
            toolCallId: 'missing',
            toolName: 'shell_run',
            arguments: const <String, dynamic>{'command': 'git diff'},
          ),
          second,
        ),
        isTrue,
      );
    });

    test('ambiguity without arguments returns null instead of guessing', () {
      final first = _event(
        id: 'a',
        approvalState: approvalStatePending,
        content: buildApprovalPendingContent(toolName: 'shell_run'),
        arguments: const <String, dynamic>{'command': 'git status'},
      );
      final second = _event(
        id: 'b',
        approvalState: approvalStatePending,
        content: buildApprovalPendingContent(toolName: 'shell_run'),
        arguments: const <String, dynamic>{'command': 'git diff'},
      );
      expect(
        findApprovalDecisionEvent(
          <Map<String, dynamic>>[first, second],
          toolCallId: 'missing',
          toolName: 'shell_run',
        ),
        isNull,
      );
    });

    test('empty ids use the unique-pending fallback', () {
      final pending = _event(
        id: '',
        approvalState: approvalStatePending,
        content: buildApprovalPendingContent(toolName: 'shell_run'),
      );
      expect(
        identical(
          findApprovalDecisionEvent(
            <Map<String, dynamic>>[
              _event(id: '', approvalState: approvalStateAuto),
              pending,
            ],
            toolCallId: '',
            toolName: 'shell_run',
          ),
          pending,
        ),
        isTrue,
      );
    });
  });

  test('canonicalApprovalArguments ignores key order', () {
    expect(
      canonicalApprovalArguments(const <String, dynamic>{'b': 2, 'a': 1}),
      canonicalApprovalArguments(const <String, dynamic>{'a': 1, 'b': 2}),
    );
  });

  test('shell approvals get a longer window than file approvals', () {
    expect(shellApprovalPendingTimeout, greaterThan(approvalPendingTimeout));
    expect(shellApprovalPendingTimeout, const Duration(minutes: 30));
  });
}
