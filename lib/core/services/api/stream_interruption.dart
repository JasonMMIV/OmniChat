/// Stream-interruption detection — ported from AnyBuff
/// (sdk/src/impl/stream-interruption.ts).
///
/// Two failure modes are tricky to detect because they don't raise an
/// exception:
///
/// 1. **Silent interruption** — the SSE body simply ends. A healthy
///    OpenAI/Google stream always sends a `finish_reason` (and, on most
///    providers, a `usage` block) before `[DONE]`. When the connection
///    dies mid-stream — a server deploy killing the instance, a proxy
///    timeout, a half-open TCP connection — the body just ends. The parser
///    falls out of the `await for` loop without throwing. If we treated
///    that as a normal completion the user would see the agent "stop
///    randomly" with no error anywhere.
///
/// 2. **Reasoning-only / output-limit stops** — the model spent its
///    `max_tokens` budget entirely on reasoning, or ended after reasoning
///    without producing any visible answer. Both look like a normal
///    completion to a naive parser and would silently end the turn with
///    nothing visible.
///
/// `classifyStreamEndRecovery` inspects the metadata captured during the
/// stream (`finishReason`, `hasUsage`, what was actually yielded) and
/// returns a [StreamRecovery] hint when the stream did not end "normally"
/// in the user-visible sense.
///
/// In OmniChat, the recovery hint is *not* (yet) fed back into the LLM as
/// a follow-up user message — the L1 retry loop in `sendMessageStream`
/// reissues the same request and the partial content is preserved on the
/// message bubble. The hint exists so the parser can throw a
/// [TransientStreamError] with the right `errorKind`.
class StreamRecovery {
  /// `'stream-interrupted' | 'output-limit' | 'reasoning-only'`
  final String source;

  /// Human-readable description. In the AnyBuff upstream this message is
  /// injected into the next agent step as a user-role message. In
  /// OmniChat it is currently only logged and used to disambiguate the
  /// UI copy.
  final String message;

  const StreamRecovery({required this.source, required this.message});
}

/// Recovery hint for an SSE body that ended without a recognised finish
/// marker. Equivalent to AnyBuff's `STREAM_INTERRUPTED_RECOVERY`.
const StreamRecovery streamInterruptedRecovery = StreamRecovery(
  source: 'stream-interrupted',
  message: 'The connection dropped while the response was streaming, '
      'so the output above may be cut off mid-thought.',
);

/// Recovery hint for a `length` finish that produced no visible output
/// (the model spent its output budget on reasoning). Equivalent to AnyBuff's
/// `OUTPUT_LIMIT_RECOVERY`.
const StreamRecovery outputLimitRecovery = StreamRecovery(
  source: 'output-limit',
  message: 'The response hit its output token limit while still reasoning, '
      'so no answer was produced.',
);

/// Recovery hint for a stream that ended after reasoning but without
/// producing any visible answer or tool call. Equivalent to AnyBuff's
/// `REASONING_ONLY_RECOVERY`.
const StreamRecovery reasoningOnlyRecovery = StreamRecovery(
  source: 'output-limit',
  message: 'The response ended after reasoning without producing an answer '
      'or tool call.',
);

/// Inspect the metadata captured during a stream and return a recovery hint
/// when the stream did not end "normally" in the user-visible sense.
///
/// Returns `null` for normal completions. A user-cancel (`aborted: true`)
/// also returns `null` — user cancels are not a recovery, they are
/// intentional and handled by the cancel path.
///
/// This is a pure function with no side effects; it does not throw.
StreamRecovery? classifyStreamEndRecovery({
  required bool aborted,
  required String? finishReason,
  required bool hasUsage,
  required bool receivedReasoning,
  required bool yieldedText,
  required bool yieldedToolCall,
}) {
  if (aborted) return null;

  // Normalise the finish reason so providers that report upper-case
  // values (Gemini: `STOP` / `MAX_TOKENS` / `SAFETY`, OpenAI-compatible
  // hosts, etc.) are classified identically to their lower-case forms.
  final normalized = finishReason?.toLowerCase();

  // Silent interruption: no finish part arrived at all, or `finish_reason`
  // was the uninformative `'unknown'` and no usage block was delivered.
  // AnyBuff notes: "unknown" alone is not proof, because providers also
  // map any unrecognised finish_reason to "unknown". The disambiguator is
  // `hasUsage` — usage always arrives in the final chunk, so an "unknown"
  // finish_reason with no usage means the tail was never received.
  final interrupted =
      normalized == null || (normalized == 'unknown' && !hasUsage);
  if (interrupted) return streamInterruptedRecovery;

  // If the user has already seen any text or a tool call, the stream
  // completed visibly. A subsequent `length` stop is "the answer ran
  // long", not a silent stop — retrying would duplicate what was already
  // shown. Treat as a normal completion.
  if (yieldedText || yieldedToolCall) return null;

  // Output-budget exhausted with no visible output: OpenAI-compatible
  // hosts report `length`, Gemini reports `MAX_TOKENS`. Both mean the
  // model spent its budget (often on reasoning) — the response is
  // complete and billed, so it must NOT be treated as a retryable
  // interruption.
  if (normalized == 'length' || normalized == 'max_tokens') {
    return outputLimitRecovery;
  }

  // Whatever finish reason the provider reported (`stop`, anything else
  // we don't recognise): if reasoning was produced but no visible answer
  // followed, the user would otherwise see "the agent randomly stopped".
  if (receivedReasoning) return reasoningOnlyRecovery;

  return null;
}
