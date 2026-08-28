import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import 'transient_stream_error.dart';

/// L1 stream retry policy — ported from AnyBuff (sdk/src/retry-config.ts,
/// sdk/src/error-utils.ts, common/src/util/error.ts).
///
/// L1 retries apply to a single LLM HTTP call (or stream). The retry loop
/// in `ChatApiService.sendMessageStream` reissues the same request on any
/// transient failure; the yielded-flag tracking on
/// [StreamAttemptFlags] only feeds [classifyStreamEndRecovery] so a clean
/// finish after visible output is not mistaken for a silent interruption.
///
/// OmniChat does NOT adopt L2 failover (no backup model switch) or L3 whole-run
/// resume. See docs/STREAM_RETRY_RECOVERY.md for the full design.
class StreamRetryConfig {
  /// Maximum number of retry attempts PER MESSAGE after the initial attempt.
  /// With the value 3, the call may be issued up to 4 times in total
  /// (1 initial + 3 retries). Mirrors AnyBuff `MAX_RETRIES_PER_MESSAGE`.
  static const int maxRetriesPerMessage = 3;

  /// Base delay in milliseconds for the exponential backoff. Mirrors
  /// AnyBuff `RETRY_BACKOFF_BASE_DELAY_MS`.
  static const int backoffBaseMs = 1000;

  /// Cap for the backoff delay. Mirrors AnyBuff `RETRY_BACKOFF_MAX_DELAY_MS`.
  static const int backoffMaxMs = 8000;

  /// Jitter applied to the computed delay (±this fraction). Mirrors
  /// AnyBuff `RETRY_BACKOFF_JITTER_FRACTION`.
  static const double jitterFraction = 0.2;

  /// Compute the delay in milliseconds for the given retry [attempt]
  /// (0-based; attempt=0 is the first retry, i.e. ~1 s).
  ///
  /// Formula: `round(min(baseMs * 2^attempt, maxMs) * (lo + rand * span))`
  /// where `lo = 1 - jitterFraction`, `span = 2 * jitterFraction`. Pass
  /// `jitter: false` only for tests that need deterministic timing.
  static int computeBackoffDelayMs(int attempt, {bool jitter = true}) {
    final clamped = attempt < 0 ? 0 : attempt;
    final base = math.min(
      backoffBaseMs * math.pow(2, clamped).toInt(),
      backoffMaxMs,
    );
    if (!jitter) return base;
    final lo = 1 - jitterFraction;
    final span = 2 * jitterFraction;
    return (base * (lo + math.Random().nextDouble() * span)).round();
  }
}

/// HTTP status codes eligible for L1 retry. Mirrors AnyBuff
/// `RETRYABLE_STATUS_CODES` — excludes 400, 401, 403, 404 (all terminal
/// in OmniChat since we have no failover path) and includes 408/429/5xx.
const Set<int> kRetryableStatusCodes = {408, 429, 500, 502, 503, 504};

/// Decision returned by [classify]. Drives the retry loop in
/// `ChatApiService.sendMessageStream`.
enum RetryDecision {
  /// Network-level (ECONNRESET etc.) or HTTP 408/429/5xx. Caller may retry
  /// the same model after a backoff sleep.
  retryableTransient,

  /// 4xx other than 408/429, auth errors, content-policy rejections, parse
  /// errors, or anything we don't recognise. Caller should surface the
  /// error to the UI immediately.
  terminal,
}

/// Returns `true` if [error] looks like a transient connection-level failure
/// (no HTTP response received). Ported from AnyBuff
/// `isTransientNetworkError` with Dart-idiomatic exception-type matching.
///
/// NOTE: A [http.ClientException] is treated as transient only when it
/// does NOT carry a recoverable HTTP status code. When the message
/// contains `HTTP <code>`, the classifier routes the error through
/// [isRetryableStatusCode] (5xx → retry, 4xx → terminal) instead — the
/// status code is more informative than the catch-all "connection
/// error" semantics of [http.ClientException].
bool isTransientNetworkError(Object error) {
  if (error is SocketException) return true;
  if (error is HandshakeException) return true;
  if (error is http.ClientException) {
    // If a status code can be parsed from the wrapped message, defer
    // to the status-code classifier so 4xx errors stay terminal.
    if (extractStatusCode(error) != null) return false;
    return true;
  }
  if (error is HttpException) {
    // dio wraps some socket-level errors as HttpException; fall back to a
    // substring check on the message.
    final msg = error.message.toLowerCase();
    if (_transientMessagePatterns.any(msg.contains)) return true;
    return false;
  }
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return true;
      case DioExceptionType.unknown:
        // Some runtimes (notably Bun on certain Linux configs) surface
        // a severed response body as `DioExceptionType.unknown` with a
        // ECONNRESET-like message. Substring sniff as a safety net.
        final msg = (error.message ?? '').toLowerCase();
        if (_transientMessagePatterns.any(msg.contains)) return true;
        return false;
      case DioExceptionType.badResponse:
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
        return false;
    }
  }
  return false;
}

/// Best-effort status-code extraction. Returns `null` for non-HTTP errors
/// or when the status code cannot be located.
int? extractStatusCode(Object error) {
  if (error is DioException && error.response != null) {
    return error.response!.statusCode;
  }
  if (error is http.ClientException) {
    // DioHttpClient wraps the underlying error (often a [HttpException]
    // or a [DioException]) in a [http.ClientException] whose [message]
    // is `e.toString()` of the original. The [HttpException] toString
    // is `'HttpException: HTTP 500: …'`, so a regex can recover the
    // status code. Without this recovery the L1 retry loop would treat
    // every 4xx/5xx as a terminal error and never retry.
    final match = RegExp(r'HTTP\s+(\d{3})').firstMatch(error.message);
    if (match != null) return int.parse(match.group(1)!);
    return null;
  }
  if (error is HttpException) {
    final match = RegExp(r'HTTP\s+(\d{3})').firstMatch(error.message);
    return match != null ? int.parse(match.group(1)!) : null;
  }
  return null;
}

bool isRetryableStatusCode(int? code) =>
    code != null && kRetryableStatusCodes.contains(code);

/// Final classifier used by the retry loop. Returns the decision in one
/// place so the loop body stays short.
RetryDecision classify(Object error) {
  // A [TransientStreamError] wrapping a `silent_interrupt` is by
  // definition transient — the parser detected a clean-but-incomplete
  // stream, not a 4xx error. `isTransientNetworkError` /
  // `extractStatusCode` cannot infer this from the wrapper alone, so
  // route it through the transient path explicitly. A
  // `retries_exhausted` wrapper, on the other hand, is the final
  // terminal signal from the retry loop itself — it must not be
  // reclassified as transient or the loop would never terminate.
  if (error is TransientStreamError) {
    return error.isSilentInterrupt
        ? RetryDecision.retryableTransient
        : RetryDecision.terminal;
  }
  if (isRetryableStatusCode(extractStatusCode(error))) {
    return RetryDecision.retryableTransient;
  }
  if (isTransientNetworkError(error)) {
    return RetryDecision.retryableTransient;
  }
  return RetryDecision.terminal;
}

const _transientMessagePatterns = [
  'socket connection was closed unexpectedly',
  'fetch failed',
  'failed to fetch',
  'network connection was lost',
  'connection reset',
  'connection reset by peer',
  'connection refused',
  'connection closed',
  'broken pipe',
];
