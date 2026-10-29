package com.psyche.omnichat

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Parcelable
import android.provider.OpenableColumns
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Copies incoming Android shares while the sender's temporary URI grants are
 * still valid, then hands the private copies to Flutter through a pending
 * `share.json` record. Flutter acknowledges a record once the attachments are
 * durable in its upload directory.
 */
internal class IncomingShareHandler(
    private val context: Context,
    private val onPendingShare: () -> Unit,
) {
    private val executor = Executors.newSingleThreadExecutor()
    private val root = File(context.filesDir, "incoming_shares")

    fun handleIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND &&
            intent?.action != Intent.ACTION_SEND_MULTIPLE
        ) return

        executor.execute {
            try {
                val uris = collectUris(intent)
                val text = extractText(intent)
                if (uris.isEmpty() && text.isEmpty()) return@execute

                val shareId = UUID.randomUUID().toString()
                val shareDir = File(root, shareId)
                if (!shareDir.mkdirs() && !shareDir.isDirectory) return@execute

                val files = JSONArray()
                var failedFiles = (uris.size - MAX_FILES).coerceAtLeast(0)
                var totalBytes = 0L
                uris.take(MAX_FILES).forEachIndexed { index, uri ->
                    val copied = try {
                        copyUri(uri, shareDir, index, totalBytes)
                    } catch (_: Exception) {
                        null
                    }
                    if (copied == null) {
                        failedFiles++
                    } else {
                        totalBytes += copied.size
                        files.put(
                            JSONObject()
                                .put("path", copied.file.absolutePath)
                                .put("fileName", copied.displayName)
                                .put("mime", mimeTypeFor(uri, intent.type)),
                        )
                    }
                }

                val record = JSONObject()
                    .put("id", shareId)
                    .put("text", text)
                    .put("files", files)
                    .put("failedFiles", failedFiles)
                val tempRecord = File(shareDir, "$RECORD_NAME.tmp")
                tempRecord.writeText(record.toString(), Charsets.UTF_8)
                if (!tempRecord.renameTo(File(shareDir, RECORD_NAME))) {
                    shareDir.deleteRecursively()
                    return@execute
                }
                onPendingShare()
            } catch (_: Exception) {
                // A malformed or revoked share must not crash the host activity.
            }
        }
    }

    fun getPendingShares(callback: (List<Map<String, Any>>) -> Unit) {
        executor.execute {
            val pending = try {
                root.listFiles()
                    .orEmpty()
                    .filter { it.isDirectory }
                    .sortedBy { it.lastModified() }
                    .mapNotNull(::readRecord)
            } catch (_: Exception) {
                emptyList()
            }
            callback(pending)
        }
    }

    fun acknowledge(shareId: String?, callback: (Boolean) -> Unit) {
        executor.execute {
            val id = shareId?.takeIf { UUID_REGEX.matches(it) }
            val deleted = if (id == null) {
                false
            } else {
                val directory = File(root, id)
                !directory.exists() || directory.deleteRecursively()
            }
            callback(deleted)
        }
    }

    fun close() {
        // Queued copies still finish so a share is never half-handed over.
        executor.shutdown()
    }

    private fun collectUris(intent: Intent): List<Uri> {
        val result = LinkedHashSet<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (uri != null) result.add(uri)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Parcelable>(Intent.EXTRA_STREAM)
                    ?.filterIsInstance<Uri>()
                    ?.forEach(result::add)
            }
        }
        intent.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                clip.getItemAt(index).uri?.let(result::add)
            }
        }
        return result.toList()
    }

    private fun extractText(intent: Intent): String {
        val extraText = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val clipText = if (extraText.isNullOrBlank()) intent.clipData?.firstText() else null
        return (extraText?.takeIf { it.isNotBlank() } ?: clipText ?: "").take(MAX_TEXT_CHARS)
    }

    private fun ClipData.firstText(): String? {
        for (index in 0 until itemCount) {
            getItemAt(index).text?.toString()?.takeIf { it.isNotBlank() }?.let { return it }
        }
        return null
    }

    /** Streams one granted URI into the share directory, removing any partial copy. */
    private fun copyUri(
        uri: Uri,
        destinationDirectory: File,
        index: Int,
        currentTotal: Long,
    ): CopiedShareFile? {
        // Only provider-granted content URIs. A `file://` URI would be read as
        // THIS app's uid, so an exported-activity caller could pull our private
        // files into a draft; senders on API 24+ cannot share file:// anyway.
        if (uri.scheme != "content") return null
        val name = safeFileName(
            displayName(uri) ?: uri.lastPathSegment?.let(Uri::decode) ?: "shared_file",
        )
        val destination = File(destinationDirectory, "$index-$name")
        var copiedBytes = 0L
        try {
            val input = context.contentResolver.openInputStream(uri) ?: return null
            input.use { source ->
                FileOutputStream(destination).use { output ->
                    val buffer = ByteArray(COPY_BUFFER_SIZE)
                    while (true) {
                        val count = source.read(buffer)
                        if (count < 0) break
                        copiedBytes += count
                        if (copiedBytes > MAX_FILE_BYTES ||
                            currentTotal + copiedBytes > MAX_TOTAL_BYTES
                        ) {
                            throw ShareSizeLimitException()
                        }
                        output.write(buffer, 0, count)
                    }
                    output.flush()
                }
            }
            // A provider that hands over zero bytes never produced a real file.
            if (copiedBytes == 0L) {
                destination.delete()
                return null
            }
            return CopiedShareFile(destination, name, copiedBytes)
        } catch (e: Exception) {
            destination.delete()
            throw e
        }
    }

    private fun displayName(uri: Uri): String? = try {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    cursor.getString(cursor.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME))
                } else {
                    null
                }
            }
    } catch (_: Exception) {
        null
    }

    private fun mimeTypeFor(uri: Uri, intentMime: String?): String {
        val resolved = try {
            context.contentResolver.getType(uri)
        } catch (_: Exception) {
            null
        }
        return resolved?.takeIf { it.isNotBlank() }
            ?: intentMime?.takeIf { it.isNotBlank() && !it.contains('*') }
            ?: "application/octet-stream"
    }

    private fun safeFileName(rawName: String): String {
        val cleaned = rawName
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .filter { it >= ' ' && it.code != 127 }
            .trim()
            .take(120)
        return if (cleaned.isEmpty() || cleaned == "." || cleaned == "..") {
            "shared_file"
        } else {
            cleaned
        }
    }

    private fun readRecord(directory: File): Map<String, Any>? {
        if (System.currentTimeMillis() - directory.lastModified() > MAX_PENDING_AGE_MS) {
            directory.deleteRecursively()
            return null
        }
        val recordFile = File(directory, RECORD_NAME)
        if (!recordFile.isFile) {
            // A directory without a completed record can never be imported.
            directory.deleteRecursively()
            return null
        }
        return try {
            val record = JSONObject(recordFile.readText(Charsets.UTF_8))
            val jsonFiles = record.optJSONArray("files") ?: JSONArray()
            val files = ArrayList<Map<String, String>>(jsonFiles.length())
            var dropped = 0
            for (index in 0 until jsonFiles.length()) {
                val item = jsonFiles.optJSONObject(index) ?: continue
                val file = File(item.optString("path"))
                if (!file.isFile || !isInside(directory, file)) {
                    dropped++
                    continue
                }
                files.add(
                    mapOf(
                        "path" to file.absolutePath,
                        "fileName" to item.optString("fileName"),
                        "mime" to item.optString("mime", "application/octet-stream"),
                    ),
                )
            }
            mapOf(
                "id" to record.optString("id"),
                "text" to record.optString("text"),
                "files" to files,
                "failedFiles" to record.optInt("failedFiles", 0) + dropped,
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun isInside(directory: File, file: File): Boolean = try {
        file.canonicalPath.startsWith(directory.canonicalPath + File.separator)
    } catch (_: Exception) {
        false
    }

    private data class CopiedShareFile(
        val file: File,
        val displayName: String,
        val size: Long,
    )

    private class ShareSizeLimitException : Exception()

    private companion object {
        const val RECORD_NAME = "share.json"
        const val MAX_FILES = 32
        const val MAX_TEXT_CHARS = 100_000
        const val MAX_FILE_BYTES = 20L * 1024 * 1024
        const val MAX_TOTAL_BYTES = 50L * 1024 * 1024
        const val COPY_BUFFER_SIZE = 64 * 1024
        const val MAX_PENDING_AGE_MS = 7L * 24 * 60 * 60 * 1000
        val UUID_REGEX = Regex("^[0-9a-fA-F-]{36}$")
    }
}
