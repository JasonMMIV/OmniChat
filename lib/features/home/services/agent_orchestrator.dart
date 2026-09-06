// Agent-loop driver (IMPORT_PLAN_COWORK.md P0-2).
//
// The connection layer between the pure kernel
// (`lib/core/services/agent/agent_loop.dart`) and the existing transport +
// UI pipeline:
//
//   - `sendRound` is a single-round `ChatApiService.sendMessageStream` call
//     with `exposeToolCallsOnly: true` — one transport request per kernel
//     round, tools surfaced but NOT executed by the transport.
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
// Kill-switch: `SettingsProvider.agentLoopV1` (default `true`). During the
// strangler migration both paths coexist; the legacy transport loop is
// removed after one soak release (IMPORT_PLAN_COWORK.md P0-3 後段). Callers
// that have not been parity-verified against the kernel path (per-provider
// reasoning-echo / Responses continuation) fall back to the legacy loop via
// [AgentOrchestrator.supportsKernelPath].

import 'dart:async';
import 'dart:convert';

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/agent/agent_loop.dart';
import '../../../core/services/api/chat_api_service.dart';

/// Loop driver: owns the kernel instance, the transport binding and the tool
/// execution adapter. Stateless per run — a fresh [run] call drives a fresh
/// kernel loop.
class AgentOrchestrator {
  /// Whether the kernel path is safe for this provider *today*.
  ///
  /// Phase-0 parity coverage (P0-2/P0-3): OpenAI chat-completions
  /// (non-stream + SSE stream + no-DONE vendor fallback), the Responses API
  /// (`output_item` continuation replay), Claude (non-stream + streaming,
  /// thinking-block echo) and Gemini (non-stream + streaming,
  /// thought-signature echo) are byte-verified against the legacy loop
  /// (`agent_loop_provider_parity_test.dart`).
  ///
  /// Still excluded: Neuralwatt (classified as OpenAI-compatible by the
  /// transport, but its tool-loop shape has not been parity-verified). It
  /// keeps the legacy transport loop regardless of the `agent_loop_v1`
  /// kill-switch.
  static bool supportsKernelPath(ProviderConfig config) {
    final kind = config.providerType;
    return kind == ProviderKind.openai ||
        kind == ProviderKind.claude ||
        kind == ProviderKind.google;
  }

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
    Future<String> Function(String name, Map<String, dynamic> args)? onToolCall,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
    required bool streamOutput,
    required String requestId,
    String? imageAspectRatio,
    AgentLoopOptions options = const AgentLoopOptions(),
    AgentLoopHooks hooks = const AgentLoopHooks(),
    Future<Stream<ChatStreamChunk>> Function(
      List<Map<String, dynamic>> messages,
    )?
    sendRound,
  }) async* {
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
          streamOutput: streamOutput,
          requestId: requestId,
          imageAspectRatio: imageAspectRatio,
        ));
    await for (final event in runAgentLoop(
      messages: messages,
      sendRound: round,
      onToolCall: (call) => toolHandler(call.name, call.arguments),
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
            yield ChatStreamChunk(
              content: '',
              isDone: true,
              totalTokens: tokensUsed,
            );
          }
          return;
      }
    }
  }

  /// Single-round transport binding: one `sendMessageStream` call with
  /// `exposeToolCallsOnly: true` (tools surfaced, never executed here).
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
    required bool streamOutput,
    required String requestId,
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
      onToolCall: null, // The kernel executes tools, not the transport.
      exposeToolCallsOnly: true,
      extraHeaders: extraHeaders,
      extraBody: extraBody,
      stream: streamOutput,
      requestId: requestId,
      imageAspectRatio: imageAspectRatio,
    );
  }
}

/// Fallback tool handler used when a caller has no real handler: surfaces a
/// structured error to the model instead of crashing the run.
Future<String> noopToolHandler(
  String name,
  Map<String, dynamic> args,
) async => jsonEncode(<String, dynamic>{
  'type': 'tool_error',
  'error': 'execution_error',
  'message': 'Tool "$name" is not available in this context.',
  'tool': name,
  'instruction':
      'The tool execution failed unexpectedly. You may try again with different parameters or inform the user about the issue.',
});
