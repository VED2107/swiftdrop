package app.swiftdrop.swiftdrop

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * One channel to the platform layer: where received files are saved ([StorageBridge]) and
 * what the network looks like ([NetBridge]). The Dart side (apps/swiftdrop/lib/app/platform.dart)
 * relays the engine isolate's calls here.
 */
class MainActivity : FlutterActivity() {
    private lateinit var storage: StorageBridge
    private var net: NetBridge? = null
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        storage = StorageBridge(this)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.swiftdrop/platform")
        channel = ch
        val nb = NetBridge(applicationContext) { ch.invokeMethod("networkChanged", null) }
        net = nb
        ch.setMethodCallHandler { call, result ->
            if (storage.handle(call, result)) return@setMethodCallHandler
            when (call.method) {
                "interfaces" -> result.success(nb.interfaces())
                "watchNetwork" -> {
                    nb.start()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (::storage.isInitialized && storage.onActivityResult(requestCode, resultCode, data)) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        net?.stop()
        super.onDestroy()
    }
}
