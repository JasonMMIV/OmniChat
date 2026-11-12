/// P2-3 subagent runtime (`spawn_subagent`, docs/Cowork剩餘項目實作計劃.md §2.6).
///
/// A subagent is a **fresh-context** agent run driven by the same kernel as the
/// main generation (`agent_loop.dart`): it gets its own system + task messages,
/// its own step ceiling and token budget, executes tools through the injected
/// handler, and returns **only a final summary** to the parent. The parent
/// conversation never receives the helper's raw tool calls or tool output —
/// that isolation is the whole point (token savings + noise isolation).
///
/// Deliberately Flutter-free and transport-free: [sendRound] and [onToolCall]
/// are injected, so the semantics below are unit-testable without a provider
/// tree or a network.
///
/// Contracts:
/// - **Serialized**: subagent runs are queued behind each other process-wide
///   (manual §5.1 "never-parallel" for external processes). Two proposers that
///   each spawn a helper cannot interleave their tool side effects.
/// - **Independent budget**: [SubagentSpec.maxSteps] / [SubagentSpec.tokenBudget]
///   are counted from zero and never consume the parent run's budget.
/// - **No recursion**: the caller must exclude [spawnSubagentToolName] from the
///   child tool list ([subagentChildTools]); the tool handler also refuses a
///   nested call as defense in depth.
/// - **Fail-open**: a transport error, timeout or empty answer is reported as a
///   structured status; it never throws into the parent tool loop.
library;

import 'dart:async';
import 'dart:convert';

import '../api/chat_stream_chunk.dart';
import 'agent_loop.dart';

/// Tool name advertised to the parent model.
const String spawnSubagentToolName = 'spawn_subagent';

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

/// Child tool list: the parent's list minus [subagentExcludedToolNames].
///
/// Pure so the inheritance rule can be asserted without a provider tree.
List<Map<String, dynamic>> subagentChildTools(
  List<Map<String, dynamic>>? parentTools,
) {
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
    result.add(def);
  }
  return result;
}

/// Parent generation snapshot a helper inherits.
///
/// Kept as one object on purpose: the inherited set (provider, model, tools,
/// custom headers/body, output cap) has to stay identical across the tool
/// handler, the child transport and the tests. Adding a field here forces
/// every call site to think about it instead of silently dropping it.
class SubagentLaunchConfig {
  const SubagentLaunchConfig({
    required this.providerKey,
    required this.modelId,
    required this.tools,
    this.extraHeaders,
    this.extraBody,
    this.maxTokens,
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

  /// 0 = parent generation, 1 = helper. Nested helpers are refused.
  final int depth;

  SubagentLaunchConfig child(List<Map<String, dynamic>> childTools) {
    return SubagentLaunchConfig(
      providerKey: providerKey,
      modelId: modelId,
      tools: childTools,
      extraHeaders: extraHeaders,
      extraBody: extraBody,
      maxTokens: maxTokens,
      depth: depth + 1,
    );
  }
}

/// One subagent invocation.
class SubagentSpec {
  const SubagentSpec({
    required this.task,
    this.role,
    this.maxSteps = defaultMaxSteps,
    this.tokenBudget = defaultTokenBudget,
    this.timeout = defaultTimeout,
  });

  /// Self-contained instructions for the helper.
  final String task;

  /// Optional specialization ("code reviewer", "researcher", …).
  final String? role;

  /// Tool rounds the helper may dispatch (independent of the parent).
  final int maxSteps;

  /// Soft budget over the helper's cumulative token usage.
  final int tokenBudget;

  /// Wall-clock deadline for the whole helper run.
  final Duration timeout;

  static const int defaultMaxSteps = 16;
  static const int maxStepsLimit = 40;
  static const int defaultTokenBudget = 120000;
  static const Duration defaultTimeout = Duration(minutes: 10);

  /// Task cap: the task travels as one user message; 32 KB is already far
  /// beyond a useful delegation and keeps a runaway prompt out of the wire.
  static const int maxTaskChars = 32000;

  /// Role cap: a line or two, not a second task description.
  static const int maxRoleChars = 2000;

  /// Normalize model-supplied arguments (clamping, trimming, truncation).
  factory SubagentSpec.fromArguments(Map<String, dynamic> args) {
    final task = (args['task'] ?? '').toString().trim();
    final role = (args['role'] ?? '').toString().trim();
    final rawSteps = args['max_steps'];
    var steps = defaultMaxSteps;
    if (rawSteps is num) {
      steps = rawSteps.toInt();
    } else if (rawSteps is String) {
      steps = int.tryParse(rawSteps) ?? defaultMaxSteps;
    }
    return SubagentSpec(
      task: task.length > maxTaskChars
          ? task.substring(0, maxTaskChars)
          : task,
      role: role.isEmpty
          ? null
          : (role.length > maxRoleChars
                ? role.substring(0, maxRoleChars)
                : role),
      maxSteps: steps.clamp(1, maxStepsLimit).toInt(),
    );
  }
}

/// What one helper run produced. [summary] is the only model-facing artefact.
class SubagentOutcome {
  const SubagentOutcome({
    required this.summary,
    this.stopReason,
    this.steps = 0,
    this.toolCallCount = 0,
    this.tokensUsed = 0,
    this.timedOut = false,
    this.cancelled = false,
    this.error,
  });

  final String summary;
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

  /// Hard cap on the summary embedded in the tool-result JSON. The result is
  /// a JSON contract the model parses, so the TEXT is clipped here — letting
  /// [ToolResultCaps] cut the encoded string would corrupt the JSON.
  static const int maxSummaryChars = 24000;

  /// Error strings (often an entire provider response body) are clipped for
  /// the same reason: the encoded result has to stay under the tool cap.
  static const int maxErrorChars = 2000;

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
        return 'stopped';
      case null:
        return 'empty';
    }
  }

  bool get isComplete => status == 'finished';

  /// Structured tool result the parent model reads.
  String toToolResultJson() {
    final note = _noteFor(status);
    final truncated = summary.length > maxSummaryChars;
    final rendered = !truncated
        ? summary
        : '${summary.substring(0, maxSummaryChars)}\n\n'
              '[... summary truncated — ${summary.length} chars total ...]';
    return jsonEncode(<String, dynamic>{
      'type': 'subagent_result',
      'status': status,
      'summary': rendered.isEmpty
          ? '(the subagent produced no summary)'
          : rendered,
      'steps': steps,
      'tool_calls': toolCallCount,
      'tokens': tokensUsed,
      if (truncated) 'summary_truncated': true,
      if (error != null)
        'error': error!.length > maxErrorChars
            ? error!.substring(0, maxErrorChars)
            : error,
      if (note != null) 'note': note,
    });
  }

  static String? _noteFor(String status) {
    switch (status) {
      case 'timeout':
        return 'The helper hit its time limit, so the summary is partial. '
            'Split the task into smaller pieces or finish the work yourself.';
      case 'max_steps':
      case 'token_budget':
        return 'The helper stopped at its own limit before finishing. Its '
            'summary may be partial; narrow the task or continue yourself.';
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

/// Serial queue shared by every runner instance in the process (§5.1).
///
/// Subagent tool calls execute inside a parent tool call, so a single
/// generation is already serial; this gate additionally covers concurrent
/// generations (AI Team proposers) that each spawn a helper.
Future<void> _serialGate = Future<void>.value();

Future<T> _serialized<T>(Future<T> Function() action) async {
  final previous = _serialGate;
  final completer = Completer<void>();
  _serialGate = completer.future;
  await previous;
  try {
    return await action();
  } finally {
    completer.complete();
  }
}

/// Drives one subagent run through the agent-loop kernel.
class SubagentRunner {
  SubagentRunner({required this.sendRound, required this.onToolCall});

  /// One transport request per kernel round (tools surfaced, never executed).
  final Future<Stream<ChatStreamChunk>> Function(
    List<Map<String, dynamic>> messages,
  )
  sendRound;

  /// Executes one child tool call. Permission policy is inherited from the
  /// caller (same workspace, same switches), but the helper never surfaces an
  /// approval card — see the system prompt's `approval_required` guidance.
  final Future<String> Function(AgentToolCall call) onToolCall;

  /// Run [spec] to completion (or timeout) and return its summary.
  Future<SubagentOutcome> run(
    SubagentSpec spec, {
    bool Function()? isCancelled,
  }) {
    return _serialized(() => _run(spec, isCancelled: isCancelled));
  }

  Future<SubagentOutcome> _run(
    SubagentSpec spec, {
    bool Function()? isCancelled,
  }) async {
    final messages = <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'system',
        'content': buildSubagentSystemPrompt(role: spec.role),
      },
      <String, dynamic>{'role': 'user', 'content': 'Task:\n${spec.task}'},
    ];

    final buffer = StringBuffer();
    var roundMaxTokens = 0;
    var usageAcrossRounds = 0;
    var toolCallCount = 0;
    var steps = 0;
    AgentRunStopReason? stopReason;
    var timedOut = false;
    String? error;

    final loop = runAgentLoop(
      messages: messages,
      sendRound: sendRound,
      onToolCall: onToolCall,
      options: AgentLoopOptions(
        maxSteps: spec.maxSteps,
        tokenBudget: spec.tokenBudget,
        // The parent timeline must not receive the helper's tool cards: the
        // summary is the only artefact that travels back.
        emitCalls: false,
      ),
      hooks: AgentLoopHooks(
        onRoundStart: (_, __, ___) async => !(isCancelled?.call() ?? false),
      ),
    );

    try {
      await for (final event in _withDeadline(loop, spec.timeout)) {
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
            toolCallCount++;
          case AgentRoundFinishedEvent():
            // A tool round's text is a preamble, not the deliverable.
            usageAcrossRounds += roundMaxTokens;
            roundMaxTokens = 0;
            buffer.clear();
          case AgentRunFinishedEvent(:final reason, :final stepIndex):
            steps = stepIndex;
            stopReason = reason;
        }
      }
    } on TimeoutException {
      timedOut = true;
    } catch (e) {
      // A cancelled transport may surface as an exception; that is not a
      // helper failure, so do not report it as one.
      if (!(isCancelled?.call() ?? false)) error = e.toString();
    }

    return SubagentOutcome(
      summary: buffer.toString().trim(),
      stopReason: stopReason,
      steps: steps,
      toolCallCount: toolCallCount,
      tokensUsed: usageAcrossRounds + roundMaxTokens,
      timedOut: timedOut,
      cancelled: isCancelled?.call() ?? false,
      error: error,
    );
  }
}

/// The helper's system prompt. Self-contained on purpose: the helper cannot see
/// the parent conversation, so every rule it needs must live here.
String buildSubagentSystemPrompt({String? role}) {
  final roleBlock = (role ?? '').trim();
  return [
    'You are a subagent — an isolated helper agent working for a parent agent.',
    '',
    'Your context is fresh: you cannot see the parent conversation, and the '
        'parent will only receive your final message. Everything you need is '
        'in the task below or must be obtained with your own tool calls.',
    if (roleBlock.isNotEmpty) ...['', 'Your role: $roleBlock'],
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

/// Wrap [source] with a wall-clock deadline: on timeout the inner
/// subscription is cancelled and a [TimeoutException] reaches the consumer.
Stream<T> _withDeadline<T>(Stream<T> source, Duration timeout) {
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
