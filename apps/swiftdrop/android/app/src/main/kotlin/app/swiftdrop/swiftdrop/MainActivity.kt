package app.swiftdrop.swiftdrop

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import android.os.Build
import android.view.HapticFeedbackConstants
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
                "haptic" -> result.success(haptic(call.argument<String>("effect")))
                "installApk" -> result.success(installApk(call.argument<String>("path")))
                "watchNetwork" -> {
                    nb.start()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Opens the downloaded APK in the system installer. Android asks the person once to
     * allow installs from SwiftDrop; until then this opens that settings page and says so.
     */
    private fun installApk(path: String?): String {
        if (path == null) return "unsupported"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            return "needsPermission"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", File(path))
        startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        return "started"
    }

    /** System CONFIRM / REJECT effects (Android 11+), tuned by each phone for its own motor. */
    private fun haptic(effect: String?): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        val c = when (effect) {
            "confirm" -> HapticFeedbackConstants.CONFIRM
            "reject" -> HapticFeedbackConstants.REJECT
            else -> return false
        }
        return window?.decorView?.performHapticFeedback(c) ?: false
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
