// R0 reactive layer — context-overflow classification and trim decision
// (IMPORT_PLAN_COWORK.md P1-2, first batch).
//
// Ported from AnyBuff (sdk/src/error-utils.ts and
// sdk/src/impl/context-overflow-trim.ts). Zero Flutter imports; the only
// seam into the transport layer is [planContextOverflowTrim], called from
// `ChatApiService.sendMessageStream` on a terminal error before the
// existing rethrow.
//
// R0 is failure-path-only: it has no settings toggle by design. The flow is
// `overflow 400 → classify (conservative regex) → learn the provider's real
// window from the error text (smaller plausible side, sanity-checked) →
// mechanically trim the request (tail-keep, system preserved, pairing-safe)
// → retry the SAME model exactly once`. A second failure falls back to the
// existing terminal path.
library;

import 'dart:convert';

import '../agent/compaction/context_trim.dart';

/// Conservative context-overflow markers (AnyBuff P0 A1). Case-insensitive.
/// Rate-limit messages MUST stay out of this list (counter-examples in
/// tests) — only 400s carrying these markers classify as overflow.
final List<RegExp> contextOverflowPatterns = <RegExp>[
  RegExp(r'context_length_exceeded', caseSensitive: false),
  RegExp(r'maximum context length', caseSensitive: false),
  RegExp(r'prompt is too long|input is too long|too many (input )?tokens',
      caseSensitive: false),
  RegExp(r'reduce[^\n]*the length|exceeds (the )?(context|maximum)',
      caseSensitive: false),
];

bool isContextOverflowMessage(String text) {
  if (text.isEmpty) return false;
  for (final pattern in contextOverflowPatterns) {
    if (pattern.hasMatch(text)) return true;
  }
  return false;
}

/// Join the message-bearing fields of an unknown error into one text blob
/// the overflow matcher (and the window parser) can scan.
String overflowErrorText(Object error) {
  final parts = <String>[];
  if (error is Exception) {
    // DioException-style errors carry the response on `.response`; both
    // dio and package:http errors render useful text via toString().
    try {
      final response = (error as dynamic).response;
      if (response != null) {
        final data = response.data;
        if (data is String) {
          parts.add(data);
        } else if (data != null) {
          try {
            parts.add(jsonEncode(data));
          } catch (_) {
            parts.add(data.toString());
          }
        }
      }
    } catch (_) {}
    final message = error.toString();
    if (message.isNotEmpty) parts.add(message);
  } else {
    parts.add(error.toString());
  }
  return parts.where((p) => p.isNotEmpty).join('\n');
}

/// True when the error is an HTTP 400 whose text carries an overflow marker.
/// Overflow is its own failure class: it is not retryable (the same request
/// would fail identically) and only becomes fixable by trimming.
bool isContextOverflowError(Object error, {int? statusCode}) {
  final code = statusCode ?? extractStatusCodeLoose(error);
  if (code != 400) return false;
  return isContextOverflowMessage(overflowErrorText(error));
}

/// Best-effort status-code extraction without importing the retry policy
/// (keeps this module dependency-free).
int? extractStatusCodeLoose(Object error) {
  if (error is Exception) {
    try {
      final response = (error as dynamic).response;
      final code = response?.statusCode;
      if (code is int) return code;
    } catch (_) {}
  }
  final match = RegExp(r'HTTP\s+(\d{3})').firstMatch(error.toString());
  if (match != null) {
    return int.tryParse(match.group(1)!);
  }
  return null;
}

// ============================================================================
// Window learning (AnyBuff P0 A2 step 1)
// ============================================================================

/// Real model windows live in the 4k–32M band; anything outside is noise
/// (timestamps, request ids, pricing figures).
const int learnedWindowMinTokens = 4_000;
const int learnedWindowMaxTokens = 32_000_000;

/// A parsed window can only be trusted up to 20% above the local estimate —
/// tokenizer variance never reaches that high.
const double learnedWindowEstimateTolerance = 1.2;

/// Parse the provider's real context-window token count out of an overflow
/// message. Providers word these wildly differently (`maximum context
/// length is 128000 tokens`, `prompt is too long: 123456 tokens > 100000
/// maximum`, …), so scan for integers near context-related keywords and
/// deliberately take the SMALLER plausible side: the window is the number
/// the request must fit under, and request-token counts (the larger number
/// in "X > Y" phrasings) must never be mistaken for it.
///
/// Returns `null` when nothing in-range can be trusted.
int? parseLearnedContextWindow(String message, int requestLocalTokenEstimate) {
  if (message.isEmpty || requestLocalTokenEstimate <= 0) return null;
  final lower = message.toLowerCase();

  final candidates = <int>[];
  // Numeric runs of at least 4 digits (optionally comma-separated) —
  // shorter numbers are overwhelmingly ids/versions, not token counts.
  final numberPattern = RegExp(r'(\d[\d,]{3,})');
  for (final match in numberPattern.allMatches(lower)) {
    final raw = match.group(1)!.replaceAll(',', '');
    final value = int.tryParse(raw);
    if (value == null) continue;
    // Only trust integers near context-related keywords (±60 chars) — ids,
    // versions and pricing figures must never leak in.
    final start = match.start - 60 < 0 ? 0 : match.start - 60;
    final end = match.end + 60 > lower.length ? lower.length : match.end + 60;
    final context = lower.substring(start, end);
    if (!RegExp(r'(context|maximum|limit|tokens?|length|window)')
        .hasMatch(context)) {
      continue;
    }
    candidates.add(value);
  }

  // Prefer the smaller plausible side per the "X > Y maximum" phrasing.
  final plausible = candidates
      .where((v) =>
          v >= learnedWindowMinTokens &&
          v < learnedWindowMaxTokens &&
          v <= requestLocalTokenEstimate * learnedWindowEstimateTolerance)
      .toList();
  if (plausible.isEmpty) return null;
  return plausible.reduce((a, b) => a < b ? a : b);
}

// ============================================================================
// Trim decision (AnyBuff P0 A2 — decideContextOverflowTrim)
// ============================================================================

/// Smallest target we will ever trim a request down to.
const int minTrimTargetTokens = 4096;

class ContextOverflowTrimPlan {
  /// Trimmed message list to retry the SAME model with, exactly once.
  final List<Map<String, dynamic>> messages;

  /// Trim target that was applied (window − reserve).
  final int targetTokens;

  /// Window the target was derived from (learned or declared).
  final int windowTokens;

  /// Window learned from the error text, when one was parsed.
  final int? learnedWindowTokens;

  const ContextOverflowTrimPlan({
    required this.messages,
    required this.targetTokens,
    required this.windowTokens,
    this.learnedWindowTokens,
  });
}

/// Pure decision: what to do with a request that just failed with a
/// provider error. Returns `null` when the caller should proceed with its
/// normal (terminal) handling — not an overflow 400, already trimmed once,
/// no usable window, or the keep-during-truncation core already fits
/// (irreducible).
///
/// [declaredWindowTokens] is the caller's window resolution
/// (learned-from-settings → seed table → 1M fallback, see
/// [resolveContextWindowTokens]); a window freshly learned from THIS error
/// always wins over it (capped at the declared value when both exist).
ContextOverflowTrimPlan? planContextOverflowTrim({
  required Object error,
  required List<Map<String, dynamic>> messages,
  required bool alreadyTrimmed,
  int? statusCode,
  required int Function(List<Map<String, dynamic>>) estimateTokens,
  required int? declaredWindowTokens,
}) {
  if (alreadyTrimmed) return null;
  if (!isContextOverflowError(error, statusCode: statusCode)) return null;

  final errorText = overflowErrorText(error);
  final estimate = estimateTokens(messages);
  final learned = parseLearnedContextWindow(errorText, estimate);

  int windowTokens;
  if (learned != null) {
    windowTokens = declaredWindowTokens == null
        ? learned
        : (learned < declaredWindowTokens ? learned : declaredWindowTokens);
  } else {
    if (declaredWindowTokens == null) return null;
    windowTokens = declaredWindowTokens;
  }

  final reserve = reserveTokens(windowTokens, null);
  final target =
      minTrimTargetTokens > windowTokens - reserve ? minTrimTargetTokens : windowTokens - reserve;

  final trimmed = trimMessagesToFitTokenLimit(messages, target);
  if (trimmed == null) return null;
  if (estimateTokens(trimmed) >= estimate) return null;

  return ContextOverflowTrimPlan(
    messages: trimmed,
    targetTokens: target,
    windowTokens: windowTokens,
    learnedWindowTokens: learned,
  );
}
