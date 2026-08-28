/// Structured error raised by `ChatApiService.sendMessageStream` after the
/// L1 retry loop has either detected a silent stream interruption or
/// exhausted its retry budget.
///
/// The class is used to bridge two distinct conditions to the chat-action
/// layer:
/// - `silent_interrupt`: the SSE body ended without a `[DONE]` (or
///   equivalent) marker. The retry loop will keep attempting the same
///   model unless the user cancels.
/// - `retries_exhausted`: the retry budget is spent; the chat-action layer
///   should preserve the partial content and surface the failure to the UI.
///
/// OmniChat does NOT adopt L2 failover — there is no "next model" to switch
/// to. Once `retries_exhausted` fires, the original error message bubbles
/// up unchanged.
class TransientStreamError implements Exception {
  /// One of:
  /// - `'silent_interrupt'` — the SSE body closed prematurely without
  ///   a recognised finish marker. The retry loop will keep trying
  ///   the same model until either it succeeds, the user cancels, or
  ///   the retry budget is spent.
  /// - `'retries_exhausted'` — the retry budget has been spent without a
  ///   successful response. The chat-action layer should preserve the
  ///   partial content (if any) and surface the error to the UI.
  final String errorKind;

  /// Number of attempts already made (1-based). Always >= 1.
  final int attempts;

  /// The underlying error message, either the original exception's
  /// `toString()` or, for `silent_interrupt`, a human-readable
  /// description of the recovery source.
  final String originalMessage;

  /// The provider's reported `finish_reason`, when one was captured
  /// before the stream ended. Only populated for `silent_interrupt`.
  final String? finishReason;

  TransientStreamError({
    required this.errorKind,
    required this.attempts,
    required this.originalMessage,
    this.finishReason,
  });

  /// True when the L1 retry loop has exhausted its budget and is
  /// surfacing the final failure to the chat-action layer. The chat
  /// layer uses this flag to decide between "preserve partial content
  /// with a note" and the legacy "overwrite with raw error text"
  /// behaviour.
  bool get isRetriesExhausted => errorKind == 'retries_exhausted';

  /// True when the failure is a detected silent stream interruption
  /// (SSE body closed without a finish marker) rather than a thrown
  /// exception.
  bool get isSilentInterrupt => errorKind == 'silent_interrupt';

  @override
  String toString() =>
      'TransientStreamError(kind=$errorKind, attempts=$attempts): $originalMessage';
}
