package com.example.demo

import io.flutter.embedding.android.FlutterActivity

class WidgetActivity : FlutterActivity() {
    override fun getCachedEngineId(): String? = "warm"
    override fun getDartEntrypointFunctionName(): String = "ghostMain"
}
