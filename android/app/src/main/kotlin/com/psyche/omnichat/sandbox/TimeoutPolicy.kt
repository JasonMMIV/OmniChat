package com.psyche.omnichat.sandbox

/**
 * Timeout contract shared by the Dart backend and the native runner.
 *
 * The channel carries milliseconds. A negative value means "no wall-clock
 * deadline"; zero or any other non-positive value falls back to the default;
 * finite values are clamped to [MAX_TIMEOUT_MS].
 */
internal const val DEFAULT_TIMEOUT_MS = 30_000L
internal const val MAX_TIMEOUT_MS = 600_000L
internal const val NO_TIMEOUT_MS = -1L

internal fun normalizeTimeoutMs(requestedMs: Long): Long = when {
    requestedMs < 0L -> NO_TIMEOUT_MS
    requestedMs == 0L -> DEFAULT_TIMEOUT_MS
    else -> requestedMs.coerceIn(1_000L, MAX_TIMEOUT_MS)
}
