// Ported from Chevey339/kelivo@05eef503b6e7cda14de897373b79bab7bebe35b9
// (`android/app/src/main/kotlin/com/psyche/kelivo/OAuthCallbackActivity.kt`,
// AGPL-3.0), modified for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.

package com.psyche.omnichat

import android.app.Activity
import android.content.Intent
import android.os.Bundle

class OAuthCallbackActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleCallback(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleCallback(intent)
    }

    private fun handleCallback(intent: Intent?) {
        val delivered = intent?.data?.let(OAuthHandler::handleCallback) == true
        if (delivered) {
            // Let Android resolve the existing singleTask activity. AppTask's
            // explicit task insertion rejects a singleTask target and crashes.
            startActivity(
                Intent(this, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                },
            )
        }
        finish()
    }
}
