// Claude `/v1/messages` max_tokens negotiation.
//
// Anthropic requires `max_tokens` on every request — unlike the
// OpenAI-compatible endpoints there is no "omit it and let the provider
// decide" mode — so the value we send is the only thing standing between a
// model and its real output capability. The historical hard-coded `4096`
// fallback capped every Claude reply at ~3% of what current models can emit
// (Opus 5.5 / Sonnet 5 / Fable line: 128k output tokens).
//
// Instead of maintaining a model→ceiling table that goes stale on every
// release, we start high and let the server state its own ceiling. A 400
// arrives before a single output byte, with the limit spelled out:
//
//   max_tokens: 64001 > 64000, which is the maximum allowed number of
//   output tokens for claude-opus-4-5-20251101
//
// We parse that number — plus the common third-party wordings (see
// [_ceilingGlyphRes] and [_ceilingGenericRes]) — retry with it, and remember
// it in [LearnedMaxOutputCaps] so the round trip happens once per model.
//
// Two neighbouring facts ride the same negotiation pass:
//   * a `prompt is too long` body states the context window; the window is
//     a model fact and is exposed for the caller to remember
//     ([parseClaudePromptTooLongWindow]), while the per-request slack is
//     not.
//   * `thinking.budget_tokens` must stay strictly below `max_tokens`;
//     after a negotiated down-shift the budget is clamped through
//     [claudeThinkingBudgetForMaxTokens].
//
// Pure Dart (no Flutter imports) so the decision table stays unit-testable.
library;

import 'learned_max_output_caps.dart' show LearnedMaxOutputCaps;

/// First-attempt ceiling when nothing has been learned for this model: the
/// largest output any currently shipped Claude model allows.
const int claudeMaxTokensInitial = 128000;

/// Hard lower bound, used only when the server rejects our value without
/// disclosing its own ceiling. Deliberately *not* the old 4096: modern
/// models accept 12800 trivially, and 4096 is what truncated replies.
const int claudeMaxTokensFloor = 12800;

/// Negotiation attempts allowed per request. Each attempt is a pre-output
/// 400, so the bound is what keeps a hostile/broken endpoint from
/// spinning — after two, the error surfaces to the L1 retry loop as usual.
const int claudeMaxTokensMaxAttempts = 2;

final RegExp _ceilingRe = RegExp(
  r'max_tokens:\s*(\d+)\s*>\s*(\d+)\s*,\s*which is the maximum allowed',
  caseSensitive: false,
);

/// `max_tokens`-anchored wordings third-party gateways use; safe on any
/// body because the captured number can only be a limit on `max_tokens`
/// itself.
final List<RegExp> _ceilingGlyphRes = <RegExp>[
  // "max_tokens must be less than or equal to 8192" /
  // "max_tokens: 128000 must not exceed 8192" / "max_tokens <= 8192".
  RegExp(
    r'max_tokens.{0,60}?(?:less than or equal to|no more than|not exceed|'
    r'cannot exceed|no greater than|at most|<=|≤)\s*[:=]?\s*(\d+)',
    caseSensitive: false,
    dotAll: true,
  ),
  // "the valid range of max_tokens is [1, 8192]".
  RegExp(
    r'max_tokens[^0-9]{0,60}?\[\s*\d+\s*,\s*(\d+)',
    caseSensitive: false,
  ),
];

/// Generic wordings that bound the *output* without naming `max_tokens`.
/// Skipped when the body reads like a window/overflow statement, where
/// "N tokens" is the context window, not an output ceiling.
final List<RegExp> _ceilingGenericRes = <RegExp>[
  // "allows a maximum of 8192 output tokens" / "max 8192 output tokens".
  RegExp(
    r'max(?:imum)?\s+(?:of\s+)?(\d+)\s+output\s+tokens',
    caseSensitive: false,
  ),
  // "you can request at most 8192 output tokens" / "no more than 8192 tokens".
  RegExp(
    r'(?:at most|no more than|up to)\s+(\d+)\s+(?:output\s+)?tokens',
    caseSensitive: false,
  ),
];

final RegExp _promptTooLongRe = RegExp(
  r'prompt is too long:\s*(\d+)\s*tokens\s*>\s*(\d+)\s*maximum',
  caseSensitive: false,
);

/// The ceiling the API stated for this model, parsed out of a 400 body, or
/// `null` when the message does not disclose one.
int? parseClaudeOutputCeiling(String errorBody) {
  final match = _ceilingRe.firstMatch(errorBody);
  if (match != null) {
    final limit = int.tryParse(match.group(2) ?? '');
    if (limit != null && limit > 0) return limit;
  }
  for (final re in _ceilingGlyphRes) {
    final glyph = re.firstMatch(errorBody);
    final limit = glyph == null ? null : int.tryParse(glyph.group(1) ?? '');
    if (limit != null && limit > 0) return limit;
  }
  // A window/overflow statement ("prompt is too long …") may also contain
  // "at most N tokens" wording — that N is the context window, not an
  // output ceiling — so the generic patterns are skipped there.
  final lower = errorBody.toLowerCase();
  final looksLikeOverflow = lower.contains('prompt is too long') ||
      lower.contains('input is too long') ||
      lower.contains('too many input tokens');
  if (!looksLikeOverflow) {
    for (final re in _ceilingGenericRes) {
      final generic = re.firstMatch(errorBody);
      final limit = generic == null
          ? null
          : int.tryParse(generic.group(1) ?? '');
      if (limit != null && limit > 0) return limit;
    }
  }
  return null;
}

/// The context window the API stated in a `prompt is too long` 400, or
/// `null`. The window is a model fact; the per-request slack
/// (`window - used`) is not, and callers must never cache it.
int? parseClaudePromptTooLongWindow(String errorBody) {
  final match = _promptTooLongRe.firstMatch(errorBody);
  if (match == null) return null;
  final window = int.tryParse(match.group(2) ?? '');
  if (window == null || window <= 0) return null;
  return window;
}

/// Decide the `max_tokens` to send after [errorBody] came back as HTTP 400.
///
/// Returns `null` when the error is unrelated, when the caller pinned the
/// value through `customBody`/`maxTokens`, or when [attempts] is exhausted —
/// in every one of those cases the caller rethrows and nothing is retried.
///
/// [current] must be the value actually sent (post-override).
int? claudeMaxTokensNextOn400({
  required String errorBody,
  required int current,
  required int attempts,
  bool pinned = false,
}) {
  if (pinned || attempts >= claudeMaxTokensMaxAttempts) return null;

  // The server named its ceiling — the most trustworthy answer there is.
  final ceiling = parseClaudeOutputCeiling(errorBody);
  if (ceiling != null) {
    // Use it verbatim: it may sit below the floor on long-deprecated models,
    // but a request that succeeds beats one that cannot. Equal means we
    // already sent it, so there is nothing left to try.
    return ceiling == current ? null : ceiling;
  }

  // Models predating 4.5 validate `input + max_tokens` against the window
  // ("prompt is too long"). Only the leftover room is ours to request, and
  // the room left depends on this request's input, so it is never cached.
  final slack = _promptTooLongSlack(errorBody);
  if (slack != null) {
    if (slack < claudeMaxTokensFloor || slack >= current) return null;
    return slack;
  }

  // A max_tokens-flavoured rejection we cannot read (third-party gateway
  // wording). Drop to the floor once and let the endpoint prove itself.
  final lower = errorBody.toLowerCase();
  if ((lower.contains('max_tokens') || lower.contains('prompt is too long')) &&
      current > claudeMaxTokensFloor) {
    return claudeMaxTokensFloor;
  }
  return null;
}

int? _promptTooLongSlack(String errorBody) {
  final match = _promptTooLongRe.firstMatch(errorBody);
  if (match == null) return null;
  final used = int.tryParse(match.group(1) ?? '');
  final window = int.tryParse(match.group(2) ?? '');
  if (used == null || window == null) return null;
  return window - used;
}

/// Largest `thinking.budget_tokens` a request carrying [maxTokens] can use:
/// Anthropic requires the budget to stay strictly below `max_tokens`.
///
/// Returns [budget] unchanged when it is null (auto) or non-positive
/// (disabled), when it already fits, or when [maxTokens] is too small for
/// the API's 1024-token minimum budget (then no value satisfies both
/// constraints and the server's own error is the honest outcome).
int? claudeThinkingBudgetForMaxTokens(int? budget, int maxTokens) {
  if (budget == null || budget <= 0) return budget;
  if (maxTokens > budget) return budget;
  final shrunk = maxTokens - 1;
  if (shrunk < 1024) return budget;
  return shrunk;
}

/// Remember a ceiling the server stated for [providerId]/[modelId] — the
/// logical model id, the same key convention as LearnedContextWindows.
///
/// Kept next to the parser (rather than in the service) so every caller of
/// [claudeMaxTokensNextOn400] records the same way. Never throws.
Future<void> rememberClaudeOutputCeiling(
  String providerId,
  String modelId,
  String errorBody,
) async {
  final ceiling = parseClaudeOutputCeiling(errorBody);
  if (ceiling == null) return;
  await LearnedMaxOutputCaps.record(providerId, modelId, ceiling);
}
