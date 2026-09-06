import '../../models/token_usage.dart';

/// A single unit of streamed output emitted by [ChatApiService.sendMessageStream].
///
/// Kept in its own pure-Dart file (no Flutter imports) so the agent-loop
/// kernel (`lib/core/services/agent/agent_loop.dart`) can consume the
/// transport's chunks without dragging in the Flutter dependency of
/// `chat_api_service.dart`.
class ChatStreamChunk {
  final String content;
  // Optional reasoning delta (when model supports reasoning)
  final String? reasoning;
  final bool isDone;
  final int totalTokens;
  final TokenUsage? usage;
  final List<ToolCallInfo>? toolCalls;
  final List<ToolResultInfo>? toolResults;

  // --- L1 retry / silent-interrupt recovery metadata ---
  // These three fields are populated by [ChatApiService.sendMessageStream]
  // when it is about to reissue the same request after a transient or silent
  // failure. Downstream consumers ([chat_actions] and [chat_turn_service])
  // route them to a UI hook so the user sees "正在重試 1/3…" snackbars.
  final String?
  errorKind; // null | 'transient_retry' | 'silent_interrupt_retry'
  final int? attempt; // 1-based upcoming attempt number
  final int? maxAttempts; // total attempts allowed (1 + retries)
  final int? nextRetryInMs; // ms to sleep before the next attempt

  // --- Provider finish metadata ---
  // Captured at the parser level so the L1 retry loop can detect silent
  // interruptions (SSE body that closes without [DONE] / `message_stop` /
  // explicit Gemini `finishReason`). See `stream_interruption.dart`.
  final String? finishReason;
  final bool hasUsage;

  // --- Agent-loop kernel contract ---
  // Populated ONLY in expose mode (`exposeToolCallsOnly: true`) by the
  // transport, which owns the provider-specific reasoning-echo policy
  // (e.g. DeepSeek-family `reasoning_content`, OpenRouter
  // `reasoning_details`). The kernel forwards these verbatim onto the
  // follow-up assistant `tool_calls` message so multi-round tool calling
  // stays byte-identical to the legacy loop. UI consumers ignore this field.
  final Map<String, dynamic>? assistantExtras;

  ChatStreamChunk({
    required this.content,
    this.reasoning,
    required this.isDone,
    required this.totalTokens,
    this.usage,
    this.toolCalls,
    this.toolResults,
    this.errorKind,
    this.attempt,
    this.maxAttempts,
    this.nextRetryInMs,
    this.finishReason,
    this.hasUsage = false,
    this.assistantExtras,
  });
}

/// A tool call the model asked to run, surfaced in [ChatStreamChunk.toolCalls].
class ToolCallInfo {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  ToolCallInfo({required this.id, required this.name, required this.arguments});
}

/// The completed result of a tool call, surfaced in
/// [ChatStreamChunk.toolResults] so UI / persistence layers can update the
/// tool card for that call.
class ToolResultInfo {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  final String content;
  ToolResultInfo({
    required this.id,
    required this.name,
    required this.arguments,
    required this.content,
  });
}
