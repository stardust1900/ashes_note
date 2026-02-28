package me.wangxuan.ashes_note

import android.content.res.Configuration
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // Flutter 引擎会自动处理配置变化，这里不需要额外操作
    }
}
