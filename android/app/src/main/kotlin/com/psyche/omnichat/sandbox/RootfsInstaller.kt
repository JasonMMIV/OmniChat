package com.psyche.omnichat.sandbox

import android.content.Context
import android.os.StatFs
import android.system.Os
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Rootfs installer for the Android PRoot sandbox (P2-5 §2.8 item 5).
 *
 * The pinned Ubuntu base tarball ships inside the APK (`assets/sandbox/`), so
 * first boot is offline-capable and immune to upstream URL rot. Installation is
 * five-stage (download/verify → stage → validate → activate → cleanup):
 *
 * 1. stream the asset out of the APK while hashing it;
 * 2. extract into `rootfs.staging` with [SafeTarExtractor];
 * 3. patch DNS/hosts/tmp and verify `/bin/sh`;
 * 4. rename staging → live, keeping the previous tree until the rename wins;
 * 5. delete the archive, staging leftovers and rootfs `/tmp`.
 *
 * A marker file (`metadata.json`) records the exact SHA-256 + version that is
 * active, so an app update with the same payload reuses the installed tree and
 * a changed payload re-installs it.
 */
class RootfsInstaller(
    private val context: Context,
    private val paths: SandboxPaths,
) {

    interface Progress {
        fun onStage(stage: String)
        fun onProgress(percent: Int)
    }

    companion object {
        private const val TAG = "OmniChatRootfs"
        private const val ASSET_SANDBOX = "sandbox"
        private const val ASSET_MANIFEST = "$ASSET_SANDBOX/manifest.json"
        private const val BUF = 256 * 1024

        /**
         * Headroom above the uncompressed payload before we refuse to install.
         * Covers filesystem slack; a mid-extract ENOSPC would strand a
         * half-written staging dir behind an opaque failure.
         */
        private const val SPACE_MARGIN = 50L * 1024 * 1024
    }

    data class RuntimeAsset(
        val file: String,
        val sha256: String,
        val version: String,
        val uncompressedBytes: Long,
    )

    data class InstalledRootfs(
        val version: String,
        val sha256: String,
        val installedAt: String?,
        val bytes: Long,
    )

    private val installMutex = Any()

    private fun manifest(): RuntimeAsset {
        val raw = context.assets.open(ASSET_MANIFEST).bufferedReader().use { it.readText() }
        val rootfs = JSONObject(raw).getJSONObject("rootfs")
        return RuntimeAsset(
            file = rootfs.getString("file"),
            sha256 = rootfs.getString("sha256"),
            version = rootfs.getString("version"),
            uncompressedBytes = rootfs.optLong("uncompressedBytes", 0L),
        )
    }

    /** Active rootfs metadata, or null when no matching install is present. */
    fun installed(): InstalledRootfs? {
        val asset = try {
            manifest()
        } catch (_: Exception) {
            return null
        }
        if (!paths.rootfs.isDirectory) return null
        val shell = File(paths.rootfs, "bin/sh")
        if (!shell.isFile || !shell.canExecute()) return null

        val obj = try {
            if (paths.metadata.isFile) JSONObject(paths.metadata.readText()) else null
        } catch (_: Exception) {
            null
        }
        // The metadata file is written after activation. A crash in that tiny
        // window leaves a perfectly usable rootfs; the in-rootfs marker lets
        // the next probe adopt it instead of forcing a full re-extract.
        val inRootfsSha = try {
            File(paths.rootfs, "etc/omnichat-rootfs")
                .readLines()
                .firstOrNull()
                ?.trim()
        } catch (_: Exception) {
            null
        }
        val metadataSha = obj?.optString("sha256")?.takeIf { it == asset.sha256 }
        val sha = metadataSha ?: inRootfsSha?.takeIf { it == asset.sha256 } ?: return null
        val version = obj?.optString("version")?.takeIf { it.isNotBlank() }
            ?: asset.version
        return InstalledRootfs(
            version = version,
            sha256 = sha,
            installedAt = obj?.optString("installedAt")?.takeIf { it.isNotBlank() },
            // Cheap installation-size estimate for probe/status. The exact
            // walk stays behind the separate `diskUsage` call so a startup
            // probe never scans ~100 MB of rootfs files.
            bytes = obj?.optLong("uncompressedBytes", asset.uncompressedBytes)
                ?: asset.uncompressedBytes,
        )
    }

    fun isReady(): Boolean = installed() != null

    fun expectedVersion(): String = try {
        manifest().version
    } catch (_: Exception) {
        "unknown"
    }

    /**
     * Install/reinstall the pinned rootfs. Idempotent: a matching marker
     * returns immediately. [cancel] is polled while streaming and before the
     * atomic swap.
     */
    fun install(
        progress: Progress? = null,
        cancel: () -> Boolean = { false },
    ) {
        synchronized(installMutex) {
            paths.ensureDirs()
            val asset = manifest()
            if (isReady()) {
                patchRootfs(paths.rootfs)
                progress?.onStage("ready")
                progress?.onProgress(100)
                return
            }

            val lockFile = paths.installLock
            FileOutputStream(lockFile).use { lockOut ->
                val lock = try {
                    lockOut.channel.tryLock()
                } catch (_: Exception) {
                    null
                }
                if (lock == null) {
                    throw IOException("Another rootfs installation is already running.")
                }
                try {
                    installLocked(asset, progress, cancel)
                } finally {
                    try {
                        lock.release()
                    } catch (_: Exception) {
                    }
                }
            }
        }
    }

    private fun installLocked(
        asset: RuntimeAsset,
        progress: Progress?,
        cancel: () -> Boolean,
    ) {
        // Peak storage: archive + staging + (optional) old tree.
        val keepOld = paths.rootfs.isDirectory
        val needed = asset.uncompressedBytes * (if (keepOld) 2 else 1) +
            (if (asset.uncompressedBytes > 0) 32L * 1024 * 1024 else 0L) +
            SPACE_MARGIN
        if (asset.uncompressedBytes > 0) {
            val available = freeBytes()
            if (available < needed) {
                throw IOException(
                    "空間不足：安裝 Android Shell 需要約 ${needed / (1024 * 1024)} MB，" +
                        "裝置目前僅剩 ${available / (1024 * 1024)} MB。請先釋放儲存空間再重試。",
                )
            }
        }

        progress?.onStage("verify")
        progress?.onProgress(2)
        paths.rootfsStaging.deleteRecursively()
        paths.rootfsStaging.mkdirs()
        val archive = File(paths.cache, asset.file)
        archive.parentFile?.mkdirs()
        archive.delete()

        // 1. Stream the asset out of the APK, hashing as we go.
        context.assets.open("$ASSET_SANDBOX/${asset.file}").use { input ->
            archive.outputStream().use { out ->
                val buf = ByteArray(BUF)
                val digest = MessageDigest.getInstance("SHA-256")
                var copied = 0L
                var lastPercent = -1
                while (true) {
                    if (cancel()) {
                        archive.delete()
                        paths.rootfsStaging.deleteRecursively()
                        throw IOException("Install cancelled.")
                    }
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    digest.update(buf, 0, n)
                    copied += n
                    val percent = ((copied / (8L * 1024 * 1024)) * 5).toInt().coerceIn(2, 45)
                    if (percent != lastPercent) {
                        lastPercent = percent
                        progress?.onProgress(percent)
                    }
                }
                val got = digest.digest().joinToString("") { "%02x".format(it) }
                if (got != asset.sha256) {
                    archive.delete()
                    paths.rootfsStaging.deleteRecursively()
                    throw IOException(
                        "runtime asset ${asset.file} SHA256 mismatch (got $got) — " +
                            "APK corrupt or repacked",
                    )
                }
            }
        }

        // 2. Extract (the extractor unlinks the archive as soon as its fd opens).
        progress?.onStage("extract")
        progress?.onProgress(50)
        try {
            SafeTarExtractor.extract(archive, paths.rootfsStaging)
        } catch (e: Exception) {
            paths.rootfsStaging.deleteRecursively()
            throw IOException("rootfs extraction failed: ${e.message}", e)
        } finally {
            archive.delete()
        }
        if (cancel()) {
            paths.rootfsStaging.deleteRecursively()
            throw IOException("Install cancelled.")
        }

        // 3. Patch and validate before activation.
        progress?.onStage("patch")
        progress?.onProgress(78)
        patchRootfs(paths.rootfsStaging)
        val shell = File(paths.rootfsStaging, "bin/sh")
        if (!shell.isFile || !shell.canExecute()) {
            paths.rootfsStaging.deleteRecursively()
            throw IOException("rootfs validation failed: /bin/sh is missing or not executable")
        }
        val marker = File(paths.rootfsStaging, "etc/omnichat-rootfs")
        marker.parentFile?.mkdirs()
        marker.writeText("${asset.sha256}\n${asset.version}\n")

        // 4. Atomic activate (keep the old tree until the rename succeeds).
        progress?.onStage("activate")
        progress?.onProgress(90)
        if (cancel()) {
            paths.rootfsStaging.deleteRecursively()
            throw IOException("Install cancelled.")
        }
        paths.rootfsOld.deleteRecursively()
        if (paths.rootfs.exists() && !paths.rootfs.renameTo(paths.rootfsOld)) {
            paths.rootfsStaging.deleteRecursively()
            throw IOException("failed to move the previous rootfs aside")
        }
        if (!paths.rootfsStaging.renameTo(paths.rootfs)) {
            if (paths.rootfsOld.exists() && !paths.rootfs.exists()) {
                paths.rootfsOld.renameTo(paths.rootfs)
            }
            paths.rootfsStaging.deleteRecursively()
            throw IOException("failed to activate the new rootfs")
        }
        paths.rootfsOld.deleteRecursively()
        paths.rootfsStaging.deleteRecursively()

        // 5. Commit metadata last; a crash before this point leaves the old
        // marker (or no marker) and the next install repairs it.
        writeMetadata(asset)
        cleanup()
        progress?.onStage("ready")
        progress?.onProgress(100)
        Log.i(TAG, "rootfs ${asset.version} installed at ${paths.rootfs.path}")
    }

    private fun writeMetadata(asset: RuntimeAsset) {
        val obj = JSONObject()
            .put("version", asset.version)
            .put("sha256", asset.sha256)
            .put("uncompressedBytes", asset.uncompressedBytes)
            .put("installedAt", isoTimestamp())
        val tmp = File(paths.runtimeDir, "metadata.json.tmp")
        tmp.writeText(obj.toString(2))
        if (paths.metadata.exists()) paths.metadata.delete()
        if (!tmp.renameTo(paths.metadata)) {
            tmp.copyTo(paths.metadata, overwrite = true)
            tmp.delete()
        }
    }

    /** Idempotent DNS/hosts/tmp patcher. Only touches the supplied rootfs. */
    fun patchRootfs(root: File) {
        if (!root.isDirectory) return
        try {
            val etc = File(root, "etc").apply { mkdirs() }
            val dns = currentDnsServers()
            val resolvers = (dns + listOf("1.1.1.1", "8.8.8.8", "9.9.9.9"))
                .distinct()
                .take(4)
            File(etc, "resolv.conf").writeText(
                resolvers.joinToString("\n") { "nameserver $it" } + "\n",
            )
            File(etc, "hosts").writeText(
                "127.0.0.1 localhost\n" +
                    "127.0.1.1 omnichat-sandbox\n" +
                    "::1 localhost ip6-localhost ip6-loopback\n",
            )
            File(etc, "hostname").writeText("omnichat-sandbox\n")

            val profileDir = File(etc, "profile.d").apply { mkdirs() }
            File(profileDir, "omnichat.sh").writeText(
                "export LANG=C.UTF-8\n" +
                    "export LC_ALL=C.UTF-8\n" +
                    "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n",
            )

            for (path in listOf("tmp", "var/tmp", "root")) {
                val dir = File(root, path)
                dir.mkdirs()
                try {
                    dir.setReadable(true, false)
                    dir.setWritable(true, false)
                    dir.setExecutable(true, false)
                } catch (_: Exception) {
                }
            }
        } catch (e: Exception) {
            // DNS/hosts are conveniences; a patch failure must not brick an
            // otherwise valid rootfs.
            Log.w(TAG, "rootfs patch failed (non-fatal)", e)
        }
    }

    fun remove() {
        synchronized(installMutex) {
            paths.rootfs.deleteRecursively()
            paths.rootfsStaging.deleteRecursively()
            paths.rootfsOld.deleteRecursively()
            paths.cache.deleteRecursively()
            paths.metadata.delete()
            paths.tmp.deleteRecursively()
            paths.procFakes.deleteRecursively()
            paths.libs.deleteRecursively()
            paths.ensureDirs()
        }
    }

    fun freeBytes(): Long = try {
        StatFs(paths.runtimeDir.absolutePath).availableBytes
    } catch (_: Exception) {
        0L
    }

    fun diskUsageBytes(): Long {
        val root = paths.rootfs
        if (!root.isDirectory) return 0L
        var total = 0L
        val stack = ArrayDeque<File>().apply { add(root) }
        try {
            while (stack.isNotEmpty()) {
                val dir = stack.removeLast()
                val children = dir.listFiles() ?: continue
                for (file in children) {
                    // Never follow rootfs symlinks (usrmerge creates several);
                    // they would double-count and a cycle would loop forever.
                    val stat = try {
                        Os.lstat(file.absolutePath)
                    } catch (_: Exception) {
                        continue
                    }
                    if ((stat.st_mode and 0xF000) == 0xA000) continue
                    if (file.isDirectory) {
                        stack.addLast(file)
                    } else {
                        total += stat.st_size
                    }
                }
            }
        } catch (_: Exception) {
        }
        return total
    }

    private fun cleanup() {
        try {
            paths.cache.deleteRecursively()
            paths.cache.mkdirs()
            // Keep the tmp directories (and their 1777-ish permissions) and
            // only drop their contents; deleting the dirs would recreate them
            // with the process umask.
            for (path in listOf("tmp", "var/tmp")) {
                val dir = File(paths.rootfs, path)
                dir.listFiles()?.forEach { it.deleteRecursively() }
                dir.mkdirs()
            }
        } catch (_: Exception) {
        }
    }

    private fun isoTimestamp(): String {
        val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
        format.timeZone = TimeZone.getTimeZone("UTC")
        return format.format(Date())
    }

    private fun currentDnsServers(): List<String> {
        fun getprop(name: String): String = try {
            val process = ProcessBuilder("getprop", name).redirectErrorStream(true).start()
            val out = process.inputStream.bufferedReader().use { it.readText() }.trim()
            process.waitFor()
            out
        } catch (_: Exception) {
            ""
        }
        return listOf(getprop("net.dns1"), getprop("net.dns2"), getprop("net.dns3"))
            .filter { it.matches(Regex("^(?!127\\.)(\\d{1,3}\\.){3}\\d{1,3}$")) }
    }
}
