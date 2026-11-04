/// OpenCode inference error classification.
///
/// The gateway returns structured error codes in the HTTP body; the transport
/// surfaces them as `HTTP 400: {...}` strings. These helpers turn the common
/// cases into actionable, localized notices without hiding the original error
/// from the debug log.
enum OpenCodeErrorKind {
  missingSession,
  freeTier,
  insufficientBalance,
  protocolUnsupported,
  none,
}

OpenCodeErrorKind classifyOpenCodeError(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('missingsessionid') ||
      text.contains('x-opencode-session')) {
    return OpenCodeErrorKind.missingSession;
  }
  if (text.contains('freetiererror') ||
      text.contains('free tier') ||
      text.contains('free-tier')) {
    return OpenCodeErrorKind.freeTier;
  }
  if (text.contains('insufficient') ||
      text.contains('"status":402') ||
      text.contains('http 402') ||
      text.contains('payment required')) {
    return OpenCodeErrorKind.insufficientBalance;
  }
  if (text.contains('modelprotocolunsupported')) {
    return OpenCodeErrorKind.protocolUnsupported;
  }
  return OpenCodeErrorKind.none;
}
