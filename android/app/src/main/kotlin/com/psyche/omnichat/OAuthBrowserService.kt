// Ported from Chevey339/kelivo@05eef503b6e7cda14de897373b79bab7bebe35b9
// (`android/app/src/main/kotlin/com/psyche/kelivo/OAuthBrowserService.kt`,
// AGPL-3.0), modified for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.

package com.psyche.omnichat

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder

/** A browser-only lifecycle binding; this binder exposes no app data or operations. */
class OAuthBrowserService : Service() {
    private val binder = Binder()

    override fun onBind(intent: Intent?): IBinder = binder
}
