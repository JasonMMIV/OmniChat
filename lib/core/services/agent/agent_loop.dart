/// Agent loop kernel (ADR-A1).
///
/// A pure, Flutter-free *mechanical skeleton* that drives one agent run:
///
/// ```
/// for (step in 0..maxSteps):
///   (budget / max-steps soft gates checked here — never mid-round)
///   round = sendRound(messages)            // exactly one LLM request
///   passthrough every chunk to the caller
///   if round produced no tool calls → run finished
///   for each tool call: execute once (side effects only here)
///   append OpenAI-neutral assistant tool_calls + role:'tool' messages
/// ```
///
/// The kernel holds **no policy**: approval, cross-round usage accounting,
/// compression triggers, todo injection and checkpoints live in the driver
/// layer via [AgentLoopHooks] and the events this stream yields. This mirrors
/// kelivo `tool_loop_runner.dart` (kernel shape) and RikkaHub
/// `GenerationHandler` (driver shape); see IMPORT_PLAN_COWORK.md P0-1 / P0-5.
///
/// Contract notes:
/// - Follow-up messages are appended in the OpenAI-neutral shape already used
///   by `message_builder_service` (§3.11 replay), so the per-provider
///   converters in `ChatApiService` keep working unchanged.
/// - Retry semantics: a round is a single transport request (its own L1
///   retry). The kernel never re-runs a tool — retrying a round means
///   re-sending the same follow-up request, never replaying side effects
///   (ADR-A3).
/// - Dart `async*` rule: this function only ever uses `await for` + `yield`,
///   never `yield*` (see manual §3.10).
library;

import 'dart:async';
import 'dart:convert';

import '../api/chat_stream_chunk.dart';

/// How a run ended.
enum AgentRunStopReason {
  /// The last round produced no tool calls — normal completion.
  finished,

  /// [AgentLoopOptions.maxSteps] was reached while the model still wanted to
  /// call tools. Tools from the final round were already executed and their
  /// results persisted; the driver may offer the user a resume entry point
  /// (RikkaHub `canResumeExecution` semantics).
  maxStepsReached,

  /// Cumulative token usage exceeded [AgentLoopOptions.tokenBudget] before the
  /// next round would have been dispatched. This is a *soft* gate: the run
  /// stops cleanly and the driver decides what to do (ask the user, resume
  /// with a higher budget, …) instead of being hard-cut mid-stream.
  tokenBudgetReached,

  /// A hook (e.g. [AgentLoopHooks.onRoundStart]) vetoed continuing.
  stoppedByHook,
}

/// Options for a single agent run.
class AgentLoopOptions {
  const AgentLoopOptions({
    this.maxSteps = 256,
    this.tokenBudget,
    this.emitCalls = true,
  });

  /// Upper bound on the number of rounds (tool-executing rounds included)
  /// this run may dispatch. Mirrors RikkaHub's parameterized `maxSteps=256`.
  /// The run still finishes normally when a round returns no tool calls.
  final int maxSteps;

  /// Soft budget over cumulative token usage (summed across rounds from
  /// `usage.totalTokens`, falling back to per-round `totalTokens` when a
  /// provider omits usage). When exceeded the run stops before dispatching
  /// the next round with [AgentRunStopReason.tokenBudgetReached].
  final int? tokenBudget;

  /// When true (default), the kernel re-emits each executed tool result as a
  /// synthetic `ChatStreamChunk.toolResults` event so existing UI / tool-card
  /// persistence paths that consume tool results keep working unchanged.
  final bool emitCalls;
}

/// Policy hooks consulted at loop boundaries (approval / pause / budget /
/// checkpointing). All hooks are optional; the kernel never blocks on them —
/// a `false` from [onRoundStart] ends the run cleanly so the driver can
/// resume later with a fresh [runAgentLoop] call (ADR-A5 pause semantics).
class AgentLoopHooks {
  const AgentLoopHooks({
    this.onRoundStart,
    this.onToolExecuted,
    this.onRoundEnd,
  });

  /// Called before each round is dispatched, with the current step index,
  /// the neutral messages accumulated so far and the token usage accumulated
  /// so far. Returning `false` stops the run with
  /// [AgentRunStopReason.stoppedByHook] before any request is sent.
  final Future<bool> Function(
    int stepIndex,
    List<Map<String, dynamic>> messages,
    int tokensSoFar,
  )?
  onRoundStart;

  /// Called after each tool call executes, before the result is appended to
  /// the run messages.
  final Future<void> Function(AgentToolCall call, String result)?
  onToolExecuted;

  /// Called after a round's tool calls were all executed and the follow-up
  /// messages were appended.
  final Future<void> Function(int stepIndex, List<AgentToolCall> executed)?
  onRoundEnd;
}

/// A single tool call surfaced by a model round.
class AgentToolCall {
  const AgentToolCall({
    required this.toolCallId,
    required this.name,
    required this.arguments,
  });

  /// Provider tool-call id; stable across the round and reused as the
  /// `tool_call_id` of the matching role:'tool' follow-up message.
  final String toolCallId;
  final String name;
  final Map<String, dynamic> arguments;

  /// OpenAI-neutral assistant `tool_calls[]` entry (same shape as the
  /// §3.11 replay builder in `message_builder_service`).
  Map<String, dynamic> toNeutralCallMap() => <String, dynamic>{
    'id': toolCallId,
    'type': 'function',
    'function': <String, dynamic>{
      'name': name,
      'arguments': encodeArguments(arguments),
    },
  };
}

/// Encode tool arguments for the wire format; a serialization failure yields
/// '{}' rather than crashing the loop (mirrors `message_builder_service`).
String encodeArguments(Map<String, dynamic> arguments) {
  try {
    return jsonEncode(arguments);
  } catch (_) {
    return '{}';
  }
}

/// Neutral-format follow-up assembly (ADR-A2): the exact message shapes the
/// §3.11 replay path produces today, so every provider converter in
/// `ChatApiService` can consume them without change.
abstract final class AgentNeutralMessages {
  /// Build the assistant `tool_calls` message for [calls].
  ///
  /// [assistantExtras] may carry reasoning-echo fields (`reasoning_content`,
  /// `reasoning_details`, Gemini thought signatures…) that must be echoed on
  /// the follow-up assistant message for the round to keep DeepSeek /
  /// Kimi / OpenRouter multi-round tool calls working. These fields are held
  /// in memory for the duration of the run only — they are never written into
  /// cross-turn replay (§3.11 known limitation stays).
  static Map<String, dynamic> assistantMessage({
    required List<AgentToolCall> calls,
    Map<String, dynamic>? assistantExtras,
  }) {
    return <String, dynamic>{
      'role': 'assistant',
      'content': '\n\n',
      'tool_calls': [for (final call in calls) call.toNeutralCallMap()],
      ...?assistantExtras,
    };
  }

  /// Build the role:'tool' result message for [call] / [result].
  static Map<String, dynamic> toolResultMessage({
    required AgentToolCall call,
    required String result,
  }) {
    return <String, dynamic>{
      'role': 'tool',
      'name': call.name,
      'tool_call_id': call.toolCallId,
      'content': result,
    };
  }
}

/// Events yielded by [runAgentLoop].
sealed class AgentLoopEvent {
  const AgentLoopEvent();
}

/// A raw transport chunk passed through untouched (text / reasoning / tool
/// calls / usage / retry status / finish).
final class AgentStreamEvent extends AgentLoopEvent {
  const AgentStreamEvent(this.chunk);
  final ChatStreamChunk chunk;
}

/// A tool call was executed exactly once; [result] is the handler's output
/// (already a string; structured error JSON on failure).
final class AgentToolExecutedEvent extends AgentLoopEvent {
  const AgentToolExecutedEvent(this.call, this.result);
  final AgentToolCall call;
  final String result;
}

/// A round completed: every tool call it produced was executed and the
/// follow-up messages were appended to the run.
final class AgentRoundFinishedEvent extends AgentLoopEvent {
  const AgentRoundFinishedEvent({
    required this.stepIndex,
    required this.executed,
  });

  final int stepIndex;
  final List<AgentToolCall> executed;
}

/// The run ended; see [AgentRunStopReason] for the outcome.
final class AgentRunFinishedEvent extends AgentLoopEvent {
  const AgentRunFinishedEvent({
    required this.reason,
    required this.stepIndex,
    required this.executedCallCount,
    required this.messages,
    required this.tokensUsed,
  });

  final AgentRunStopReason reason;
  final int stepIndex;
  final int executedCallCount;

  /// The neutral messages accumulated by the run — the resume point a driver
  /// can hand back to a fresh [runAgentLoop] call.
  final List<Map<String, dynamic>> messages;

  /// Cumulative token usage observed across all rounds.
  final int tokensUsed;
}

/// Drive one agent run (kernel shape; driver = caller).
///
/// [messages] are the initial OpenAI-neutral messages (already containing any
/// §3.11 tool replay). [sendRound] issues exactly one transport request per
/// call and returns its chunk stream. [onToolCall] executes a single tool and
/// returns its string result; it is invoked at most once per call per run.
Stream<AgentLoopEvent> runAgentLoop({
  required List<Map<String, dynamic>> messages,
  required Future<Stream<ChatStreamChunk>> Function(
    List<Map<String, dynamic>> messages,
  )
  sendRound,
  required Future<String> Function(AgentToolCall call) onToolCall,
  AgentLoopOptions options = const AgentLoopOptions(),
  AgentLoopHooks hooks = const AgentLoopHooks(),
}) async* {
  final working = List<Map<String, dynamic>>.of(messages);

  var stepIndex = 0;
  var executedCallCount = 0;
  var tokensUsed = 0;
  var usageSeenThisRound = false;
  var maxTokensThisRound = 0;

  bool budgetExceeded() =>
      options.tokenBudget != null && tokensUsed >= options.tokenBudget!;

  AgentRunFinishedEvent runEnd(AgentRunStopReason reason) =>
      AgentRunFinishedEvent(
        reason: reason,
        stepIndex: stepIndex,
        executedCallCount: executedCallCount,
        messages: working,
        tokensUsed: tokensUsed,
      );

  while (true) {
    // === Soft gates, checked at round boundaries only (never mid-round) ===
    if (options.maxSteps > 0 && stepIndex >= options.maxSteps) {
      yield runEnd(AgentRunStopReason.maxStepsReached);
      return;
    }
    if (budgetExceeded()) {
      yield runEnd(AgentRunStopReason.tokenBudgetReached);
      return;
    }
    if (hooks.onRoundStart != null) {
      final ok = await hooks.onRoundStart!(stepIndex, working, tokensUsed);
      if (!ok) {
        yield runEnd(AgentRunStopReason.stoppedByHook);
        return;
      }
    }

    // === One round = one transport request (its own L1 retry) ===
    usageSeenThisRound = false;
    maxTokensThisRound = 0;
    final calls = <AgentToolCall>[];
    // Transport-owned provider extras (reasoning echo policy) to merge onto
    // the follow-up assistant message; last non-null chunk wins (the toolCalls
    // chunk carries the round's accumulated echo fields in expose mode).
    Map<String, dynamic>? roundExtras;
    final round = await sendRound(working);
    await for (final chunk in round) {
      if (chunk.usage != null) {
        usageSeenThisRound = true;
        tokensUsed += chunk.usage!.totalTokens;
      } else if (chunk.totalTokens > maxTokensThisRound) {
        maxTokensThisRound = chunk.totalTokens;
      }
      if (chunk.assistantExtras != null) {
        // Merge (not replace): a round may surface several tool-call chunks
        // (e.g. Gemini per-part functionCall), each carrying its own extras
        // such as per-call thought signatures.
        roundExtras = <String, dynamic>{
          ...?roundExtras,
          ...?chunk.assistantExtras,
        };
      }
      if ((chunk.toolCalls ?? const []).isNotEmpty) {
        for (final tc in chunk.toolCalls!) {
          calls.add(
            AgentToolCall(
              toolCallId: tc.id,
              name: tc.name,
              arguments: tc.arguments,
            ),
          );
        }
      }
      yield AgentStreamEvent(chunk);
    }
    if (!usageSeenThisRound && maxTokensThisRound > 0) {
      tokensUsed += maxTokensThisRound;
    }

    if (calls.isEmpty) {
      // Normal completion: the model answered without requesting tools.
      yield runEnd(AgentRunStopReason.finished);
      return;
    }

    // === Execute every tool call exactly once (ADR-A3) ===
    final executed = <AgentToolCall>[];
    final resultsById = <String, String>{};
    for (final call in calls) {
      String result;
      try {
        result = await onToolCall(call);
      } catch (e) {
        // The handler contract is to return structured error JSON, but a
        // throwing tool must never abort the run: surface the error to the
        // model as an execution error and keep going.
        result = jsonEncode(<String, dynamic>{
          'type': 'tool_error',
          'error': 'execution_error',
          'message': e.toString(),
          'tool': call.name,
        });
      }
      resultsById[call.toolCallId] = result;
      executed.add(call);
      executedCallCount++;
      yield AgentToolExecutedEvent(call, result);
      if (hooks.onToolExecuted != null) {
        await hooks.onToolExecuted!(call, result);
      }
      if (options.emitCalls) {
        // Synthetic tool-result chunk so existing `handleToolResultsChunk`
        // style consumers (UI cards + tool event persistence) keep working
        // without any change.
        yield AgentStreamEvent(
          ChatStreamChunk(
            content: '',
            isDone: false,
            totalTokens: 0,
            toolResults: <ToolResultInfo>[
              ToolResultInfo(
                id: call.toolCallId,
                name: call.name,
                arguments: call.arguments,
                content: result,
              ),
            ],
          ),
        );
      }
    }

    // === Append neutral follow-up messages and loop ===
    working.add(
      AgentNeutralMessages.assistantMessage(
        calls: calls,
        assistantExtras: roundExtras,
      ),
    );
    for (final call in executed) {
      working.add(
        AgentNeutralMessages.toolResultMessage(
          call: call,
          result: resultsById[call.toolCallId] ?? '',
        ),
      );
    }
    stepIndex++;
    if (hooks.onRoundEnd != null) {
      await hooks.onRoundEnd!(stepIndex - 1, executed);
    }
    yield AgentRoundFinishedEvent(stepIndex: stepIndex - 1, executed: executed);
  }
}
