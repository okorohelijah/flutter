package dev.securepaste.toolbardemo

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * An ordinary FlutterActivity. The only addition lets a test script choose the demo's switches
 * when it starts the app, for example:
 *
 *     adb shell am start -n dev.securepaste.toolbardemo/.MainActivity --es strategy B --es theme dark
 *
 * The Dart side (lib/main.dart) asks for these values once, at startup.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "proto/launch_config")
            .setMethodCallHandler { call, result ->
                if (call.method != "get") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val extras = intent?.extras
                val config = HashMap<String, Any?>()
                for (key in listOf("strategy", "theme", "locale")) {
                    extras?.getString(key)?.let { config[key] = it }
                }
                for (key in listOf("system_toolbar", "allow_paste_overflow")) {
                    if (extras?.containsKey(key) == true) {
                        config[key] = extras.getBoolean(key)
                    }
                }
                result.success(config)
            }
    }
}
