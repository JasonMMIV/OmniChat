package com.psyche.omnichat.sandbox

import org.junit.Assert.assertEquals
import org.junit.Test

class TimeoutPolicyTest {

    @Test
    fun `negative timeout means unlimited`() {
        assertEquals(NO_TIMEOUT_MS, normalizeTimeoutMs(-1L))
        assertEquals(NO_TIMEOUT_MS, normalizeTimeoutMs(-1_000L))
    }

    @Test
    fun `zero uses the default`() {
        assertEquals(DEFAULT_TIMEOUT_MS, normalizeTimeoutMs(0L))
    }

    @Test
    fun `finite values clamp to the product range`() {
        assertEquals(1_000L, normalizeTimeoutMs(1L))
        assertEquals(120_000L, normalizeTimeoutMs(120_000L))
        assertEquals(MAX_TIMEOUT_MS, normalizeTimeoutMs(999_999L))
    }
}
