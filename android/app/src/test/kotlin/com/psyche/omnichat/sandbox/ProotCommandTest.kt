package com.psyche.omnichat.sandbox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * JVM-level tests for the security-critical argv contract. These do not need
 * an Android device: [ProotCommand.build] is called with an explicit
 * `kernelRelease` so it never touches android.os.Os.
 */
class ProotCommandTest {

    @get:Rule
    val temp = TemporaryFolder()

    @Test
    fun `guest cwd accepts only the workspace`() {
        assertEquals("/workspace", ProotCommand.validateGuestCwd("/workspace"))
        assertEquals(
            "/workspace/lib",
            ProotCommand.validateGuestCwd("/workspace/lib"),
        )
        assertThrows { ProotCommand.validateGuestCwd("/etc") }
        assertThrows { ProotCommand.validateGuestCwd("/workspace/../etc") }
        assertThrows { ProotCommand.validateGuestCwd("workspace") }
        assertThrows { ProotCommand.validateGuestCwd("/workspace/\u0000x") }
    }

    @Test
    fun `binds reject duplicates and non-allowlisted guest roots`() {
        val host = temp.newFolder("workspace")
        ProotCommand.validateBinds(
            listOf(BindMount(host.absolutePath, "/workspace")),
        )
        assertThrows {
            ProotCommand.validateBinds(
                listOf(
                    BindMount(host.absolutePath, "/workspace"),
                    BindMount(host.absolutePath, "/workspace"),
                ),
            )
        }
        assertThrows {
            ProotCommand.validateBinds(
                listOf(BindMount(host.absolutePath, "/etc")),
            )
        }
    }

    @Test
    fun `command is one positional argument and env is wiped`() {
        val nativeDir = temp.newFolder("jni")
        val rootfs = temp.newFolder("rootfs")
        val tmp = temp.newFolder("tmp")
        val tallocDir = temp.newFolder("libs")
        File(nativeDir, ProotCommand.EXEC_LIB).writeText("")
        File(nativeDir, ProotCommand.LOADER_LIB).writeText("")
        File(tallocDir, ProotCommand.TALLOC_SONAME).writeText("")
        val hostWorkspace = temp.newFolder("workspace")

        val command = "echo \"a b\"; printf '%s\\n' ok"
        val launch = ProotCommand.build(
            nativeLibDir = nativeDir,
            rootfsDir = rootfs,
            tmpDir = tmp,
            procFakeFiles = emptyMap(),
            binds = listOf(BindMount(hostWorkspace.absolutePath, "/workspace")),
            cwd = "/workspace/sub",
            command = command,
            tallocDir = tallocDir,
            kernelRelease = null,
        )

        val argv = launch.argv
        assertTrue(argv.contains("--kill-on-exit"))
        assertTrue(argv.contains("-b"))
        assertTrue(
            argv.contains("${hostWorkspace.absolutePath}:/workspace"),
        )
        val envIndex = argv.indexOf("/usr/bin/env")
        assertTrue(envIndex > 0)
        assertEquals("-i", argv[envIndex + 1])
        val shellIndex = argv.indexOf("/bin/sh")
        assertEquals("-lc", argv[shellIndex + 1])
        assertEquals(ProotCommand.BASH_EVAL, argv[shellIndex + 2])
        assertEquals("omnichat", argv[shellIndex + 3])
        assertEquals("/workspace/sub", argv[shellIndex + 4])
        // The command is exactly one argv entry, even with quotes/metacharacters.
        assertEquals(command, argv[shellIndex + 5])
        assertEquals(argv.size - 1, argv.lastIndexOf(command))
        val libraryPath = launch.processEnv["LD_LIBRARY_PATH"]!!
            .split(File.pathSeparator)
        assertTrue(libraryPath.contains(tallocDir.absolutePath))
        assertTrue(libraryPath.contains(nativeDir.absolutePath))
    }

    private fun assertThrows(block: () -> Unit) {
        try {
            block()
        } catch (_: IllegalArgumentException) {
            return
        }
        throw AssertionError("expected IllegalArgumentException")
    }
}
