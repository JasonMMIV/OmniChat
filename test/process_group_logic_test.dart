// 過程收褶（process folding）grouping logic contract tests — Phase 1 of
// PLAN_PROCESS_FOLDING.md. Pins down the port of AnyBuff's chat-groups.ts
// degenerate case: live verdict matrix, interleaved entry order, filter
// contracts (B3), forced-open for user-action cards (B1), the
// autoCollapseThinking semantics mapping (B2) and the explicit pin.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/approval.dart';
import 'package:OmniChat/core/services/chat/ask_user_models.dart';
import 'package:OmniChat/features/chat/widgets/process_group_logic.dart';

ProcessTool _tool(
  int index, {
  String toolName = 'search_web',
  bool loading = false,
  bool requiresUserAction = false,
}) {
  return ProcessTool(
    index: index,
    toolName: toolName,
    loading: loading,
    requiresUserAction: requiresUserAction,
  );
}

ProcessGroupModel _build({
  List<ProcessThought> thoughts = const <ProcessThought>[],
  List<ProcessTool> tools = const <ProcessTool>[],
  bool isStreaming = false,
  bool hasAnswerText = true,
  bool showThinkingCards = true,
  bool showToolCards = true,
}) {
  return buildProcessGroup(
    thoughts: thoughts,
    tools: tools,
    isStreaming: isStreaming,
    hasAnswerText: hasAnswerText,
    showThinkingCards: showThinkingCards,
    showToolCards: showToolCards,
  );
}

void main() {
  group('buildProcessGroup — interleaved entry order', () {
    test('toolStartIndex splits tool ranges between segments in order', () {
      final model = _build(
        thoughts: const [
          ProcessThought(text: 'A', loading: false, toolStartIndex: 0),
          ProcessThought(text: 'B', loading: false, toolStartIndex: 2),
        ],
        tools: [_tool(0), _tool(1), _tool(2)],
      );

      expect(model.visible, isTrue);
      final kinds = model.entries.map((e) => e.runtimeType).toList();
      expect(kinds, [
        ThoughtEntry, // A
        ToolEntry, // tool 0
        ToolEntry, // tool 1
        ThoughtEntry, // B
        ToolEntry, // tool 2
      ]);
      final toolIndices = model.entries
          .whereType<ToolEntry>()
          .map((e) => e.tool.index)
          .toList();
      expect(toolIndices, [0, 1, 2]);
    });

    test('no segments (fallback path) puts every tool into one range', () {
      final model = _build(tools: [_tool(0), _tool(1)]);

      expect(model.visible, isTrue);
      expect(model.entries, hasLength(2));
      expect(
        model.entries.map((e) => e.runtimeType).toList(),
        [ToolEntry, ToolEntry],
      );
    });

    test('out-of-range toolStartIndex is clamped, never throws', () {
      final model = _build(
        thoughts: const [
          ProcessThought(text: 'A', loading: false, toolStartIndex: -5),
          ProcessThought(text: 'B', loading: false, toolStartIndex: 99),
        ],
        tools: [_tool(0)],
      );

      // Segment A owns [0, 1) (clamped low), segment B owns nothing.
      final toolIndices = model.entries
          .whereType<ToolEntry>()
          .map((e) => e.tool.index)
          .toList();
      expect(toolIndices, [0]);
      expect(model.entries.whereType<ThoughtEntry>(), hasLength(2));
    });

    test('empty-text thoughts never render an entry', () {
      final model = _build(
        thoughts: const [ProcessThought(text: '   ', loading: true)],
      );

      expect(model.visible, isFalse);
      expect(model.entries, isEmpty);
    });
  });

  group('buildProcessGroup — filters and visibility (B3)', () {
    test('builtin_search and legacy workspace_snapshot rows are excluded',
        () {
      final model = _build(tools: [
        _tool(0, toolName: 'builtin_search'),
        _tool(1, toolName: 'workspace_snapshot'),
      ]);

      expect(model.visible, isFalse);
      expect(model.entries, isEmpty);
    });

    test('showToolCards=false drops plain tools, keeps thought entries', () {
      final model = _build(
        thoughts: const [ProcessThought(text: 'A', loading: false)],
        tools: [_tool(0)],
        showToolCards: false,
      );

      expect(model.visible, isTrue);
      expect(model.entries, hasLength(1));
      expect(model.entries.single, isA<ThoughtEntry>());
    });

    test('showThinkingCards=false drops thought entries, keeps tools', () {
      final model = _build(
        thoughts: const [ProcessThought(text: 'A', loading: false)],
        tools: [_tool(0)],
        showThinkingCards: false,
      );

      expect(model.visible, isTrue);
      expect(model.entries.single, isA<ToolEntry>());
    });

    test('B3: both filters on with only filtered rows → group not rendered',
        () {
      final model = _build(
        thoughts: const [ProcessThought(text: 'A', loading: false)],
        tools: [_tool(0, toolName: 'builtin_search')],
        showThinkingCards: false,
        showToolCards: false,
      );

      expect(model.visible, isFalse);
    });
  });

  group('buildProcessGroup — live verdict matrix', () {
    test('loading tool while streaming → live', () {
      final model = _build(
        tools: [_tool(0, loading: true)],
        isStreaming: true,
      );
      expect(model.live, isTrue);
    });

    test('streaming thought while streaming → live', () {
      final model = _build(
        thoughts: const [ProcessThought(text: 'A', loading: true)],
        isStreaming: true,
      );
      expect(model.live, isTrue);
    });

    test('everything finished + answer text + streaming → not live (Worked)',
        () {
      final model = _build(
        thoughts: const [ProcessThought(text: 'A', loading: false)],
        tools: [_tool(0)],
        isStreaming: true,
        hasAnswerText: true,
      );
      expect(model.live, isFalse);
    });

    test('finished group + streaming tail without answer text → live (gap)',
        () {
      final model = _build(
        tools: [_tool(0)],
        isStreaming: true,
        hasAnswerText: false,
      );
      expect(model.live, isTrue);
    });

    test('historical message (not streaming) → never live', () {
      final model = _build(
        thoughts: const [ProcessThought(text: 'A', loading: true)],
        tools: [_tool(0, loading: true)],
        isStreaming: false,
        hasAnswerText: false,
      );
      expect(model.live, isFalse);
    });

    test('B1: user-action tool forces live even when not streaming', () {
      final model = _build(
        tools: [_tool(0, requiresUserAction: true)],
        isStreaming: false,
      );
      expect(model.forcedOpen, isTrue);
      expect(model.live, isTrue);
    });

    test('hidden rows never drive live on their own', () {
      final model = _build(
        tools: [_tool(0, toolName: 'builtin_search', loading: true)],
        isStreaming: true,
        hasAnswerText: true,
      );
      expect(model.live, isFalse);
    });
  });

  group('B1 — user-action cards bypass showToolCards and force open', () {
    test('approval-pending tool survives showToolCards=false', () {
      final model = _build(
        tools: [_tool(0, requiresUserAction: true)],
        showToolCards: false,
      );
      expect(model.visible, isTrue);
      expect(model.entries.single, isA<ToolEntry>());
    });

    test('forcedOpen wins over the run state and the user pin', () {
      final open = resolveProcessOpen(
        explicitOpen: false,
        forcedOpen: true,
        live: false,
        autoCollapse: true,
      );
      expect(open, isTrue);
    });
  });

  group('resolveProcessStartAt — header timer start anchor', () {
    final thinkStart = DateTime(2026, 10, 5, 9);
    final toolStart = DateTime(2026, 10, 5, 8, 59, 30);

    test('prefers the first process event (a tool call before any thinking)', () {
      expect(
        resolveProcessStartAt(
          processStartedAt: toolStart,
          reasoningStartAt: thinkStart,
        ),
        toolStart,
      );
    });

    test('tool-only turn (no reasoning at all) still gets an anchor', () {
      expect(
        resolveProcessStartAt(
          processStartedAt: toolStart,
          reasoningStartAt: null,
        ),
        toolStart,
      );
    });

    test('legacy rows without the field fall back to the reasoning start', () {
      expect(
        resolveProcessStartAt(
          processStartedAt: null,
          reasoningStartAt: thinkStart,
        ),
        thinkStart,
      );
      expect(
        resolveProcessStartAt(processStartedAt: null, reasoningStartAt: null),
        isNull,
      );
    });
  });

  group('resolveProcessFinishedAt — header timer freeze anchor', () {
    // Regression (2026-10-05): a message whose thinking ends at 2.0s and whose
    // tool finishes at 12.0s used to freeze at reasoningFinishedAt, so the
    // header counted up to 11.4s and then snapped back to 2.0s.
    final t0 = DateTime(2026, 10, 5, 9);
    final thinkEnd = DateTime(2026, 10, 5, 9, 0, 2);
    final processEnd = DateTime(2026, 10, 5, 9, 0, 12);

    test('live → null (the shell ticks against the wall clock)', () {
      expect(
        resolveProcessFinishedAt(
          live: true,
          processFinishedAt: processEnd,
          reasoningFinishedAt: thinkEnd,
        ),
        isNull,
      );
    });

    test('finished → the process end, not the thinking end', () {
      expect(
        resolveProcessFinishedAt(
          live: false,
          processFinishedAt: processEnd,
          reasoningFinishedAt: thinkEnd,
        ),
        processEnd,
      );
    });

    test('frozen end is never before the last ticked second', () {
      // 11.4s is the last value the user sees while the tool runs; the frozen
      // value must not be smaller than it (no rewind).
      final lastSeen = t0.add(const Duration(milliseconds: 11400));
      final end = resolveProcessFinishedAt(
        live: false,
        processFinishedAt: processEnd,
        reasoningFinishedAt: thinkEnd,
      );
      expect(end!.isBefore(lastSeen), isFalse);
    });

    test('rows without the new field fall back to the thinking end', () {
      expect(
        resolveProcessFinishedAt(
          live: false,
          processFinishedAt: null,
          reasoningFinishedAt: thinkEnd,
        ),
        thinkEnd,
      );
      expect(
        resolveProcessFinishedAt(
          live: false,
          processFinishedAt: null,
          reasoningFinishedAt: null,
        ),
        isNull,
      );
    });
  });

  group('resolveProcessOpen — pin and autoCollapse semantics', () {
    test('no pin + live → open (working, expanded)', () {
      expect(
        resolveProcessOpen(
          explicitOpen: null,
          forcedOpen: false,
          live: true,
          autoCollapse: true,
        ),
        isTrue,
      );
    });

    test('B2: no pin + finished + autoCollapse → closed (default fold)', () {
      expect(
        resolveProcessOpen(
          explicitOpen: null,
          forcedOpen: false,
          live: false,
          autoCollapse: true,
        ),
        isFalse,
      );
    });

    test('B2: no pin + finished + autoCollapse off → stays open', () {
      expect(
        resolveProcessOpen(
          explicitOpen: null,
          forcedOpen: false,
          live: false,
          autoCollapse: false,
        ),
        isTrue,
      );
    });

    test('explicit pin wins over live and over auto-collapse', () {
      // User collapsed while working — stays collapsed.
      expect(
        resolveProcessOpen(
          explicitOpen: false,
          forcedOpen: false,
          live: true,
          autoCollapse: true,
        ),
        isFalse,
      );
      // User expanded after the run — stays expanded.
      expect(
        resolveProcessOpen(
          explicitOpen: true,
          forcedOpen: false,
          live: false,
          autoCollapse: true,
        ),
        isTrue,
      );
    });
  });

  group('toolRequiresUserAction — persisted-content predicates', () {
    test('ask_user: pending payload and empty content both require action',
        () {
      final pending = jsonEncode(<String, dynamic>{
        'type': askUserPendingType,
        'questions': <Map<String, dynamic>>[],
      });
      expect(
        toolRequiresUserAction(toolName: askUserToolName, content: pending),
        isTrue,
      );
      expect(
        toolRequiresUserAction(toolName: askUserToolName, content: null),
        isTrue,
      );
    });

    test('ask_user: answered payload no longer requires action', () {
      final answered = jsonEncode(<String, dynamic>{
        'type': askUserAnswerType,
        'answers': <Map<String, dynamic>>[],
      });
      expect(
        toolRequiresUserAction(toolName: askUserToolName, content: answered),
        isFalse,
      );
    });

    test('approval: approval_required requires action, denied does not', () {
      final required = jsonEncode(<String, dynamic>{
        'type': approvalRequiredType,
        'tool': 'file_write',
        'resolved_path': 'C:/ws/out.txt',
      });
      final denied = jsonEncode(<String, dynamic>{
        'type': approvalDeniedType,
        'tool': 'file_write',
      });

      expect(
        toolRequiresUserAction(toolName: 'file_write', content: required),
        isTrue,
      );
      expect(
        toolRequiresUserAction(toolName: 'file_write', content: denied),
        isFalse,
      );
    });

    test('approval: timeout error is a terminal recorded state', () {
      final timeout = jsonEncode(<String, dynamic>{
        'type': approvalRequiredType,
        'tool': 'file_write',
        'error': 'approval_timeout',
      });

      expect(
        toolRequiresUserAction(toolName: 'file_write', content: timeout),
        isFalse,
      );
    });

    test('plain tool results never require action', () {
      expect(
        toolRequiresUserAction(
          toolName: 'search_web',
          content: '{"items": []}',
        ),
        isFalse,
      );
      expect(toolRequiresUserAction(toolName: 'search_web', content: null),
          isFalse);
      expect(
        toolRequiresUserAction(toolName: 'file_read', content: 'not json'),
        isFalse,
      );
    });
  });

  group('ThoughtEntry card passthrough (2026-10-05 revision)', () {
    test('per-card fold state survives into the group entries', () {
      var toggled = false;
      final model = _build(
        thoughts: [
          ProcessThought(
            text: 'A',
            loading: false,
            toolStartIndex: 0,
            expanded: false,
            onToggle: () => toggled = true,
          ),
        ],
        tools: [_tool(0)],
      );

      final thought = model.entries.whereType<ThoughtEntry>().single;
      expect(thought.expanded, isFalse);
      expect(thought.streaming, isFalse);
      thought.onToggle!();
      expect(toggled, isTrue);
    });

    test('defaults keep legacy constructor call sites intact', () {
      final model = _build(
        thoughts: const [
          ProcessThought(text: 'A', loading: true, toolStartIndex: 0),
        ],
      );

      final thought = model.entries.whereType<ThoughtEntry>().single;
      expect(thought.expanded, isTrue);
      expect(thought.onToggle, isNull);
      expect(thought.streaming, isTrue);
    });
  });
}
