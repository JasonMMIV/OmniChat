package com.psyche.omnichat.sandbox

import android.content.Context
import java.io.File

/**
 * On-disk layout for the Android PRoot sandbox (P2-5).
 *
 * Everything lives under `{appData}/cli_runtime/` — the same contract the plan
 * documents for the desktop CLI runtime. The rootfs is the only large payload;
 * it is installed from a pinned APK asset and never written into a workspace.
 */
class SandboxPaths(context: Context) {

    private val filesDir = context.filesDir

    /** Runtime root (`{appData}/cli_runtime/`). */
    val runtimeDir = File(filesDir, "cli_runtime")

    /** Active, patched Ubuntu rootfs. */
    val rootfs = File(runtimeDir, "rootfs")

    /** Extraction staging; renamed into [rootfs] only after validation. */
    val rootfsStaging = File(runtimeDir, "rootfs.staging")

    /** Previous rootfs kept until an atomic swap succeeds. */
    val rootfsOld = File(runtimeDir, "rootfs.old")

    /** PRoot temp dir (`PROOT_TMP_DIR` / guest `/tmp` is inside the rootfs). */
    val tmp = File(runtimeDir, "tmp")

    /** Downloaded/copied archive staging. */
    val cache = File(runtimeDir, "cache")

    /** Install lock directory. */
    val locks = File(runtimeDir, "locks")

    /** Runtime shared libraries (`libtalloc.so.2`). */
    val libs = File(runtimeDir, "libs")

    /** Pre-generated `/proc` fakes (stat/loadavg/version/vmstat). */
    val procFakes = File(runtimeDir, "proc-fakes")

    /** Install metadata (rootfs version + SHA-256 + installedAt). */
    val metadata = File(runtimeDir, "metadata.json")

    /** Single-writer install lock (best effort; the native layer is also synchronized). */
    val installLock = File(locks, "install.lock")

    fun ensureDirs() {
        listOf(runtimeDir, tmp, cache, locks, libs, procFakes).forEach { it.mkdirs() }
    }
}
