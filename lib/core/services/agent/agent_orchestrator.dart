// Agent-loop driver (IMPORT_PLAN_COWORK.md P0-2).
//
// The connection layer between the pure kernel
// (`lib/core/services/agent/agent_loop.dart`) and the existing transport +
// UI pipeline:
//
//   - `sendRound` is a single-round `ChatApiService.sendMessageStream` call —
//     one transport request per kernel round, tools surfaced but NOT executed
//     by the transport.
//   - the kernel executes tools via the injected legacy handler
//     (`(name, args) => String`, the same contract `chat_actions` uses
//     today) and composes the follow-up messages.
//   - kernel events are re-mapped onto the `Stream<ChatStreamChunk>` shape
//     the existing UI pipeline consumes (`_handleStreamData`): transport
//     chunks pass through untouched (content / reasoning / usage / retry
//     status / toolCalls), synthetic tool-result chunks (kernel
//     `emitCalls`) update tool cards exactly as before, and the run's end
//     becomes a terminal `isDone` chunk.
//
// P0-3: the `agent_loop_v1` kill-switch has been retired and the legacy
// transport tool loops are gone — this driver is the only generation path.
// The transport is now strictly one request per call: it parses the response,
// surfaces tool calls (with the provider's reasoning-echo extras) and returns.
// Every provider was parity-verified before the loops were removed (OpenAI
// chat-completions incl. Responses and the no-DONE fallback, Claude thinking
// echo and pause_turn/server-tool continuation, Gemini thought signatures, and
// Neuralwatt on the OpenAI wire).

import 'dart:async';
import 'dart:convert';

import '../../providers/settings_provider.dart';
import 'agent_loop.dart';
import '../api/chat_api_service.dart';

/// Loop driver: owns the kernel instance, the transport binding and the tool
/// execution adapter. Stateless per run — a fresh [run] call drives a fresh
/// kernel loop.
class AgentOrchestrator {
  /// Drive one agent run and re-emit the kernel's events as the chunk stream
  /// the existing UI / persistence pipeline consumes.
  ///
  /// [messages] are the initial OpenAI-neutral messages. [sendRound] issues
  /// exactly one transport request per call. [onToolCall] executes a single
  /// tool (legacy `(name, args)` contract). [options] / [hooks] are passed
  /// through to the kernel; hooks let callers observe round boundaries (soft
  /// budget, Phase-1 approval pause/resume, compression triggers).
  ///
  /// The stream ends with a terminal `isDone` chunk carrying the run's
  /// cumulative token usage; when the kernel stops early (max steps / budget
  /// / hook veto) the same terminal chunk is emitted so the UI finalizes the
  /// message bubble as it does today.
  Stream<ChatStreamChunk> run({
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    List<String>? userImagePaths,
    int? thinkingBudget,
    double? temperature,
    double? topP,
    int? maxTokens,
    List<Map<String, dynamic>>? tools,
    ToolCallHandler? onToolCall,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
    bool webFetchEnabled = true,
    required bool streamOutput,
    required String requestId,
    String? sessionId,
    String? imageAspectRatio,
    AgentLoopOptions options = const AgentLoopOptions(),
    AgentLoopHooks hooks = const AgentLoopHooks(),
    Future<Stream<ChatStreamChunk>> Function(
      List<Map<String, dynamic>> messages,
    )?
    sendRound,
  }) async* {
    assert(
      onToolCall != null || tools == null || tools.isEmpty,
      'tools require an onToolCall handler: the kernel would otherwise feed '
      'empty tool results back to the model.',
    );
    final toolHandler = onToolCall ?? noopToolHandler;
    final round =
        sendRound ??
        ((msgs) => sendRoundImpl(
          config: config,
          modelId: modelId,
          messages: msgs,
          userImagePaths: userImagePaths,
          thinkingBudget: thinkingBudget,
          temperature: temperature,
          topP: topP,
          maxTokens: maxTokens,
          tools: tools,
          extraHeaders: extraHeaders,
          extraBody: extraBody,
          webFetchEnabled: webFetchEnabled,
          streamOutput: streamOutput,
          requestId: requestId,
          sessionId: sessionId,
          imageAspectRatio: imageAspectRatio,
        ));
    await for (final event in runAgentLoop(
      messages: messages,
      sendRound: round,
      // id-aware contract: the kernel's AgentToolCall carries the provider
      // call id; handlers key per-call side effects off it (approval event
      // ids).
      onToolCall: (call) =>
          toolHandler(call.name, call.arguments, toolCallId: call.toolCallId),
      options: options,
      hooks: hooks,
    )) {
      switch (event) {
        case AgentStreamEvent(:final chunk):
          // Transport chunks (content / reasoning / usage / retry status /
          // toolCalls / synthetic toolResults) pass through untouched.
          yield chunk;
        case AgentToolExecutedEvent():
          // The kernel already re-emits a synthetic toolResults chunk for the
          // UI (options.emitCalls); nothing to do here.
          break;
        case AgentRoundFinishedEvent():
          // Boundary bookkeeping is handled by hooks; nothing to re-emit.
          break;
        case AgentRunFinishedEvent(:final reason, :final tokensUsed):
          if (reason != AgentRunStopReason.finished) {
            // Early stop: the transport never emitted a terminal chunk for
            // the final round, so synthesize one so the UI finalizes the
            // message exactly as on normal completion. `finished` already
            // delivered its own isDone chunk through the transport.
            // P0-5: max-steps / token-budget stops are surfaced to the user
            // via a localized footnote (ADR-A4 soft-gate semantics); hook
            // vetoes (approval pause) carry no reason — the approval card
            // is the user-facing surface for those.
            yield ChatStreamChunk(
              content: '',
              isDone: true,
              totalTokens: tokensUsed,
              softStopReason: switch (reason) {
                AgentRunStopReason.maxStepsReached => 'max_steps',
                AgentRunStopReason.tokenBudgetReached => 'token_budget',
                _ => null,
              },
            );
          }
          return;
      }
    }
  }

  /// Single-round transport binding: one `sendMessageStream` call (tools
  /// surfaced, never executed here).
  Future<Stream<ChatStreamChunk>> sendRoundImpl({
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    List<String>? userImagePaths,
    int? thinkingBudget,
    double? temperature,
    double? topP,
    int? maxTokens,
    List<Map<String, dynamic>>? tools,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
    bool webFetchEnabled = true,
    required bool streamOutput,
    required String requestId,
    String? sessionId,
    String? imageAspectRatio,
  }) async {
    return ChatApiService.sendMessageStream(
      config: config,
      modelId: modelId,
      messages: messages,
      userImagePaths: userImagePaths,
      thinkingBudget: thinkingBudget,
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens,
      tools: tools,
      extraHeaders: extraHeaders,
      extraBody: extraBody,
      webFetchEnabled: webFetchEnabled,
      stream: streamOutput,
      requestId: requestId,
      sessionId: sessionId,
      imageAspectRatio: imageAspectRatio,
    );
  }
}

/// Fallback tool handler used when a caller has no real handler: surfaces a
/// structured error to the model instead of crashing the run.
Future<String> noopToolHandler(
  String name,
  Map<String, dynamic> args, {
  String? toolCallId,
}) async => jsonEncode(<String, dynamic>{
  'type': 'tool_error',
  'error': 'execution_error',
  'message': 'Tool "$name" is not available in this context.',
  'tool': name,
  'instruction':
      'The tool execution failed unexpectedly. You may try again with different parameters or inform the user about the issue.',
});
