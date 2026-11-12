package com.psyche.omnichat.sandbox

import android.os.Build
import android.os.Process
import android.system.Os
import java.io.File

/** One host → guest bind. Read-only is an app-level policy, not a proot flag. */
data class BindMount(
    val host: String,
    val guest: String,
    val readOnly: Boolean = false,
)

data class ProotLaunch(
    val argv: List<String>,
    val processEnv: Map<String, String>,
    val workingDirectory: File,
)

/**
 * PRoot argv assembly (P2-5 §2.8 items 1–4).
 *
 * Security-relevant invariants:
 * - the command is passed as a **positional argument** to `sh -lc`, never
 *   concatenated into a host command line;
 * - guest `cwd` must be absolute, NUL-free, and free of `..`;
 * - binds must target a small allowlist of guest roots;
 * - the guest environment starts from `env -i` (no host environment leaks);
 * - `--kill-on-exit` makes proot reap guest children when the tracer exits.
 */
object ProotCommand {
    const val EXEC_LIB = "libproot_exec.so"
    const val LOADER_LIB = "libproot_loader.so"
    const val TALLOC_SONAME = "libtalloc.so.2"
    const val BASH_EVAL = "cd -- \"\$1\" && eval \"\$2\""

    // Keep in sync with WorkspaceMountTable._isAllowedGuest on the Dart side.
    private val ALLOWED_GUEST_ROOTS = listOf(
        "/workspace",
        "/upload",
        "/skills",
        "/tmp",
        "/mounts/",
    )

    fun validateGuestPath(path: String, label: String = "guest path"): String {
        val trimmed = path.trim()
        require(trimmed.startsWith("/")) { "$label must be absolute" }
        require(!trimmed.contains('\u0000')) { "$label contains a NUL byte" }
        require(trimmed.split('/').none { it == ".." }) { "$label must not contain .. segments" }
        return trimmed
    }

    fun validateGuestCwd(cwd: String): String {
        val guest = validateGuestPath(cwd, "guest cwd")
        require(guest == "/workspace" || guest.startsWith("/workspace/")) {
            "guest cwd must stay inside /workspace"
        }
        return guest
    }

    fun validateBinds(binds: List<BindMount>) {
        require(binds.size <= 16) { "too many bind mounts" }
        val seen = mutableSetOf<String>()
        for (bind in binds) {
            val host = bind.host.trim()
            require(File(host).isAbsolute) { "bind host must be absolute" }
            require(!host.contains('\u0000')) {
                "bind host contains a NUL byte"
            }
            // Android host paths are POSIX; reject ':' there (PRoot's
            // host:guest separator). Keep Windows drive letters usable for
            // the JVM argv tests.
            require(File.separatorChar == '\\' || !host.contains(':')) {
                "bind host contains an invalid character"
            }
            require(File(host).isDirectory) { "bind host is not a directory: $host" }
            val guest = validateGuestPath(bind.guest, "bind guest")
            require(ALLOWED_GUEST_ROOTS.any { guest == it || guest.startsWith("$it/") }) {
                "bind guest is outside the allowlist: $guest"
            }
            require(seen.add(guest)) { "duplicate bind guest: $guest" }
        }
    }

    fun defaultKernelRelease(): String? {
        val is64 = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) Process.is64Bit() else false
        } catch (_: Exception) {
            false
        }
        if (is64) return null
        return try {
            Os.uname().release
        } catch (_: Exception) {
            "5.15.0-android"
        }
    }

    fun build(
        nativeLibDir: File,
        rootfsDir: File,
        tmpDir: File,
        procFakeFiles: Map<String, File>,
        binds: List<BindMount>,
        cwd: String,
        command: String,
        tallocDir: File,
        kernelRelease: String? = defaultKernelRelease(),
    ): ProotLaunch {
        val guestCwd = validateGuestCwd(cwd)
        require(command.isNotBlank()) { "command must not be blank" }
        require(!command.contains('\u0000')) { "command contains a NUL byte" }
        require(command.length <= 64 * 1024) { "command is too long" }
        validateBinds(binds)

        val exec = File(nativeLibDir, EXEC_LIB)
        val loader = File(nativeLibDir, LOADER_LIB)
        require(exec.isFile) { "PRoot exec missing: ${exec.path}" }
        require(loader.isFile) { "PRoot loader missing: ${loader.path}" }

        val argv = mutableListOf(
            exec.absolutePath,
            "--root-id",
            "--sysvipc",
            "--link2symlink",
            "--kill-on-exit",
        )
        if (kernelRelease != null) argv += "--kernel-release=$kernelRelease"
        argv += listOf("-r", rootfsDir.absolutePath, "-w", guestCwd)
        for (bind in binds) {
            argv += "-b"
            argv += "${bind.host}:${bind.guest}"
        }
        argv += listOf("-b", "/dev", "-b", "/dev/urandom:/dev/random")
        // Specific /proc fakes first, then /proc itself. PRoot resolves nested
        // binds so the fakes shadow the vendor kernel files.
        for ((guestPath, file) in procFakeFiles) {
            argv += "-b"
            argv += "${file.absolutePath}:$guestPath"
        }
        argv += listOf("-b", "/proc", "-b", "/sys")

        // Terminator: everything after this is the guest program, not proot.
        argv += listOf("/usr/bin/env", "-i")
        val guestEnv = linkedMapOf(
            "HOME" to "/root",
            "PATH" to "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "LANG" to "C.UTF-8",
            "LC_ALL" to "C.UTF-8",
            "TERM" to "dumb",
            "NO_COLOR" to "1",
            "CI" to "true",
            "PAGER" to "cat",
            "TMPDIR" to "/tmp",
        )
        for ((key, value) in guestEnv) argv += "$key=$value"
        // `$1` is the cwd and `$2` the command; both arrive as independent
        // argv entries, so no shell metacharacter in the command can escape
        // into the host command line.
        argv += listOf("/bin/sh", "-lc", BASH_EVAL, "omnichat", guestCwd, command)

        val talloc = File(tallocDir, TALLOC_SONAME)
        val processEnv = linkedMapOf(
            "PROOT_LOADER" to loader.absolutePath,
            "PROOT_TMP_DIR" to tmpDir.absolutePath,
            "TMPDIR" to tmpDir.absolutePath,
        )
        if (talloc.isFile) {
            processEnv["LD_LIBRARY_PATH"] =
                tallocDir.absolutePath + File.pathSeparator + nativeLibDir.absolutePath
        } else {
            processEnv["LD_LIBRARY_PATH"] = nativeLibDir.absolutePath
        }

        return ProotLaunch(
            argv = argv,
            processEnv = processEnv,
            workingDirectory = rootfsDir.parentFile ?: rootfsDir,
        )
    }
}
