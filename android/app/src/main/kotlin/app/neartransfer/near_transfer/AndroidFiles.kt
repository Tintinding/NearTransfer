package app.neartransfer.near_transfer

import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.os.StatFs
import android.provider.MediaStore
import android.provider.MediaStore.MediaColumns
import android.provider.OpenableColumns
import android.system.ErrnoException
import android.system.OsConstants
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

internal class BridgeFailure(val code: String) : Exception(code)

internal class AndroidFiles(private val context: Context) {
    private val resolver = context.contentResolver
    private val downloads = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    private val preferences = context.getSharedPreferences("receive_journal", Context.MODE_PRIVATE)
    private val readers = ConcurrentHashMap<String, Reader>()
    private val writers = mutableMapOf<String, Download>()

    private class Reader {
        val signal = CancellationSignal()
        @Volatile var input: InputStream? = null
    }
    private data class Download(val uri: Uri, val name: String, val stream: FileOutputStream)

    fun describe(uris: List<Uri>): List<Map<String, Any>> {
        val descriptions = uris.map { uri ->
            require(uri.scheme == "content")
            val projection = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
            resolver.query(uri, projection, null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) throw BridgeFailure("source_unreadable")
                val name = cursor.getString(0)
                if (name.isNullOrBlank() || cursor.isNull(1)) throw BridgeFailure("unknown_size")
                val size = cursor.getLong(1)
                if (size < 0) throw BridgeFailure("unknown_size")
                mapOf("uri" to uri.toString(), "name" to name, "size" to size)
            } ?: throw BridgeFailure("source_unreadable")
        }
        for (uri in uris) {
            // Some providers only issue a temporary grant. The current
            // transfer still works, but may require reselecting after restart.
            runCatching { resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        }
        return descriptions
    }

    fun retain(uris: List<String>) {
        val retained = uris.toSet()
        for (grant in resolver.persistedUriPermissions) {
            if (grant.isReadPermission && grant.uri.toString() !in retained) {
                runCatching { resolver.releasePersistableUriPermission(grant.uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
            }
        }
    }

    fun openRead(handle: String, uri: String) {
        val entry = Reader()
        require(readers.putIfAbsent(handle, entry) == null)
        try {
            val descriptor = resolver.openAssetFileDescriptor(Uri.parse(uri), "r", entry.signal)
                ?: throw BridgeFailure("source_unreadable")
            val input = try {
                descriptor.createInputStream()
            } catch (error: Exception) {
                descriptor.close()
                throw error
            }
            entry.input = input
            if (readers[handle] !== entry) input.close()
        } catch (error: Exception) {
            closeRead(handle)
            throw error
        }
    }

    fun read(handle: String): ByteArray {
        val input = readers[handle]?.input ?: throw BridgeFailure("source_unreadable")
        val bytes = ByteArray(128 * 1024)
        val count = input.read(bytes)
        return if (count < 0) ByteArray(0) else if (count == bytes.size) bytes else bytes.copyOf(count)
    }

    fun closeRead(handle: String) {
        val entry = readers.remove(handle) ?: return
        entry.signal.cancel()
        entry.input?.close()
    }

    fun closeReaders() = readers.keys.forEach { runCatching { closeRead(it) } }

    fun create(name: String, size: Long): String {
        require(name.isNotBlank() && '/' !in name && '\\' !in name)
        if (StatFs(Environment.getExternalStorageDirectory().path).availableBytes < size) {
            throw BridgeFailure("no_space")
        }
        val handle = UUID.randomUUID().toString()
        val values = ContentValues().apply {
            put(MediaColumns.DISPLAY_NAME, name)
            put(MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/")
            put(MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(downloads, values) ?: throw BridgeFailure("storage_failed")
        try {
            // Persist synchronously before accepting bytes.
            check(preferences.edit().putString(handle, uri.toString()).commit())
            val fd = resolver.openFileDescriptor(uri, "w") ?: throw BridgeFailure("storage_failed")
            writers[handle] = Download(uri, name, ParcelFileDescriptor.AutoCloseOutputStream(fd))
            return handle
        } catch (error: Exception) {
            runCatching { deleteIfPending(uri) }.onSuccess { preferences.edit().remove(handle).apply() }
            throw error
        }
    }

    fun write(handle: String, bytes: ByteArray) {
        require(bytes.size <= 128 * 1024)
        val download = writers[handle] ?: throw BridgeFailure("storage_failed")
        try {
            download.stream.write(bytes)
        } catch (error: IOException) {
            if (generateSequence<Throwable>(error) { it.cause }
                    .any { it is ErrnoException && it.errno == OsConstants.ENOSPC }) {
                throw BridgeFailure("no_space")
            }
            throw error
        }
    }

    fun commit(handle: String): Map<String, String> {
        val download = writers[handle] ?: throw BridgeFailure("storage_failed")
        download.stream.fd.sync()
        download.stream.close()
        // MediaStore chooses a unique filesystem path during publication, even
        // for files owned by another app that we cannot enumerate.
        val updated = resolver.update(download.uri, ContentValues().apply {
            put(MediaColumns.IS_PENDING, 0)
        }, null, null)
        check(updated == 1)
        writers.remove(handle)
        preferences.edit().remove(handle).apply()
        val name = runCatching {
            resolver.query(download.uri, arrayOf(MediaColumns.DISPLAY_NAME), null, null, null)
                ?.use { if (it.moveToFirst()) it.getString(0) else null }
        }.getOrNull() ?: download.name
        return mapOf("uri" to download.uri.toString(), "name" to name)
    }

    fun rollback(handle: String) {
        val download = writers.remove(handle)
        runCatching { download?.stream?.close() }
        val uri = download?.uri ?: preferences.getString(handle, null)?.let(Uri::parse)
        if (uri != null) deleteIfPending(uri)
        preferences.edit().remove(handle).apply()
    }

    fun discardOpenFiles() = writers.keys.toList().forEach { runCatching { rollback(it) } }

    @Suppress("DEPRECATION")
    private fun deleteIfPending(uri: Uri) {
        resolver.delete(MediaStore.setIncludePending(uri), "${MediaColumns.IS_PENDING}=1", null)
    }

    @Suppress("DEPRECATION")
    fun cleanup() {
        for (handle in preferences.all.keys) rollback(handle)
        // Cover process death between MediaStore.insert and journaling its URI.
        val projection = arrayOf(MediaColumns._ID)
        val selection = "${MediaColumns.IS_PENDING}=1 AND ${MediaColumns.OWNER_PACKAGE_NAME}=?"
        val arguments = arrayOf(context.packageName)
        val cursor = if (Build.VERSION.SDK_INT >= 30) {
            resolver.query(downloads, projection, Bundle().apply {
                putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_ONLY)
                putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
                putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, arguments)
            }, null)
        } else {
            resolver.query(MediaStore.setIncludePending(downloads), projection, selection, arguments, null)
        }
        val orphaned = mutableListOf<Uri>()
        cursor?.use { while (it.moveToNext()) orphaned += ContentUris.withAppendedId(downloads, it.getLong(0)) }
        orphaned.forEach(::deleteIfPending)
    }
}
