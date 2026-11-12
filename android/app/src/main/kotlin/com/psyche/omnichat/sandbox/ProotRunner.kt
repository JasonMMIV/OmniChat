package com.psyche.omnichat.sandbox

import android.content.Context
import android.system.Os
import android.system.OsConstants
import android.util.Log
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Foreground one-shot PRoot execution (P2-5 §2.8 items 1/3/11).
 *
 * A run is a single process tree:
 *   PRoot → /usr/bin/env -i … → /bin/sh -lc 'cd -- "$1" && eval "$2"' …
 *
 * Output is drained continuously from both pipes (a full pipe must never
 * block the child), capped in memory, and mirrored to Dart for the live tool
 * card. Timeout/cancel sends SIGQUIT first (PRoot's own reaper runs
 * `--kill-on-exit`), then sweeps the whole sandbox process tree — killing only
 * the tracer would orphan guest children.
 */
class ProotRunner(
    private val context: Context,
    private val paths: SandboxPaths,
    private val emit: (String, Map<String, Any?>) -> Unit,
) {

    companion object {
        private const val TAG = "OmniChatProot"
        // Product contract (plan §2.8 item 11): 24 KB stdout / 6 KB stderr.
        // Live ToolRun output still receives every chunk before this cap.
        private const val MAX_STDOUT_BYTES = 24 * 1024
        private const val MAX_STDERR_BYTES = 6 * 1024
    }

    private data class Running(
        val process: Process,
        val cancelled: AtomicBoolean = AtomicBoolean(false),
        val timedOut: AtomicBoolean = AtomicBoolean(false),
    )

    private class Collector(
        private val capBytes: Int,
        private val onChunk: (ByteArray) -> Unit,
    ) {
        private val buffer = java.io.ByteArrayOutputStream()
        var truncated: Boolean = false
            private set

        fun add(chunk: ByteArray) {
            if (chunk.isEmpty()) return
            onChunk(chunk)
            val room = capBytes - buffer.size()
            if (room <= 0) {
                truncated = true
                return
            }
            if (chunk.size <= room) {
                buffer.write(chunk, 0, chunk.size)
            } else {
                buffer.write(chunk, 0, room)
                truncated = true
            }
        }

        fun bytes(): ByteArray = buffer.toByteArray()
    }

    private val active = ConcurrentHashMap<String, Running>()
    private val commandGate = AtomicBoolean(false)

    fun isBusy(): Boolean = commandGate.get() || active.isNotEmpty()

    fun run(
        runId: String,
        command: String,
        guestCwd: String,
        timeoutMs: Long,
        binds: List<BindMount>,
    ): Map<String, Any?> {
        if (!commandGate.compareAndSet(false, true)) {
            throw IOException("The Android shell is already running a command.")
        }
        try {
            return runLocked(runId, command, guestCwd, timeoutMs, binds)
        } finally {
            commandGate.set(false)
        }
    }

    private fun runLocked(
        runId: String,
        command: String,
        guestCwd: String,
        timeoutMs: Long,
        binds: List<BindMount>,
    ): Map<String, Any?> {
        // Reap orphans from a previous SIGKILLed app process before spawning
        // a new PRoot tree (AnyBuff's hard-won lesson: orphaned guest children
        // pile up until memory pressure kills the fresh run too).
        killStraySandboxProcesses()
        ensureProcFakes()
        stageTalloc()

        val launch = ProotCommand.build(
            nativeLibDir = File(context.applicationInfo.nativeLibraryDir),
            rootfsDir = paths.rootfs,
            tmpDir = paths.tmp,
            procFakeFiles = procFakeFiles(),
            binds = binds,
            cwd = guestCwd,
            command = command,
            tallocDir = paths.libs,
        )
        val builder = ProcessBuilder(launch.argv)
            .directory(launch.workingDirectory)
            .redirectErrorStream(false)
        builder.environment().clear()
        builder.environment().putAll(launch.processEnv)

        val startedAt = System.currentTimeMillis()
        val process = builder.start()
        try {
            process.outputStream.close()
        } catch (_: Exception) {
        }

        val running = Running(process)
        active[runId] = running

        val stdout = Collector(MAX_STDOUT_BYTES) { chunk ->
            emit(
                "runOutput",
                mapOf(
                    "runId" to runId,
                    "stream" to "stdout",
                    "data" to chunk,
                ),
            )
        }
        val stderr = Collector(MAX_STDERR_BYTES) { chunk ->
            emit(
                "runOutput",
                mapOf(
                    "runId" to runId,
                    "stream" to "stderr",
                    "data" to chunk,
                ),
            )
        }
        val stdoutThread = drain(process.inputStream, stdout, "stdout-$runId")
        val stderrThread = drain(process.errorStream, stderr, "stderr-$runId")

        val finished = waitFor(process, timeoutMs.coerceAtLeast(1_000L))
        if (!finished) {
            if (running.cancelled.get()) {
                // cancel() already requested exit.
            } else {
                running.timedOut.set(true)
            }
            stopProcess(process)
            waitFor(process, 2_000L)
        }

        val cancelled = running.cancelled.get()
        val timedOut = running.timedOut.get()
        var exitCode = try {
            process.exitValue()
        } catch (_: Exception) {
            -1
        }
        if (cancelled || timedOut) exitCode = -1

        // Let the pipe readers observe EOF; a daemonized guest may hold a pipe
        // open, so bound the join.
        stdoutThread.join(1_500)
        stderrThread.join(1_500)
        try {
            process.inputStream.close()
        } catch (_: Exception) {
        }
        try {
            process.errorStream.close()
        } catch (_: Exception) {
        }

        active.remove(runId, running)
        return mapOf(
            "exitCode" to exitCode,
            "durationMs" to (System.currentTimeMillis() - startedAt),
            "timedOut" to timedOut,
            "cancelled" to cancelled,
            "interrupted" to (!finished && !timedOut && !cancelled),
            "stdout" to String(stdout.bytes(), Charsets.UTF_8),
            "stderr" to String(stderr.bytes(), Charsets.UTF_8),
            "stdoutTruncated" to stdout.truncated,
            "stderrTruncated" to stderr.truncated,
        )
    }

    fun cancel(runId: String): Boolean {
        val running = active[runId] ?: return false
        running.cancelled.set(true)
        stopProcess(running.process)
        return true
    }

    fun cancelAll() {
        for ((_, running) in active) {
            running.cancelled.set(true)
            stopProcess(running.process)
        }
    }

    /** Kill every process whose cmdline contains this install's PRoot path. */
    fun killStraySandboxProcesses() {
        try {
            val parents = procParentMap()
            for (pid in sandboxPids()) {
                for (child in descendantsOf(pid, parents).asReversed()) {
                    try {
                        android.os.Process.killProcess(child)
                    } catch (_: Exception) {
                    }
                }
                try {
                    android.os.Process.killProcess(pid)
                } catch (_: Exception) {
                }
            }
        } catch (_: Exception) {
        }
    }

    private fun stopProcess(process: Process) {
        if (!isAlive(process)) return
        val pid = processPid(process)
        if (pid != null) {
            // SIGQUIT asks PRoot to kill and reap the complete traced set.
            try {
                Os.kill(pid.toInt(), OsConstants.SIGQUIT)
            } catch (_: Exception) {
            }
            if (waitFor(process, 1_500L)) return
        }
        try {
            process.destroy()
        } catch (_: Exception) {
        }
        if (waitFor(process, 1_000L)) return
        killStraySandboxProcesses()
        try {
            process.destroy()
        } catch (_: Exception) {
        }
        if (pid != null) {
            try {
                android.os.Process.killProcess(pid.toInt())
            } catch (_: Exception) {
            }
        }
    }

    private fun drain(
        stream: InputStream,
        collector: Collector,
        name: String,
    ): Thread {
        val thread = Thread({
            val buffer = ByteArray(8 * 1024)
            try {
                stream.use { input ->
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        if (read == 0) continue
                        collector.add(buffer.copyOf(read))
                    }
                }
            } catch (e: Exception) {
                Log.d(TAG, "drain $name ended: ${e.message}")
            }
        }, "omnichat-sandbox-$name")
        thread.isDaemon = true
        thread.start()
        return thread
    }

    private fun ensureProcFakes() {
        paths.procFakes.mkdirs()
        File(paths.procFakes, "stat").writeText(fakeProcStat())
        File(paths.procFakes, "loadavg").writeText("0.00 0.01 0.05 1/100 1\n")
        File(paths.procFakes, "version").writeText("Linux version 6.1.0-android (fake)\n")
        File(paths.procFakes, "vmstat").writeText("nr_free_pages 100000\n")
    }

    private fun procFakeFiles(): Map<String, File> = linkedMapOf(
        "/proc/stat" to File(paths.procFakes, "stat"),
        "/proc/loadavg" to File(paths.procFakes, "loadavg"),
        "/proc/version" to File(paths.procFakes, "version"),
        "/proc/vmstat" to File(paths.procFakes, "vmstat"),
    )

    /** Copy the LGPL talloc runtime out of the APK to the SONAME proot NEEDs. */
    private fun stageTalloc() {
        paths.libs.mkdirs()
        val dest = File(paths.libs, ProotCommand.TALLOC_SONAME)
        if (dest.isFile && dest.length() > 0) return
        val tmp = File(paths.libs, "${ProotCommand.TALLOC_SONAME}.tmp")
        context.assets.open("sandbox/lib/${ProotCommand.TALLOC_SONAME}").use { input ->
            tmp.outputStream().use { input.copyTo(it) }
        }
        if (!tmp.renameTo(dest)) {
            tmp.copyTo(dest, overwrite = true)
            tmp.delete()
        }
    }

    private fun fakeProcStat(): String =
        "cpu  100 0 100 10000 0 0 0 0 0 0\n" +
            "cpu0 50 0 50 5000 0 0 0 0 0 0\n" +
            "intr 100 0 0 0 0 0 0 0 0 0\n" +
            "ctxt 1000\n" +
            "btime 1700000000\n" +
            "processes 10\n" +
            "procs_running 1\n" +
            "procs_blocked 0\n"

    private fun waitFor(process: Process, timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (!isAlive(process)) return true
            try {
                Thread.sleep(40)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return !isAlive(process)
            }
        }
        return !isAlive(process)
    }

    private fun isAlive(process: Process): Boolean = try {
        process.exitValue()
        false
    } catch (_: IllegalThreadStateException) {
        true
    } catch (_: Exception) {
        false
    }

    private fun processPid(process: Process): Long? {
        try {
            val method = process.javaClass.methods.firstOrNull {
                it.name == "pid" && it.parameterCount == 0
            }
            val value = method?.invoke(process) as? Number
            if (value != null && value.toLong() > 0L) return value.toLong()
        } catch (_: Exception) {
        }
        try {
            val field = process.javaClass.getDeclaredField("pid")
            field.isAccessible = true
            val value = (field.get(process) as? Number)?.toLong()
            if (value != null && value > 0L) return value
        } catch (_: Exception) {
        }
        return Regex("pid[= ](\\d+)").find(process.toString())?.groupValues?.get(1)?.toLongOrNull()
    }

    private fun procParentMap(): Map<Int, Int> {
        val map = mutableMapOf<Int, Int>()
        for (dir in File("/proc").listFiles() ?: emptyArray()) {
            val pid = dir.name.toIntOrNull() ?: continue
            val stat = try {
                File(dir, "stat").readText()
            } catch (_: Exception) {
                continue
            }
            val close = stat.lastIndexOf(')')
            if (close < 0) continue
            val ppid = stat.substring(close + 2).split(' ').getOrNull(1)?.toIntOrNull()
                ?: continue
            map[pid] = ppid
        }
        return map
    }

    private fun descendantsOf(root: Int, parentOf: Map<Int, Int>): List<Int> {
        val childrenOf = parentOf.entries.groupBy({ it.value }, { it.key })
        val out = mutableListOf<Int>()
        val stack = ArrayDeque<Int>().apply { add(root) }
        while (stack.isNotEmpty()) {
            val pid = stack.removeLast()
            for (child in childrenOf[pid].orEmpty()) {
                out.add(child)
                stack.addLast(child)
            }
        }
        return out
    }

    private fun sandboxPids(): List<Int> {
        val needle = try {
            File(context.applicationInfo.nativeLibraryDir, ProotCommand.EXEC_LIB).absolutePath
        } catch (_: Exception) {
            return emptyList()
        }
        val out = mutableListOf<Int>()
        for (dir in File("/proc").listFiles() ?: emptyArray()) {
            val pid = dir.name.toIntOrNull() ?: continue
            val cmd = try {
                File(dir, "cmdline").readBytes().toString(Charsets.UTF_8)
            } catch (_: Exception) {
                continue
            }
            if (cmd.contains(needle)) out.add(pid)
        }
        return out
    }
}
