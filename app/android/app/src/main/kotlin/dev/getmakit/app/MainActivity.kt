package dev.getmakit.app

import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // `makit/device_info` → the device name (e.g. the user's set device
        // name, else manufacturer + model) for the pairing label. Read-only,
        // no third-party plugin (see SECURITY.md §5).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "makit/device_info")
            .setMethodCallHandler { call, result ->
                if (call.method == "name") {
                    val name = Settings.Global.getString(contentResolver, "device_name")
                        ?: "${Build.MANUFACTURER} ${Build.MODEL}"
                    result.success(name)
                } else {
                    result.notImplemented()
                }
            }
    }
}
