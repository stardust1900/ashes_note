package me.wangxuan.ashes_note

import android.content.res.Configuration
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var volumeEventSink: EventChannel.EventSink? = null
    private var volumeKeyPageTurnEnabled = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "volume_key_channel")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    volumeEventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    volumeEventSink = null
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "volume_key_config")
            .setMethodCallHandler { call, result ->
                if (call.method == "setEnabled") {
                    volumeKeyPageTurnEnabled = call.arguments as Boolean
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (!volumeKeyPageTurnEnabled) return super.onKeyDown(keyCode, event)
        return when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_DOWN -> { volumeEventSink?.success("down"); true }
            KeyEvent.KEYCODE_VOLUME_UP   -> { volumeEventSink?.success("up");   true }
            else -> super.onKeyDown(keyCode, event)
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
    }
}
