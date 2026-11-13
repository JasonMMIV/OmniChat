package com.psyche.omnichat.sandbox

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Flutter bridge for the Android PRoot sandbox (P2-5).
 *
 * Methods:
 *   probe         → supported/ABI/rootfs state/free space
 *   install       → install the pinned rootfs (progress via `installProgress`)
 *   cancelInstall → cooperative cancel of an in-flight install
 *   remove        → delete the rootfs/runtime payloads
 *   run           → one foreground command (output via `runOutput`)
 *   cancel        → cancel one run by id
 *   diskUsage     → rootfs size + free space
 */
class SandboxPlugin(private val context: Context) {

    companion object {
        const val CHANNEL_NAME = "omnichat/sandbox"
        private const val TAG = "OmniChatSandbox"
    }

    private val paths = SandboxPaths(context)
    private val installer = RootfsInstaller(context, paths)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newCachedThreadPool()
    private var channel: MethodChannel? = null
    private val runner = ProotRunner(context, paths) { method, args -> emit(method, args) }
    private val installing = AtomicBoolean(false)
    private val installCancelled = AtomicBoolean(false)

    /** Serializes the start of install/run/remove so check-then-act is atomic. */
    private val operationLock = Any()
    private var commandStarting = false
    private var removing = false

    fun configure(messenger: BinaryMessenger) {
        paths.ensureDirs()
        channel = MethodChannel(messenger, CHANNEL_NAME).also { ch ->
            ch.setMethodCallHandler { call, result -> handle(call, result) }
        }
    }

    fun dispose() {
        installCancelled.set(true)
        runner.cancelAll()
        channel?.setMethodCallHandler(null)
        channel = null
        executor.shutdownNow()
        synchronized(operationLock) {
            commandStarting = false
            removing = false
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "probe" -> runAsync(result) { probe() }
                "install" -> install(result)
                "cancelInstall" -> {
                    installCancelled.set(true)
                    result.success(true)
                }
                "remove" -> remove(result)
                "run" -> run(call, result)
                "cancel" -> {
                    val runId = asMap(call.arguments)["runId"]?.toString().orEmpty()
                    // Never block the platform thread on the SIGQUIT/wait
                    // sequence; the run future reports the terminal state.
                    if (runId.isNotEmpty()) {
                        executor.execute { runner.cancel(runId) }
                    }
                    result.success(runId.isNotEmpty())
                }
                "diskUsage" -> runAsync(result) {
                    mapOf(
                        "rootfsBytes" to installer.diskUsageBytes(),
                        "freeBytes" to installer.freeBytes(),
                    )
                }
                else -> result.notImplemented()
            }
        } catch (error: IllegalArgumentException) {
            result.error("invalid_args", error.message, null)
        } catch (error: Exception) {
            Log.w(TAG, "sandbox call ${call.method} failed", error)
            result.error("sandbox", error.message ?: error.javaClass.simpleName, null)
        }
    }

    private fun probe(): Map<String, Any?> {
        val nativeLibDir = File(context.applicationInfo.nativeLibraryDir)
        val exec = File(nativeLibDir, ProotCommand.EXEC_LIB)
        val loader = File(nativeLibDir, ProotCommand.LOADER_LIB)
        if (exec.isFile) exec.setExecutable(true, false)
        if (loader.isFile) loader.setExecutable(true, false)

        val abiSupported = isArm64Process()
        val nativeReady = abiSupported && exec.isFile && loader.isFile &&
            exec.canExecute() && loader.canExecute()
        val installed = installer.installed()
        val reason = when {
            !abiSupported -> "unsupported_abi"
            !exec.isFile -> "proot_missing"
            !exec.canExecute() -> "proot_not_executable"
            !loader.isFile -> "proot_loader_missing"
            !loader.canExecute() -> "proot_loader_not_executable"
            installed == null -> "rootfs_not_installed"
            else -> null
        }
        val tallocStaged = File(paths.libs, ProotCommand.TALLOC_SONAME).isFile
        return mapOf(
            "supported" to nativeReady,
            "ready" to (nativeReady && installed != null),
            "reason" to reason,
            "abi" to Build.SUPPORTED_ABIS.firstOrNull().orEmpty(),
            "nativeLibDir" to nativeLibDir.absolutePath,
            "prootPath" to exec.takeIf { it.isFile }?.absolutePath,
            "loaderPath" to loader.takeIf { it.isFile }?.absolutePath,
            "tallocStaged" to tallocStaged,
            "rootfsDir" to paths.rootfs.absolutePath,
            "rootfsInstalled" to (installed != null),
            "rootfsVersion" to installed?.version,
            "installedAt" to installed?.installedAt,
            "rootfsBytes" to (installed?.bytes ?: 0L),
            "freeBytes" to installer.freeBytes(),
            "busy" to (installing.get() || runner.isBusy()),
        )
    }

    private fun isArm64Process(): Boolean {
        val is64 = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) Process.is64Bit() else false
        } catch (_: Exception) {
            false
        }
        if (!is64) return false
        return Build.SUPPORTED_ABIS.any { it == "arm64-v8a" }
    }

    private fun install(result: MethodChannel.Result) {
        synchronized(operationLock) {
            if (installing.getAndSet(true)) {
                result.error("busy", "An installation is already running.", null)
                return
            }
            if (commandStarting || removing || runner.isBusy()) {
                installing.set(false)
                result.error("busy", "Stop the running command before installing.", null)
                return
            }
        }
        installCancelled.set(false)
        executor.execute {
            try {
                installer.install(
                    progress = object : RootfsInstaller.Progress {
                        override fun onStage(stage: String) {
                            emit("installProgress", mapOf("stage" to stage, "percent" to 0))
                        }

                        override fun onProgress(percent: Int) {
                            emit(
                                "installProgress",
                                mapOf("stage" to "progress", "percent" to percent),
                            )
                        }
                    },
                    cancel = { installCancelled.get() },
                )
                val value = probe()
                mainHandler.post { result.success(value) }
            } catch (error: Exception) {
                if (installCancelled.get()) {
                    // Cancellation is a user action, not an install failure.
                    val value = probe()
                    mainHandler.post { result.success(value) }
                } else {
                    Log.w(TAG, "rootfs install failed", error)
                    mainHandler.post {
                        result.error(
                            "install_failed",
                            error.message ?: "install failed",
                            null,
                        )
                    }
                }
            } finally {
                installing.set(false)
            }
        }
    }

    private fun remove(result: MethodChannel.Result) {
        synchronized(operationLock) {
            if (installing.get()) {
                result.error("busy", "An installation is already running.", null)
                return
            }
            if (commandStarting || removing || runner.isBusy()) {
                result.error("busy", "Stop the running command before removing the rootfs.", null)
                return
            }
            removing = true
        }
        executor.execute {
            try {
                installer.remove()
                mainHandler.post { result.success(probe()) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error("remove_failed", error.message ?: "remove failed", null)
                }
            } finally {
                synchronized(operationLock) { removing = false }
            }
        }
    }

    private fun run(call: MethodCall, result: MethodChannel.Result) {
        val args = asMap(call.arguments)
        val runId = requiredString(args, "runId")
        val command = requiredString(args, "command")
        val guestCwd = ProotCommand.validateGuestCwd(requiredString(args, "cwd"))
        val timeoutMs = normalizeTimeoutMs(
            number(args["timeoutMs"], DEFAULT_TIMEOUT_MS),
        )
        val binds = parseBinds(args["binds"])
        if (installer.installed() == null) {
            result.error("rootfs_not_installed", "Install Android Shell first.", null)
            return
        }
        synchronized(operationLock) {
            if (installing.get() || removing || commandStarting || runner.isBusy()) {
                result.error("busy", "The Android shell is already running a command.", null)
                return
            }
            commandStarting = true
        }
        executor.execute {
            try {
                val value = runner.run(
                    runId = runId,
                    command = command,
                    guestCwd = guestCwd,
                    timeoutMs = timeoutMs,
                    binds = binds,
                )
                mainHandler.post { result.success(value) }
            } catch (error: Exception) {
                Log.w(TAG, "sandbox command failed", error)
                mainHandler.post {
                    result.error("execution_error", error.message ?: "execution failed", null)
                }
            } finally {
                synchronized(operationLock) { commandStarting = false }
            }
        }
    }

    /** Run a blocking probe/install-side operation off the platform thread. */
    private fun runAsync(
        result: MethodChannel.Result,
        block: () -> Any?,
    ) {
        executor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error(
                        "sandbox",
                        error.message ?: error.javaClass.simpleName,
                        null,
                    )
                }
            }
        }
    }

    private fun emit(method: String, args: Map<String, Any?>) {
        val ch = channel ?: return
        mainHandler.post {
            try {
                ch.invokeMethod(method, args)
            } catch (_: Exception) {
            }
        }
    }

    private fun asMap(value: Any?): Map<*, *> = value as? Map<*, *> ?: emptyMap<Any, Any>()

    private fun requiredString(args: Map<*, *>, key: String): String {
        val value = args[key]?.toString()?.trim().orEmpty()
        require(value.isNotEmpty()) { "missing $key" }
        return value
    }

    private fun number(value: Any?, fallback: Long): Long = when (value) {
        is Number -> value.toLong()
        is String -> value.toLongOrNull() ?: fallback
        else -> fallback
    }

    private fun parseBinds(raw: Any?): List<BindMount> {
        val list = raw as? List<*> ?: return emptyList()
        return list.mapNotNull { item ->
            val map = item as? Map<*, *> ?: return@mapNotNull null
            val host = map["host"]?.toString().orEmpty()
            val guest = map["guest"]?.toString().orEmpty()
            if (host.isBlank() || guest.isBlank()) return@mapNotNull null
            BindMount(host, guest, map["readOnly"] == true)
        }
    }
}
