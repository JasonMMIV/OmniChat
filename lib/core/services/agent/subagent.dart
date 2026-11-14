/// P2-3 subagent runtime (`spawn_subagent`, docs/Cowork剩餘項目實作計劃.md §2.6)
/// plus the P0/P1 hardening in docs/子代理P0-P1修正實作計畫.md.
///
/// A subagent is a **fresh-context** agent run driven by the same kernel as the
/// main generation (`agent_loop.dart`): it gets its own system + task messages,
/// its own step ceiling and token budget, executes tools through the injected
/// handler, and returns **only a final summary** to the parent. The parent
/// conversation never receives the helper's raw tool calls or tool output —
/// that isolation is the whole point (token savings + noise isolation).
///
/// Deliberately transport-free and provider-free: [SubagentRunner.sendRound] /
/// [SubagentRunner.onToolCall] are injected, so the semantics below are
/// unit-testable without a provider tree or a network. The kernel itself is
/// never modified (plan §2 D2 / §3.4): context guarding, abort-before-tool,
/// wrap-up and tracing all live in this runner.
///
/// Contracts:
/// - **Serialized** ([SerialGate]): helper runs are queued behind each other
///   process-wide (manual §5.1 "never-parallel" for external processes). The
///   gate is held until the run's in-flight tool settled (or the 5s grace
///   expired), not merely until the kernel stream ended.
/// - **Independent budget**: [SubagentSpec.maxSteps] / [SubagentSpec.tokenBudget]
///   are counted from zero and never consume the parent run's budget.
/// - **No recursion**: the caller must exclude [spawnSubagentToolName] from the
///   child tool list ([subagentChildTools]); the tool handler also refuses a
///   nested call as defense in depth.
/// - **Fail-open**: a transport error, timeout or empty answer is reported as a
///   structured status; it never throws into the parent tool loop.
/// - **Never fake success**: an aborted round throws [SubagentAborted] instead
///   of returning an empty stream (the kernel treats "no tool calls" as
///   `finished`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import '../api/chat_stream_chunk.dart';
import '../logging/flutter_logger.dart';
import 'agent_loop.dart';
import 'compaction/context_trim.dart';
import 'compaction/tool_result_pruner.dart';
import 'subagent_profiles.dart';
import 'subagent_request.dart';

/// Tool name advertised to the parent model.
const String spawnSubagentToolName = 'spawn_subagent';

/// UI-only tool name for a user-initiated `@profile` delegation. It is never
/// advertised to a model; the card/persistence path uses it to distinguish a
/// direct delegation from a model-chosen `spawn_subagent` call.
const String delegateSubagentToolName = 'delegate_subagent';

/// Tools a subagent must never receive.
///
/// - `spawn_subagent`: no recursion (unbounded fan-out + budget escapes).
/// - `ask_user`: there is nobody to answer inside a helper run.
/// - `write_todos`: the helper would overwrite the parent conversation's plan.
const Set<String> subagentExcludedToolNames = <String>{
  spawnSubagentToolName,
  'ask_user',
  'write_todos',
};

/// Child tool list: the parent's list minus [subagentExcludedToolNames], then
/// restricted by [profile] (allowlist + read-only guard).
///
/// Pure so the inheritance rule can be asserted without a provider tree.
List<Map<String, dynamic>> subagentChildTools(
  List<Map<String, dynamic>>? parentTools, {
  SubagentProfile? profile,
}) {
  if (parentTools == null || parentTools.isEmpty) {
    return const <Map<String, dynamic>>[];
  }
  final result = <Map<String, dynamic>>[];
  for (final def in parentTools) {
    String name;
    try {
      name = ((def['function'] as Map)['name'] ?? '').toString();
    } catch (_) {
      continue;
    }
    if (name.isEmpty || subagentExcludedToolNames.contains(name)) continue;
    if (profile != null && !profile.permits(name)) continue;
    result.add(def);
  }
  return result;
}

/// P1-4: collects helper tokens for the parent message accounting.
///
/// Only `totalTokens` is affected (cost); `promptTokens` — and therefore the
/// context-usage ring — stays untouched (A3).
class SubagentUsageAccumulator {
  int _tokens = 0;

  int get tokens => _tokens;

  void add(int n) {
    if (n > 0) _tokens += n;
  }
}

/// Parent generation snapshot a helper inherits.
///
/// Kept as one object on purpose: the inherited set (provider, model, tools,
/// custom headers/body, output cap, sampling, brief material, usage callback)
/// has to stay identical across the tool handler, the child transport and the
/// tests. Adding a field here forces every call site to think about it instead
/// of silently dropping it.
class SubagentLaunchConfig {
  const SubagentLaunchConfig({
    required this.providerKey,
    required this.modelId,
    required this.tools,
    this.extraHeaders,
    this.extraBody,
    this.maxTokens,
    this.temperature,
    this.topP,
    this.thinkingBudget,
    this.toolImagesEnabled = true,
    this.projectInstructions,
    this.workspaceFileMap,
    this.profile,
    this.onUsage,
    this.depth = 0,
  });

  final String? providerKey;
  final String? modelId;

  /// Tools advertised to the parent; the child list is derived from it via
  /// [subagentChildTools].
  final List<Map<String, dynamic>>? tools;

  /// Assistant custom headers / body (proxies, OpenRouter attribution, …).
  /// Child requests must carry the same values or providers that require them
  /// would reject the helper.
  final Map<String, String>? extraHeaders;
  final Map<String, dynamic>? extraBody;

  /// Assistant output cap (null = provider default).
  final int? maxTokens;

  /// P1-6 wire parity: the parent run's sampling settings. A helper must
  /// behave like the parent, so these travel with every child round.
  final double? temperature;
  final double? topP;
  final int? thinkingBudget;
  final bool toolImagesEnabled;

  /// P0-3 brief material: the assistant's standing instructions and the
  /// already-rendered workspace file map (captured during assembly so a spawn
  /// never rescans the workspace).
  final String? projectInstructions;
  final String? workspaceFileMap;

  /// Set only on a CHILD launch. The parent snapshot is always `profile: null`
  /// — otherwise the parent's own tool calls would be checked against the
  /// helper's restrictions.
  final SubagentProfile? profile;

  /// P1-4: reports helper tokens back to the parent message accounting.
  final void Function(int tokens)? onUsage;

  /// 0 = parent generation, 1 = helper. Nested helpers are refused.
  final int depth;

  SubagentLaunchConfig child(
    List<Map<String, dynamic>> childTools, {
    SubagentProfile? profile,
  }) {
    return SubagentLaunchConfig(
      providerKey: providerKey,
      modelId: modelId,
      tools: childTools,
      extraHeaders: extraHeaders,
      extraBody: extraBody,
      maxTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      thinkingBudget: thinkingBudget,
      toolImagesEnabled: toolImagesEnabled,
      projectInstructions: projectInstructions,
      workspaceFileMap: workspaceFileMap,
      profile: profile ?? this.profile,
      onUsage: onUsage,
      depth: depth + 1,
    );
  }

  /// Apply a profile's pre-bound provider/model (A5).
  ///
  /// Cross-provider children do NOT inherit the parent's custom headers/body,
  /// output cap or reasoning budget: an Anthropic-only header or a GPT output
  /// cap must never be sent to a different vendor. Sampling parameters stay
  /// inherited for same-provider helpers (A7: the wrap-up never changes them).
  SubagentLaunchConfig withProfile(SubagentProfile profile) {
    final targetProvider = (profile.providerKey ?? '').trim();
    final targetModel = (profile.modelId ?? '').trim();
    final useProfileModel = targetProvider.isNotEmpty && targetModel.isNotEmpty;
    final crossProvider = useProfileModel && targetProvider != providerKey;
    return SubagentLaunchConfig(
      providerKey: useProfileModel ? targetProvider : providerKey,
      modelId: useProfileModel ? targetModel : modelId,
      tools: tools,
      extraHeaders: crossProvider ? null : extraHeaders,
      extraBody: crossProvider ? null : extraBody,
      maxTokens: crossProvider ? null : maxTokens,
      temperature: crossProvider ? null : temperature,
      topP: crossProvider ? null : topP,
      thinkingBudget: crossProvider ? null : thinkingBudget,
      toolImagesEnabled: toolImagesEnabled,
      projectInstructions: projectInstructions,
      workspaceFileMap: workspaceFileMap,
      profile: profile,
      onUsage: onUsage,
      depth: depth,
    );
  }
}

/// Fill one round request with the effective wire parameters.
///
/// Kept as a pure top-level function so the P1-6 contract (same-provider
/// inheritance, cross-provider clearing, stable session id) can be asserted
/// without a provider tree or a network. The tool handler supplies the
/// already-resolved [launch], child tools and run/session ids.
SubagentRoundRequest buildSubagentRoundRequest(
  SubagentRoundRequest request, {
  required SubagentLaunchConfig launch,
  required String providerKey,
  required String modelId,
  required List<Map<String, dynamic>> childTools,
  required String runId,
  required String sessionId,
  required bool webFetchEnabled,
  required Map<String, dynamic>? extraBody,
}) {
  final textOnly = request.textOnly;
  return request.copyWith(
    providerKey: providerKey,
    modelId: modelId,
    tools: textOnly
        ? null
        : (request.tools ?? (childTools.isEmpty ? null : childTools)),
    clearTools: textOnly,
    extraHeaders: launch.extraHeaders,
    extraBody: extraBody,
    maxTokens: launch.maxTokens,
    temperature: launch.temperature,
    topP: launch.topP,
    thinkingBudget: launch.thinkingBudget,
    toolImagesEnabled: textOnly ? false : launch.toolImagesEnabled,
    webFetchEnabled: textOnly
        ? false
        : (request.webFetchEnabled && webFetchEnabled),
    requestId: request.requestId ?? (textOnly ? '${runId}_summary' : runId),
    sessionId: request.sessionId ?? sessionId,
  );
}

/// One subagent invocation.
class SubagentSpec {
  const SubagentSpec({
    required this.task,
    this.role,
    this.profileId = 'general',
    this.maxSteps = defaultMaxSteps,
    this.tokenBudget = defaultTokenBudget,
    this.timeout = defaultTimeout,
    this.wrapUpTimeout = defaultWrapUpTimeout,
    this.contextWindowTokens,
    this.maxOutputTokens,
    this.toolSettleGrace = defaultToolSettleGrace,
    this.sessionId,
    this.requestId,
  });

  /// Self-contained instructions for the helper.
  final String task;

  /// Optional specialization ("code reviewer", "researcher", …).
  final String? role;

  /// Named profile (P1-1): tool allowlist / read-only / instructions /
  /// pre-bound model. Unknown ids are rejected by the tool handler.
  final String profileId;

  /// Tool rounds the helper may dispatch (independent of the parent).
  final int maxSteps;

  /// Soft budget over the helper's cumulative token usage.
  final int tokenBudget;

  /// Wall-clock deadline for the whole helper run (wrap-up included).
  final Duration timeout;

  /// Budget for the forced wrap-up round. `Duration.zero` disables it.
  final Duration wrapUpTimeout;

  /// Resolved context window (P0-4); null = unknown (1M fallback).
  final int? contextWindowTokens;

  /// Output reservation for the guard; null = 8192.
  final int? maxOutputTokens;

  /// How long the gate waits for an in-flight tool after a stop (A2: 5s).
  final Duration toolSettleGrace;

  /// P1-3: continue a previous helper session.
  final String? sessionId;

  /// Per-run transport request id (main run id + `_subagent_<seq>`).
  final String? requestId;

  static const int defaultMaxSteps = 16;
  static const int maxStepsLimit = 40;
  static const int defaultTokenBudget = 120000;
  static const Duration defaultTimeout = Duration(minutes: 10);
  static const Duration defaultWrapUpTimeout = Duration(seconds: 90);
  static const Duration defaultToolSettleGrace = Duration(seconds: 5);

  /// Task cap: the task travels as one user message; 32 KB is already far
  /// beyond a useful delegation and keeps a runaway prompt out of the wire.
  static const int maxTaskChars = 32000;

  /// Role cap: a line or two, not a second task description.
  static const int maxRoleChars = 2000;

  /// Budget clamps for model-supplied arguments.
  static const int minTokenBudget = 1000;
  static const int maxTokenBudget = 400000;

  /// Normalize model-supplied arguments (clamping, trimming, truncation).
  factory SubagentSpec.fromArguments(Map<String, dynamic> args) {
    final task = (args['task'] ?? '').toString().trim();
    final role = (args['role'] ?? '').toString().trim();
    final agent = (args['agent'] ?? '').toString().trim();
    final session = (args['session_id'] ?? '').toString().trim();
    final rawSteps = args['max_steps'];
    var steps = defaultMaxSteps;
    if (rawSteps is num) {
      steps = rawSteps.toInt();
    } else if (rawSteps is String) {
      steps = int.tryParse(rawSteps) ?? defaultMaxSteps;
    }
    final rawBudget = args['token_budget'];
    var budget = defaultTokenBudget;
    if (rawBudget is num) {
      budget = rawBudget.toInt();
    } else if (rawBudget is String) {
      budget = int.tryParse(rawBudget) ?? defaultTokenBudget;
    }
    return SubagentSpec(
      task: task.length > maxTaskChars ? task.substring(0, maxTaskChars) : task,
      role: role.isEmpty
          ? null
          : (role.length > maxRoleChars
                ? role.substring(0, maxRoleChars)
                : role),
      profileId: agent.isEmpty ? 'general' : agent,
      maxSteps: steps.clamp(1, maxStepsLimit).toInt(),
      tokenBudget: budget.clamp(minTokenBudget, maxTokenBudget).toInt(),
      sessionId: session.isEmpty ? null : session,
    );
  }
}

/// Which of the fallback layers produced [SubagentOutcome.summary].
enum SubagentSummarySource {
  /// The helper finished naturally; the last round's text is the deliverable.
  finalAnswer,

  /// A forced text-only wrap-up round produced the summary.
  wrapUp,

  /// The wrap-up failed; the last completed non-empty preamble was used.
  preamble,

  /// Nothing usable was produced.
  none;

  String get wireName => switch (this) {
    SubagentSummarySource.finalAnswer => 'final',
    SubagentSummarySource.wrapUp => 'wrap_up',
    SubagentSummarySource.preamble => 'preamble',
    SubagentSummarySource.none => 'none',
  };
}

/// Shared JSON shape for the live (while running) and final helper trace.
/// Keeping one builder prevents the live card and the persisted card from
/// drifting on the 40-row cap or field names.
Map<String, dynamic> buildSubagentTraceJson({
  required String status,
  required List<SubagentTraceStep> trace,
  String? profileId,
  int? steps,
  int? toolCalls,
  int? tokens,
  String? summarySource,
  String? sessionId,
  String? running,
}) {
  const maxRows = 40;
  return <String, dynamic>{
    'status': status,
    if (profileId != null && profileId.isNotEmpty) 'profile': profileId,
    if (steps != null) 'steps': steps,
    if (toolCalls != null) 'toolCalls': toolCalls,
    if (tokens != null) 'tokens': tokens,
    if (summarySource != null) 'summarySource': summarySource,
    if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
    'items': <Map<String, dynamic>>[
      for (final step in trace.take(maxRows)) step.toJson(),
    ],
    if (trace.length > maxRows) 'more': trace.length - maxRows,
    if (running != null && running.isNotEmpty) 'running': running,
  };
}

/// One executed child tool, for the UI-only helper trace (A6: no arguments).
class SubagentTraceStep {
  const SubagentTraceStep({
    required this.tool,
    required this.durationMs,
    required this.resultChars,
  });

  final String tool;
  final int durationMs;
  final int resultChars;

  Map<String, dynamic> toJson() => <String, dynamic>{
    't': tool,
    'ms': durationMs,
    'chars': resultChars,
  };
}

/// What one helper run produced. [summary] is the only model-facing artefact.
class SubagentOutcome {
  const SubagentOutcome({
    required this.summary,
    this.summarySource = SubagentSummarySource.none,
    this.partial = false,
    this.contextTrimmed = false,
    this.stopReason,
    this.steps = 0,
    this.toolCallCount = 0,
    this.tokensUsed = 0,
    this.timedOut = false,
    this.cancelled = false,
    this.error,
    this.profileId,
    this.sessionId,
    this.gateWaitMs = 0,
    this.trace = const <SubagentTraceStep>[],
    this.transcriptMessages,
  });

  final String summary;
  final SubagentSummarySource summarySource;

  /// True when the run stopped at a budget/deadline and the summary is not a
  /// complete deliverable.
  final bool partial;

  /// True when the context guard removed or shortened history (P0-4).
  final bool contextTrimmed;

  final AgentRunStopReason? stopReason;
  final int steps;
  final int toolCallCount;
  final int tokensUsed;
  final bool timedOut;

  /// The stop button aborted this run (in-flight request cancelled and/or the
  /// next round vetoed). Checked first: a cancelled transport may end the
  /// stream without a terminal, which would otherwise look like `finished`.
  final bool cancelled;
  final String? error;

  final String? profileId;
  final String? sessionId;

  /// Phase 3-1 observability: how long this run waited behind the serial
  /// gate before it was granted. Queueing is not execution time, so it is
  /// reported separately in the `subagent_run` log.
  final int gateWaitMs;

  /// UI-only trace (tool name / duration / result size). Never sent to the
  /// model and never persisted with arguments (A6).
  final List<SubagentTraceStep> trace;

  /// Neutral transcript for follow-up sessions (P1-3). Not part of the JSON.
  final List<Map<String, dynamic>>? transcriptMessages;

  /// Hard cap on the summary embedded in the tool-result JSON. The result is
  /// a JSON contract the model parses, so the TEXT is clipped here — letting
  /// [ToolResultCaps] cut the encoded string would corrupt the JSON.
  static const int maxSummaryChars = 24000;

  /// Error strings (often an entire provider response body) are clipped for
  /// the same reason: the encoded result has to stay under the tool cap.
  static const int maxErrorChars = 2000;

  /// Safety margin below [ToolResultCaps.maxCapThresholdChars] (32 KB). JSON
  /// escaping can expand the summary several-fold; the encoded payload must
  /// fit so the transport backstop never cuts it mid-JSON.
  static const int maxEncodedChars = 30000;

  /// Stable status string surfaced to the parent model.
  String get status {
    if (cancelled) return 'stopped';
    if (error != null) return 'error';
    if (timedOut) return 'timeout';
    switch (stopReason) {
      case AgentRunStopReason.finished:
        return summary.isEmpty ? 'empty' : 'finished';
      case AgentRunStopReason.maxStepsReached:
        return 'max_steps';
      case AgentRunStopReason.tokenBudgetReached:
        return 'token_budget';
      case AgentRunStopReason.stoppedByHook:
        return cancelled ? 'stopped' : 'empty';
      case null:
        return summary.isEmpty ? 'empty' : 'finished';
    }
  }

  bool get isComplete => status == 'finished';

  static const Object _unset = Object();

  /// Single copy point for outcome metadata. Every field is listed once so a
  /// future field cannot be silently dropped by one of the public `with*`
  /// helpers.
  SubagentOutcome _copyWith({Object? sessionId = _unset, int? gateWaitMs}) =>
      SubagentOutcome(
        summary: summary,
        summarySource: summarySource,
        partial: partial,
        contextTrimmed: contextTrimmed,
        stopReason: stopReason,
        steps: steps,
        toolCallCount: toolCallCount,
        tokensUsed: tokensUsed,
        timedOut: timedOut,
        cancelled: cancelled,
        error: error,
        profileId: profileId,
        sessionId: identical(sessionId, _unset)
            ? this.sessionId
            : sessionId as String?,
        gateWaitMs: gateWaitMs ?? this.gateWaitMs,
        trace: trace,
        transcriptMessages: transcriptMessages,
      );

  /// Copy with a resolved session id (the handler mints one for a new
  /// session after the run; an in-progress outcome cannot be mutated).
  SubagentOutcome withSessionId(String? id, {bool clear = false}) =>
      _copyWith(sessionId: clear ? null : (id ?? sessionId));

  /// Attach the serial-gate queue time measured by [SubagentRunner.run].
  SubagentOutcome withGateWaitMs(int ms) => _copyWith(gateWaitMs: ms);

  /// Structured tool result the parent model reads (P1-7: `untrusted`).
  ///
  /// The summary is wrapped in `<subagent_summary>` so the parent cannot
  /// mistake helper output for its own instructions, and the encoded payload
  /// is kept below [maxEncodedChars] even when JSON escaping expands it.
  String toToolResultJson() {
    final note = _noteFor();
    final renderedSummary = replaceSubagentImageMarkers(summary);
    final clippedError = error != null && error!.length > maxErrorChars
        ? error!.substring(0, maxErrorChars)
        : error;

    String encode(String text, {required bool truncated}) {
      final body = text.isEmpty
          ? '(the subagent produced no summary)'
          : '<subagent_summary>\n$text\n</subagent_summary>';
      return jsonEncode(<String, dynamic>{
        'type': 'subagent_result',
        'status': status,
        'summary': body,
        'summary_source': summarySource.wireName,
        'partial': partial || status == 'error',
        'context_trimmed': contextTrimmed,
        'steps': steps,
        'tool_calls': toolCallCount,
        'tokens': tokensUsed,
        if (sessionId != null && sessionId!.isNotEmpty) 'session_id': sessionId,
        if (profileId != null && profileId!.isNotEmpty) 'profile': profileId,
        'untrusted': true,
        if (truncated) 'summary_truncated': true,
        if (clippedError != null) 'error': clippedError,
        if (note != null) 'note': note,
      });
    }

    var truncated = renderedSummary.length > maxSummaryChars;
    var text = truncated
        ? '${renderedSummary.substring(0, maxSummaryChars)}\n\n'
              '[... summary truncated — ${renderedSummary.length} chars total ...]'
        : renderedSummary;
    var json = encode(text, truncated: truncated);
    if (json.length > maxEncodedChars) {
      truncated = true;
      var limit = text.length;
      var attempts = 0;
      while (json.length > maxEncodedChars && limit > 0 && attempts < 64) {
        attempts++;
        limit = (limit * 3) ~/ 4;
        final keep = math.min(limit, renderedSummary.length);
        text = keep <= 0
            ? ''
            : '${renderedSummary.substring(0, keep)}\n\n'
                  '[... summary truncated ...]';
        json = encode(text, truncated: true);
      }
      // Pathological escaping (or a huge error/note) can still exceed the
      // transport cap. Emit a tiny, valid contract rather than a payload that
      // ToolResultCaps would slice mid-JSON.
      if (json.length > maxEncodedChars) {
        text = '(summary omitted because it exceeded the transport limit)';
        json = encode(text, truncated: true);
      }
    }
    return json;
  }

  /// Compact UI-only trace written to the tool event extras (P1-2).
  /// Capped at 40 rows; a trailing marker carries the omitted count.
  Map<String, dynamic> toTraceJson() {
    return buildSubagentTraceJson(
      status: status,
      profileId: profileId,
      steps: steps,
      toolCalls: toolCallCount,
      tokens: tokensUsed,
      summarySource: summarySource.wireName,
      sessionId: sessionId,
      trace: trace,
    );
  }

  String? _noteFor() {
    final source = summarySource.wireName;
    switch (status) {
      case 'timeout':
        return source == 'wrap_up'
            ? 'The helper hit its time limit; the summary was produced in a '
                  'forced wrap-up round and is partial. Verify key claims with '
                  'your own tools.'
            : 'The helper hit its time limit and the wrap-up round failed, so '
                  'the text below is only its last in-progress message. Treat '
                  'it as partial.';
      case 'max_steps':
      case 'token_budget':
        return source == 'wrap_up'
            ? 'The helper stopped at its own limit; the summary was produced '
                  'in a forced wrap-up round. Treat it as partial and verify '
                  'key claims with your own tools.'
            : 'The helper stopped at its own limit before finishing and the '
                  'wrap-up failed. The text below is only its last '
                  'in-progress message; verify it yourself.';
      case 'stopped':
        return 'The helper was stopped before finishing. Resume the work '
            'yourself if it is still needed.';
      case 'empty':
        return 'The helper returned no summary. Retry with a smaller, more '
            'concrete task (it cannot see this conversation).';
      case 'error':
        return 'The helper failed before producing a summary. Retry once; if '
            'it fails again, do the work yourself.';
      default:
        return null;
    }
  }
}

/// Serial queue with queued-abort support (§4.8 of the plan).
///
/// Invariants:
/// 1. When [abort] wins, the action is NEVER executed (returns null).
/// 2. When [abort] wins, the release still waits for the current holder —
///    releasing early would let a third waiter jump the queue.
/// 3. `null` means "aborted while queued"; callers use a non-nullable action
///    result type to keep the two cases distinguishable.
class SerialGate {
  Future<void> _tail = Future<void>.value();

  static final SerialGate shared = SerialGate();

  /// Run [action] after the current holder. Returns null when [abort] fires
  /// before the turn is granted.
  Future<T?> run<T>(Future<T> Function() action, {Future<void>? abort}) async {
    return (await runMeasured<T>(action, abort: abort)).value;
  }

  /// [run] plus the time spent waiting for the current holder.
  ///
  /// The clock stops when the turn is granted (or [abort] wins), so the value
  /// is queue latency, not execution time. This is the Phase 3-1 `gateWaitMs`
  /// observability signal.
  Future<GateRunResult<T>> runMeasured<T>(
    Future<T> Function() action, {
    Future<void>? abort,
  }) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    final wait = Stopwatch()..start();

    void releaseAfterPrevious() {
      unawaited(
        previous.whenComplete(() {
          if (!release.isCompleted) release.complete();
        }),
      );
    }

    if (abort != null) {
      final granted = await Future.any<bool>([
        previous.then((_) => true),
        abort.then((_) => false),
      ]);
      if (!granted) {
        wait.stop();
        // FIFO invariant: the next waiter must still wait for the current
        // holder — release only after `previous` completes.
        releaseAfterPrevious();
        return GateRunResult<T>(null, wait.elapsedMilliseconds);
      }
    } else {
      await previous;
    }
    wait.stop();

    try {
      return GateRunResult<T>(await action(), wait.elapsedMilliseconds);
    } finally {
      if (!release.isCompleted) release.complete();
    }
  }
}

/// Result of one [SerialGate] turn, including queue latency.
class GateRunResult<T> {
  const GateRunResult(this.value, this.waitMs);

  /// Null only when the queued action was aborted before it started.
  final T? value;
  final int waitMs;
}

/// Thrown by the guarded round/tool callbacks when the run was aborted.
/// Never returned as an empty stream: the kernel would treat "no tool calls"
/// as a normal `finished` and the parent would receive a fake success.
class SubagentAborted implements Exception {
  const SubagentAborted([this.reason = 'subagent aborted']);
  final String reason;

  @override
  String toString() => 'SubagentAborted: $reason';
}

/// Drives one subagent run through the agent-loop kernel.
class SubagentRunner {
  /// Bound on the in-memory session transcript (the system prefix is always
  /// preserved). Sessions are LRU/TTL scoped, but a long chain of follow-ups
  /// must not grow without limit.
  static const int maxStoredTranscriptMessages = 200;

  SubagentRunner({
    required this.sendRound,
    required this.onToolCall,
    this.sendWrapUpRound,
    this.onAbort,
    this.onAbortRequest,
    this.decorateRequest,
    this.onZombie,
    this.onToolStart,
    this.onToolEnd,
    SerialGate? gate,
  }) : gate = gate ?? SerialGate.shared;

  /// One transport request per kernel round (tools surfaced, never executed).
  final Future<Stream<ChatStreamChunk>> Function(SubagentRoundRequest request)
  sendRound;

  /// Executes one child tool call. Permission policy is inherited from the
  /// caller (same workspace, same switches), but the helper never surfaces an
  /// approval card — see the system prompt's `approval_required` guidance.
  final Future<String> Function(AgentToolCall call) onToolCall;

  /// Text-only wrap-up transport binding (tools: null, no web fetch, no image
  /// policy). Null disables wrap-up entirely.
  final Future<Stream<ChatStreamChunk>> Function(SubagentRoundRequest request)?
  sendWrapUpRound;

  /// Called when the main deadline fires: cancels the in-flight transport so
  /// the provider stops generating and the tool settle wait starts promptly.
  final void Function()? onAbort;

  /// Cancels one request id (the wrap-up round's `<runId>_summary`). A
  /// timeout must abort the provider request, not merely drop the local
  /// subscription, or it keeps burning tokens in the background.
  final void Function(String requestId)? onAbortRequest;

  /// Fills the effective wire parameters (provider/model/sampling/session id)
  /// onto each round request. The runner stays transport-agnostic; the tool
  /// handler owns the actual values.
  final SubagentRoundRequest Function(SubagentRoundRequest request)?
  decorateRequest;

  /// Test/telemetry hook fired when the settle grace expires with a child
  /// tool still running (the gate is released anyway to avoid a global
  /// deadlock). Production wiring logs the `subagent_zombie` line.
  final void Function(int inFlight)? onZombie;

  /// UI progress hooks for the parent `spawn_subagent` card. [onToolStart]
  /// fires before the child tool executes; [onToolEnd] carries the completed
  /// trace step. Both are best-effort: a listener failure must never abort
  /// the helper run.
  final void Function(String tool)? onToolStart;
  final void Function(SubagentTraceStep step)? onToolEnd;

  final SerialGate gate;

  /// Run [spec] to completion (or timeout) and return its summary.
  ///
  /// [initialMessages] resumes a session: the stored system + task messages
  /// are reused verbatim (stable provider-cache prefix) and a follow-up task
  /// is appended. [priorTokens] is the session's cumulative usage (display).
  Future<SubagentOutcome> run(
    SubagentSpec spec, {
    SubagentProfile? profile,
    String? brief,
    List<Map<String, dynamic>>? initialMessages,
    int priorTokens = 0,
    bool Function()? isCancelled,
    Future<void>? cancelFuture,
  }) async {
    bool cancelled() => isCancelled?.call() ?? false;

    if (cancelled()) {
      return _cancelledOutcome(spec, profile, priorTokens);
    }

    final result = await gate.runMeasured<SubagentOutcome>(
      () => _run(
        spec,
        profile: profile,
        brief: brief,
        initialMessages: initialMessages,
        priorTokens: priorTokens,
        isCancelled: isCancelled,
        cancelFuture: cancelFuture,
      ),
      abort: cancelFuture,
    );
    final outcome = result.value;
    if (outcome != null) return outcome.withGateWaitMs(result.waitMs);

    // Aborted while queued: never entered the action.
    onAbort?.call();
    return _cancelledOutcome(
      spec,
      profile,
      priorTokens,
      gateWaitMs: result.waitMs,
    );
  }

  SubagentOutcome _cancelledOutcome(
    SubagentSpec spec,
    SubagentProfile? profile,
    int priorTokens, {
    int gateWaitMs = 0,
  }) {
    return SubagentOutcome(
      summary: '',
      cancelled: true,
      tokensUsed: priorTokens,
      profileId: profile?.id ?? spec.profileId,
      sessionId: spec.sessionId,
      gateWaitMs: gateWaitMs,
    );
  }

  Future<SubagentOutcome> _run(
    SubagentSpec spec, {
    SubagentProfile? profile,
    String? brief,
    List<Map<String, dynamic>>? initialMessages,
    int priorTokens = 0,
    bool Function()? isCancelled,
    Future<void>? cancelFuture,
  }) async {
    bool cancelled() => isCancelled?.call() ?? false;

    final messages = <Map<String, dynamic>>[
      if (initialMessages != null)
        for (final m in initialMessages) Map<String, dynamic>.of(m)
      else ...[
        <String, dynamic>{
          'role': 'system',
          'content': buildSubagentSystemPrompt(
            role: spec.role,
            profile: profile,
            brief: brief,
          ),
        },
        <String, dynamic>{'role': 'user', 'content': 'Task:\n${spec.task}'},
      ],
      if (initialMessages != null)
        <String, dynamic>{
          'role': 'user',
          'content': 'Task (follow-up):\n${spec.task}',
        },
    ];

    final buffer = StringBuffer();
    final trace = <SubagentTraceStep>[];
    var roundMaxTokens = 0;
    var usageAcrossRounds = 0;
    var toolCallCount = 0;
    var steps = 0;
    var timedOut = false;
    var contextTrimmed = false;
    String? error;
    AgentRunStopReason? stopReason;
    String lastNonEmptyText = '';
    List<Map<String, dynamic>>? finalMessages;
    List<Map<String, dynamic>>? lastRequestMessages;

    // In-flight child tool bookkeeping. The gate is held until this reaches
    // zero (or the grace expires), not merely until the kernel stream ends:
    // a cancelled stream does not unwind an executing tool.
    var inFlightTools = 0;
    var idle = Completer<void>()..complete();

    var aborted = false;

    final window = spec.contextWindowTokens ?? unknownModelContextFallback;
    final outputReserve = spec.maxOutputTokens ?? 8192;
    final guardBudget = math.max(1024, window - (outputReserve + 2048));

    List<Map<String, dynamic>> guard(List<Map<String, dynamic>> input) {
      final copy = <Map<String, dynamic>>[
        for (final m in input) Map<String, dynamic>.of(m),
      ];
      final before = estimateApiMessagesTokens(copy);
      // L0 middle pruning is a normal per-request optimization; it does not
      // mean the window forced a history cut (`context_trimmed`).
      applyToolResultMiddlePrune(copy);

      // Pin the CURRENT instruction: on a resumed session the last user
      // message is the follow-up task, not the original task at index 0. A
      // generic tail trim can drop older history, but never the instruction
      // the helper has to answer. Keep the map identity so a non-String
      // (multimodal) task can be detected after trimming too.
      Map<String, dynamic>? task;
      for (final m in copy) {
        if (m['role'] == 'user') task = m;
      }

      var result = copy;
      var trimmedByWindow = false;
      if (estimateApiMessagesTokens(result) > guardBudget) {
        final trimmed = trimMessagesToFitTokenLimit(result, guardBudget);
        if (trimmed != null) {
          result = trimmed;
          trimmedByWindow = true;
          final taskContent = task?['content'];
          final alreadyHasTask =
              task != null && result.any((m) => identical(m, task));
          if (task != null && !alreadyHasTask) {
            if (taskContent is String &&
                taskContent.length > guardBudget * charsPerToken) {
              task['content'] =
                  '${taskContent.substring(0, guardBudget * charsPerToken)}\n'
                  '[... truncated to fit the context window ...]';
              trimmedByWindow = true;
            }
            // The task was the newest user turn; append it so a resumed
            // session keeps its chronological position (after retained
            // history) rather than looking like the very first message.
            result.add(task);
          }
        }
      }

      // The system/brief alone can exceed a small window. Cap it first so the
      // provider does not reject the request outright.
      if (estimateApiMessagesTokens(result) > guardBudget &&
          result.isNotEmpty) {
        final maxChars = guardBudget * charsPerToken;
        for (final m in result) {
          if (m['role'] != 'system') break;
          if (_clipSubagentMessageContent(m, maxChars)) {
            trimmedByWindow = true;
          }
        }
      }

      // Irreducible (newest message alone blows the budget): hard-cap its
      // content so the provider cannot reject the request. Handles both the
      // plain-string and the multimodal list shape (text parts are clipped
      // first; if images still make it irreducible they are dropped).
      if (estimateApiMessagesTokens(result) > guardBudget &&
          result.isNotEmpty) {
        final last = result.last;
        final maxChars = guardBudget * charsPerToken;
        if (_clipSubagentMessageContent(last, maxChars)) {
          trimmedByWindow = true;
        }
        if (estimateApiMessagesTokens(result) > guardBudget) {
          final fallback = _subagentContentText(last['content']);
          if (fallback.isNotEmpty) {
            const marker =
                '\n[... attachments omitted to fit the context window ...]';
            final keep = math.max(0, maxChars - marker.length);
            last['content'] =
                '${fallback.substring(0, math.min(fallback.length, keep))}'
                '$marker';
            trimmedByWindow = true;
          }
        }
      }

      if (trimmedByWindow) {
        contextTrimmed = true;
        FlutterLogger.log(
          'subagent_context_trim before=$before after='
          '${estimateApiMessagesTokens(result)} window=$window',
          tag: 'subagent',
        );
      }
      return result;
    }

    Future<Stream<ChatStreamChunk>> guardedSend(
      SubagentRoundRequest request,
    ) async {
      if (aborted || cancelled()) throw const SubagentAborted('cancelled');
      final guarded = guard(request.messages);
      var prepared = request.copyWith(messages: guarded);
      final decorate = decorateRequest;
      if (decorate != null) prepared = decorate(prepared);
      lastRequestMessages = <Map<String, dynamic>>[
        for (final m in prepared.messages) Map<String, dynamic>.of(m),
      ];
      return sendRound(prepared);
    }

    Future<String> guardedToolCall(AgentToolCall call) async {
      if (aborted || cancelled()) {
        return jsonEncode(<String, dynamic>{
          'type': 'tool_error',
          'error': 'subagent_cancelled',
          'message': 'The helper was stopped; the tool was not executed. Do not retry.',
          'tool': call.name,
        });
      }
      inFlightTools++;
      if (inFlightTools == 1) idle = Completer<void>();
      final watch = Stopwatch()..start();
      var resultChars = 0;
      try {
        try {
          onToolStart?.call(call.name);
        } catch (_) {
          // UI progress is best-effort; never fail the tool because of it.
        }
        final result = await onToolCall(call);
        resultChars = result.length;
        return result;
      } finally {
        watch.stop();
        toolCallCount++;
        final step = SubagentTraceStep(
          tool: call.name,
          durationMs: watch.elapsedMilliseconds,
          resultChars: resultChars,
        );
        trace.add(step);
        try {
          onToolEnd?.call(step);
        } catch (_) {
          // UI progress is best-effort; never fail the tool because of it.
        }
        inFlightTools--;
        if (inFlightTools == 0 && !idle.isCompleted) idle.complete();
      }
    }

    final loop = runAgentLoop(
      messages: messages,
      // Wire parameters live in the transport binding (the runner only owns
      // the messages and the run identity).
      sendRound: (roundMessages) => guardedSend(
        SubagentRoundRequest(
          messages: roundMessages,
          requestId: spec.requestId,
          sessionId: spec.sessionId ?? spec.requestId,
        ),
      ),
      onToolCall: guardedToolCall,
      options: AgentLoopOptions(
        maxSteps: spec.maxSteps,
        tokenBudget: spec.tokenBudget,
        // The parent timeline must not receive the helper's tool cards: the
        // summary is the only artefact that travels back.
        emitCalls: false,
      ),
      hooks: AgentLoopHooks(
        onRoundStart: (_, __, ___) async {
          if (cancelled()) {
            aborted = true;
            onAbort?.call();
            return false;
          }
          return true;
        },
      ),
    );

    // Main deadline reserves the wrap-up budget so the WHOLE run still fits
    // inside `spec.timeout` (plan P0-2 item 8). Very short test deadlines keep
    // their value; the 60s floor only applies when there is room for it.
    final mainDeadline = _mainDeadline(spec);

    try {
      await for (final event in _withDeadline(
        loop,
        mainDeadline,
        onTimeout: () {
          onAbort?.call();
        },
      )) {
        switch (event) {
          case AgentStreamEvent(:final chunk):
            if (chunk.errorKind != null) {
              // L1 retry: the round is re-issued, so the partial preamble is
              // discarded exactly like the driver does for the main run.
              buffer.clear();
              roundMaxTokens = 0;
              continue;
            }
            if (chunk.content.isNotEmpty) buffer.write(chunk.content);
            final roundTotal = chunk.usage?.totalTokens ?? chunk.totalTokens;
            if (roundTotal > roundMaxTokens) roundMaxTokens = roundTotal;
          case AgentToolExecutedEvent():
            break;
          case AgentRoundFinishedEvent(:final stepIndex):
            // The finish event is absent on a timeout; track completed rounds
            // here so the trace does not report `steps: 0` for a long run.
            steps = math.max(steps, stepIndex + 1);
            // A tool round's text is a preamble, not the deliverable — but it
            // is the last-resort fallback when the wrap-up round fails.
            final preamble = buffer.toString().trim();
            if (preamble.isNotEmpty) lastNonEmptyText = preamble;
            usageAcrossRounds += roundMaxTokens;
            roundMaxTokens = 0;
            buffer.clear();
          case AgentRunFinishedEvent(
            :final reason,
            :final stepIndex,
            :final messages,
          ):
            steps = stepIndex;
            stopReason = reason;
            finalMessages = <Map<String, dynamic>>[
              for (final m in messages) Map<String, dynamic>.of(m),
            ];
        }
      }
    } on TimeoutException {
      timedOut = true;
    } on SubagentAborted {
      aborted = true;
    } catch (e) {
      if (!cancelled()) error = e.toString();
    }

    // The gate must not be released while a tool is still executing.
    await _waitForToolIdle(
      spec.toolSettleGrace,
      () => inFlightTools,
      idle.future,
    );

    var tokensUsed = priorTokens + usageAcrossRounds + roundMaxTokens;
    // Only a natural completion's last-round text is a deliverable. A timeout
    // or a budget stop leaves a preamble in the buffer — it is a fallback, not
    // the answer.
    var summary = '';
    var summarySource = SubagentSummarySource.none;
    if (error == null &&
        !cancelled() &&
        !timedOut &&
        (stopReason == null || stopReason == AgentRunStopReason.finished)) {
      final finalText = buffer.toString().trim();
      if (finalText.isNotEmpty) {
        summary = finalText;
        summarySource = SubagentSummarySource.finalAnswer;
      }
    }
    var transcript = finalMessages ?? lastRequestMessages;
    var wrapUpText = '';
    final wrapUpBudget = _wrapUpBudget(spec);

    // P0-2: a budget/deadline stop must not throw away everything the helper
    // did. Ask once, text-only, for the deliverable. Never for a user stop.
    final needsWrapUp =
        !cancelled() &&
        error == null &&
        sendWrapUpRound != null &&
        wrapUpBudget > Duration.zero &&
        (timedOut ||
            stopReason == AgentRunStopReason.maxStepsReached ||
            stopReason == AgentRunStopReason.tokenBudgetReached);

    if (needsWrapUp) {
      final base = transcript;
      if (base != null && base.isNotEmpty) {
        final guardedHistory = guard(base);
        final wrapMessages = <Map<String, dynamic>>[
          ...guardedHistory,
          <String, dynamic>{
            'role': 'user',
            'content': _finalRoundInstruction(spec, timedOut: timedOut),
          },
        ];
        final wrapRequest = SubagentRoundRequest(
          messages: wrapMessages,
          tools: null,
          extraHeaders: null,
          extraBody: null,
          maxTokens: spec.maxOutputTokens,
          toolImagesEnabled: false,
          webFetchEnabled: false,
          requestId: spec.requestId == null
              ? null
              : '${spec.requestId}_summary',
          sessionId: spec.sessionId ?? spec.requestId,
          textOnly: true,
        );
        final decorated = decorateRequest?.call(wrapRequest) ?? wrapRequest;
        final collected = await _collectTextRound(
          decorated,
          wrapUpBudget,
          cancelFuture: cancelFuture,
        );
        tokensUsed += collected.tokens;
        // A cancelFuture-only caller (no polling isCancelled) still has to
        // produce a stopped outcome, not a preamble fallback.
        if (collected.cancelled) aborted = true;
        if (collected.ok && !cancelled()) {
          summary = collected.text;
          wrapUpText = collected.text;
          summarySource = SubagentSummarySource.wrapUp;
          // Discard the timeout/tool-round residual so it cannot leak into the
          // summary on a later read.
          buffer.clear();
        }
      }
    }

    // A user stop is not a deliverable: never fall back to a tool-round
    // preamble for a cancelled helper (the parent will show "stopped").
    final isCancelledFinal = cancelled() || aborted;
    if (isCancelledFinal) {
      // A stop is not a deliverable, even when the wrap-up stream delivered
      // its last chunk in the same turn as the cancel signal.
      summary = '';
      wrapUpText = '';
      summarySource = SubagentSummarySource.none;
    }
    if (summary.isEmpty && !isCancelledFinal) {
      if (lastNonEmptyText.isNotEmpty) {
        summary = lastNonEmptyText;
        summarySource = SubagentSummarySource.preamble;
      } else {
        final residual = buffer.toString().trim();
        if (residual.isNotEmpty) {
          summary = residual;
          summarySource = SubagentSummarySource.preamble;
        } else {
          summarySource = SubagentSummarySource.none;
        }
      }
    }
    final partial =
        !isCancelledFinal &&
        error == null &&
        (timedOut ||
            stopReason == AgentRunStopReason.maxStepsReached ||
            stopReason == AgentRunStopReason.tokenBudgetReached);

    // A session keeps the helper's transcript (including the wrap-up body, so
    // a follow-up can see the deliverable that never entered the kernel).
    List<Map<String, dynamic>>? sessionTranscript;
    if (!isCancelledFinal && error == null) {
      final base = transcript;
      if (base != null && base.isNotEmpty) {
        sessionTranscript = <Map<String, dynamic>>[
          for (final m in base) Map<String, dynamic>.of(m),
          if (summarySource == SubagentSummarySource.finalAnswer &&
              summary.isNotEmpty)
            <String, dynamic>{'role': 'assistant', 'content': summary},
          if (wrapUpText.isNotEmpty)
            <String, dynamic>{'role': 'assistant', 'content': wrapUpText},
        ];
        if (sessionTranscript.length > maxStoredTranscriptMessages) {
          final system = <Map<String, dynamic>>[];
          for (final m in sessionTranscript) {
            if (m['role'] != 'system') break;
            system.add(m);
          }
          final keep = maxStoredTranscriptMessages - system.length;
          sessionTranscript = keep > 0
              ? <Map<String, dynamic>>[
                  ...system,
                  ...sessionTranscript.sublist(sessionTranscript.length - keep),
                ]
              : system.take(maxStoredTranscriptMessages).toList();
        }
      }
    }

    return SubagentOutcome(
      summary: summary,
      summarySource: summarySource,
      partial: partial,
      contextTrimmed: contextTrimmed,
      stopReason: stopReason,
      steps: steps,
      toolCallCount: toolCallCount,
      tokensUsed: tokensUsed,
      timedOut: timedOut,
      cancelled: isCancelledFinal,
      error: error,
      profileId: profile?.id ?? spec.profileId,
      sessionId: spec.sessionId,
      trace: trace,
      transcriptMessages: sessionTranscript,
    );
  }

  /// Whole-run deadline minus the wrap-up and settle reservations. Tiny
  /// deadlines keep the wrap-up budget when the grace cannot fit.
  Duration _mainDeadline(SubagentSpec spec) {
    final wrap = _wrapUpBudget(spec);
    if (wrap <= Duration.zero) return spec.timeout;
    // The settle wait happens between the main deadline and the wrap-up. Keep
    // it inside the total budget when there is room; for tiny deadlines the
    // grace is best-effort and the wrap-up reservation wins.
    final withGrace = spec.timeout - wrap - spec.toolSettleGrace;
    if (withGrace > Duration.zero) return withGrace;
    return spec.timeout - wrap;
  }

  /// The wrap-up cannot extend the whole-run deadline. When the requested
  /// wrap-up budget does not fit inside [SubagentSpec.timeout], skip the
  /// extra round and keep the partial fallback instead.
  Duration _wrapUpBudget(SubagentSpec spec) {
    if (spec.wrapUpTimeout <= Duration.zero) return Duration.zero;
    if (spec.timeout <= spec.wrapUpTimeout) return Duration.zero;
    return spec.wrapUpTimeout;
  }

  Future<void> _waitForToolIdle(
    Duration grace,
    int Function() inFlight,
    Future<void> idle,
  ) async {
    if (inFlight() == 0) return;
    try {
      await Future.any<void>([idle, Future<void>.delayed(grace)]);
    } catch (_) {}
    final remaining = inFlight();
    if (remaining > 0) {
      onZombie?.call(remaining);
      FlutterLogger.log(
        'subagent_zombie: $remaining child tool(s) still running after '
        '${grace.inMilliseconds}ms; releasing the serial gate.',
        tag: 'subagent',
      );
    }
  }

  /// Collect a text-only wrap-up round. Never throws; a timeout/error/empty
  /// body resolves with `ok: false` and the tokens already spent.
  Future<({String text, int tokens, bool ok, bool cancelled})>
  _collectTextRound(
    SubagentRoundRequest request,
    Duration timeout, {
    Future<void>? cancelFuture,
  }) async {
    final buffer = StringBuffer();
    final done = Completer<void>();
    StreamSubscription<ChatStreamChunk>? sub;
    var maxTotal = 0;
    var failed = false;
    var cancelledWhileWaiting = false;
    try {
      final stream = await sendWrapUpRound!(request);
      sub = stream.listen(
        (chunk) {
          if (chunk.errorKind != null) {
            buffer.clear();
            maxTotal = 0;
            return;
          }
          if (chunk.content.isNotEmpty) buffer.write(chunk.content);
          final total = chunk.usage?.totalTokens ?? chunk.totalTokens;
          if (total > maxTotal) maxTotal = total;
        },
        onError: (_) {
          failed = true;
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      final completion = done.future.timeout(
        timeout,
        onTimeout: () async {
          failed = true;
          final requestId = request.requestId;
          if (requestId != null && requestId.isNotEmpty) {
            onAbortRequest?.call(requestId);
          }
          await sub?.cancel();
        },
      );
      final cancelWait = cancelFuture?.then((_) {
        cancelledWhileWaiting = true;
      });
      if (cancelWait != null) {
        await Future.any<void>(<Future<void>>[completion, cancelWait]);
        if (cancelledWhileWaiting) {
          failed = true;
          final requestId = request.requestId;
          if (requestId != null && requestId.isNotEmpty) {
            onAbortRequest?.call(requestId);
          }
          // Complete the source future so its timeout timer is released; the
          // caller is returning now, not waiting for the provider.
          if (!done.isCompleted) done.complete();
          await sub.cancel();
        }
      } else {
        await completion;
      }
    } catch (_) {
      failed = true;
    }
    final text = buffer.toString().trim();
    return (
      text: failed ? '' : text,
      tokens: maxTotal,
      ok: !failed && text.isNotEmpty,
      cancelled: cancelledWhileWaiting,
    );
  }

  String _finalRoundInstruction(SubagentSpec spec, {required bool timedOut}) {
    final limit = timedOut ? 'time' : 'step or token';
    return '[FINAL ROUND — NO TOOLS]\n'
        'The helper run has reached its $limit limit.\n'
        'Do not call any tools. Write the final deliverable now: what you '
        'accomplished, concrete results (paths, line numbers, values), and '
        'what remains unfinished or unverified.';
  }
}

/// Clip one message's content in place. Returns true when anything changed.
///
/// Strings keep the existing truncation marker; multimodal lists have their
/// textual parts clipped cumulatively so a giant pasted transcript cannot
/// bypass the guard merely by being encoded as `[{type:text,...}]`.
bool _clipSubagentMessageContent(Map<String, dynamic> message, int maxChars) {
  const marker = '\n[... truncated to fit the context window ...]';
  final content = message['content'];
  if (content is String) {
    if (content.length <= maxChars) return false;
    final keep = math.max(0, maxChars - marker.length);
    message['content'] = '${content.substring(0, keep)}$marker';
    return true;
  }
  if (content is! List) return false;

  var remaining = maxChars;
  var changed = false;
  final clipped = <dynamic>[];
  for (final part in content) {
    if (part is Map && part['text'] is String) {
      final text = part['text'] as String;
      if (remaining <= 0) {
        changed = true;
        continue;
      }
      if (text.length > remaining) {
        final copy = Map<String, dynamic>.from(part);
        copy['text'] = remaining > marker.length
            ? '${text.substring(0, remaining - marker.length)}$marker'
            : text.substring(0, remaining);
        clipped.add(copy);
        remaining = 0;
        changed = true;
        continue;
      }
      remaining -= text.length;
    }
    clipped.add(part);
  }
  if (changed) message['content'] = clipped;
  return changed;
}

/// Best-effort plain text for a multimodal content list.
String _subagentContentText(Object? content) {
  if (content is String) return content;
  if (content is! List) return '';
  final buffer = StringBuffer();
  for (final part in content) {
    if (part is Map && part['text'] is String) {
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(part['text']);
    }
  }
  return buffer.toString();
}

/// Replace helper-produced image markers with inert references (P1-6):
/// the parent transport must not try to attach a child's `[image:...]` result.
String replaceSubagentImageMarkers(String text) {
  if (!text.contains('[image:')) return text;
  return text.replaceAll('[image:', '[image-ref: ');
}

/// Compress a persisted `spawn_subagent` result for cross-turn replay (P1-5).
///
/// Keeps the contract fields and a 2k-char summary / 500-char error, and marks
/// the stub `replay_truncated`. Short payloads pass through unchanged, and a
/// malformed payload is safely clipped rather than dropped.
String compactSubagentReplay(String content, {int maxSummaryChars = 2000}) {
  final sanitized = replaceSubagentImageMarkers(content);
  if (sanitized.length <= maxSummaryChars) return sanitized;

  String clip(String value, int max) {
    if (value.length <= max) return value;
    return '${value.substring(0, max)}\n[... truncated ...]';
  }

  Object? decoded;
  try {
    decoded = jsonDecode(sanitized);
  } catch (_) {
    decoded = null;
  }
  if (decoded is! Map) {
    return clip(sanitized, maxSummaryChars);
  }
  final parsed = decoded.map((key, value) => MapEntry(key.toString(), value));
  final rawSummary = (parsed['summary'] ?? '').toString();
  final summaryWasClipped = rawSummary.length > maxSummaryChars;
  var replaySummary = clip(rawSummary, maxSummaryChars);
  // Keep the untrusted wrapper balanced in the replayed context: clipping can
  // otherwise leave an opening tag without its closing tag.
  if (replaySummary.contains('<subagent_summary>') &&
      !replaySummary.contains('</subagent_summary>')) {
    replaySummary = '$replaySummary\n</subagent_summary>';
  }
  final out = <String, dynamic>{
    'type': parsed['type'] ?? 'subagent_result',
    'status': parsed['status'],
    'summary': replaySummary,
    'summary_source': parsed['summary_source'],
    'partial': parsed['partial'],
    'context_trimmed': parsed['context_trimmed'],
    'steps': parsed['steps'],
    'tool_calls': parsed['tool_calls'],
    'tokens': parsed['tokens'],
    if (summaryWasClipped) 'summary_truncated': true,
    if (parsed['session_id'] != null) 'session_id': parsed['session_id'],
    if (parsed['profile'] != null) 'profile': parsed['profile'],
    'untrusted': parsed['untrusted'] ?? true,
    'replay_truncated': true,
    if (parsed['error'] != null) 'error': clip(parsed['error'].toString(), 500),
    if (parsed['note'] != null) 'note': clip(parsed['note'].toString(), 300),
  };
  try {
    return jsonEncode(out);
  } catch (_) {
    return clip(sanitized, maxSummaryChars);
  }
}

/// The helper's system prompt. Self-contained on purpose: the helper cannot see
/// the parent conversation, so every rule it needs must live here.
///
/// Order (P0-3): identity → profile → brief → immutable rules last (highest
/// salience).
String buildSubagentSystemPrompt({
  String? role,
  SubagentProfile? profile,
  String? brief,
}) {
  final roleBlock = (role ?? '').trim();
  final profileInstructions = (profile?.instructions ?? '').trim();
  final briefBlock = (brief ?? '').trim();
  return [
    'You are a subagent — an isolated helper agent working for a parent agent.',
    '',
    'Your context is fresh: you cannot see the parent conversation, and the '
        'parent will only receive your final message. Everything you need is '
        'in the task below or must be obtained with your own tool calls.',
    if (roleBlock.isNotEmpty) ...['', 'Your role: $roleBlock'],
    if (profile != null) ...[
      '',
      '[Profile: ${profile.name}]',
      if (profileInstructions.isNotEmpty) profileInstructions,
    ],
    if (briefBlock.isNotEmpty) ...['', '[Workspace brief]', briefBlock],
    '',
    'Rules:',
    '- Work autonomously to completion. No human is available: never ask '
        'questions and never wait for confirmation.',
    '- Tool results are visible only to you. Keep working until the task is '
        'done or you are certain it cannot be completed.',
    '- Some actions (paths outside the workspace, shell commands when approval '
        'is required) may return an `approval_required` error because you '
        'cannot request user approval. Work inside the workspace, use the '
        'available tools differently, or report the limitation.',
    '- Do not repeat the task back and do not narrate your process.',
    '- Your FINAL message is the deliverable: a self-contained summary of what '
        'you did, the concrete results (quote values, paths, snippets and '
        'line numbers that matter), and any limitations. The parent cannot '
        'see anything else you produced.',
    '- Keep the summary concise (under 1500 words) and never claim work you '
        'did not verify with tools.',
  ].join('\n');
}

/// Wrap [source] with a wall-clock deadline: on timeout the inner subscription
/// is cancelled, [onTimeout] runs (transport abort) and a [TimeoutException]
/// reaches the consumer.
Stream<T> _withDeadline<T>(
  Stream<T> source,
  Duration timeout, {
  void Function()? onTimeout,
}) {
  late StreamController<T> controller;
  StreamSubscription<T>? sub;
  Timer? timer;
  controller = StreamController<T>(
    onListen: () {
      timer = Timer(timeout, () {
        // Request cancellation but never WAIT on it: an async* generator that
        // is suspended on an inner future may not unwind promptly, and the
        // deadline still has to fire (otherwise the helper hangs forever and,
        // through the serial gate, every later helper with it).
        try {
          onTimeout?.call();
        } catch (_) {}
        final pending = sub;
        sub = null;
        pending?.cancel();
        if (controller.isClosed) return;
        controller.addError(TimeoutException('subagent deadline', timeout));
        controller.close();
      });
      sub = source.listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          timer?.cancel();
          if (!controller.isClosed) controller.close();
        },
        cancelOnError: true,
      );
    },
    onPause: () => sub?.pause(),
    onResume: () => sub?.resume(),
    onCancel: () {
      timer?.cancel();
      return sub?.cancel();
    },
  );
  return controller.stream;
}
