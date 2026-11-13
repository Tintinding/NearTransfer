package app.neartransfer.near_transfer

import android.app.Activity
import android.app.DownloadManager
import android.content.Intent
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val files by lazy { AndroidFiles(applicationContext) }
    private val storageWorker = Executors.newSingleThreadExecutor()
    private val readerWorker = Executors.newSingleThreadExecutor()
    private val closeWorker = Executors.newSingleThreadExecutor()
    private var picker: MethodChannel.Result? = null
    private val connectivity by lazy { getSystemService(ConnectivityManager::class.java) }
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var events: EventChannel.EventSink? = null
    private val addresses = mutableMapOf<Network, List<String>>()
    private var sentNetworkState: String? = null
    private var boundNetwork: Network? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "near_transfer/android").setMethodCallHandler { call, result ->
            fun text(key: String): String = requireNotNull(call.argument<String>(key))
            val method = call.method
            try {
                when (method) {
                    "info" -> result.success(mapOf(
                        "directory" to filesDir.absolutePath,
                        "name" to (Build.MODEL.ifBlank { "Android" }).take(30)
                    ))
                    "pick" -> pick(result)
                    "open" -> {
                        val uri = Uri.parse(text("uri"))
                        val intent = Intent(Intent.ACTION_VIEW)
                            .setDataAndType(uri, contentResolver.getType(uri) ?: "*/*")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        startActivity(intent)
                        result.success(null)
                    }
                    "downloads" -> {
                        startActivity(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS))
                        result.success(null)
                    }
                    "openRead", "read" -> work(readerWorker, result, "source_unreadable") {
                        if (method == "openRead") files.openRead(text("handle"), text("uri"))
                        else files.read(text("handle"))
                    }
                    "closeRead" -> work(closeWorker, result, "source_unreadable") {
                        files.closeRead(text("handle"))
                    }
                    "cleanup", "create", "write", "commit", "rollback", "retain" ->
                        work(storageWorker, result, "storage_failed") {
                            when (method) {
                                "cleanup" -> files.cleanup()
                                "create" -> files.create(text("name"), requireNotNull(call.argument<Number>("size")).toLong())
                                "write" -> files.write(text("handle"), requireNotNull(call.argument<ByteArray>("bytes")))
                                "commit" -> files.commit(text("handle"))
                                "retain" -> files.retain(call.argument<List<String>>("uris").orEmpty())
                                else -> files.rollback(text("handle"))
                            }
                        }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("cannot_open", null, null)
            }
        }
        EventChannel(messenger, "near_transfer/network").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                events = sink
                watchNetwork()
            }
            override fun onCancel(arguments: Any?) = stopWatching()
        })
    }

    private fun watchNetwork() {
        if (callback != null) return
        val listener = object : ConnectivityManager.NetworkCallback() {
            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
                runOnUiThread {
                    if (callback !== this) return@runOnUiThread
                    addresses[network] = linkProperties.linkAddresses
                        .filter { it.address is Inet4Address && !it.address.isLoopbackAddress }
                        .map { "${it.address.hostAddress}/${it.prefixLength}" }.sorted()
                    publishNetworkState()
                }
            }

            override fun onLost(network: Network) {
                runOnUiThread {
                    if (callback !== this) return@runOnUiThread
                    addresses.remove(network)
                    publishNetworkState()
                }
            }
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            .build()
        try {
            callback = listener
            connectivity.registerNetworkCallback(request, listener)
            publishNetworkState()
        } catch (_: SecurityException) {
            callback = null
            events?.error("network_permission", null, null)
        }
    }

    private fun publishNetworkState() {
        val usable = addresses.filterValues { it.isNotEmpty() }
        val selected = boundNetwork?.takeIf { usable.containsKey(it) }
            ?: connectivity.activeNetwork?.takeIf { usable.containsKey(it) }
            ?: usable.keys.firstOrNull()
        // Android may prefer cellular for Internet when Wi-Fi is a LAN-only
        // network. Dart sockets in this process must still use the local link.
        if (selected != boundNetwork) {
            try {
                if (!connectivity.bindProcessToNetwork(selected)) {
                    emitNetwork("")
                    return
                }
                boundNetwork = selected
            } catch (_: SecurityException) {
                events?.error("network_permission", null, null)
                return
            }
        }
        emitNetwork(selected?.let { "$it:${usable[it]!!.joinToString()}" }.orEmpty())
    }

    private fun emitNetwork(state: String) {
        if (state != sentNetworkState) {
            sentNetworkState = state
            events?.success(state)
        }
    }

    private fun stopWatching() {
        callback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        callback = null
        events = null
        addresses.clear()
        sentNetworkState = null
        if (boundNetwork != null) {
            runCatching { connectivity.bindProcessToNetwork(null) }
            boundNetwork = null
        }
    }

    private fun work(executor: ExecutorService, result: MethodChannel.Result, fallback: String, action: () -> Any?) {
        executor.execute {
            try {
                val value = action()
                result.success(if (value == Unit) null else value)
            } catch (error: Exception) {
                val code = if (error is BridgeFailure) error.code else fallback
                result.error(code, null, null)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun pick(result: MethodChannel.Result) {
        if (picker != null) {
            result.error("busy", null, null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            type = "*/*"
            addCategory(Intent.CATEGORY_OPENABLE)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            putExtra(Intent.EXTRA_LOCAL_ONLY, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, PICK_FILES)
        picker = result
    }

    @Deprecated("Used by the Android document picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_FILES) return
        val result = picker ?: return
        picker = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<Any>())
            return
        }
        val clips = data.clipData
        val count = clips?.itemCount ?: 1
        if (count > 128) {
            result.error("too_many_files", null, null)
            return
        }
        val uris = if (clips == null) listOfNotNull(data.data)
            else (0 until count).map { clips.getItemAt(it).uri }
        work(readerWorker, result, "source_unreadable") { files.describe(uris.distinct()) }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        stopWatching()
        picker?.error("source_unreadable", null, null)
        picker = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        closeWorker.execute { files.closeReaders() }
        storageWorker.execute { files.discardOpenFiles() }
        readerWorker.shutdown()
        closeWorker.shutdown()
        storageWorker.shutdown()
        super.onDestroy()
    }

    companion object {
        private const val PICK_FILES = 41
    }
}
