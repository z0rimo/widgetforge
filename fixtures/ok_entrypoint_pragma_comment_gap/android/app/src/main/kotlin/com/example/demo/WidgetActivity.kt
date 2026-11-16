package com.example.demo

import io.flutter.embedding.android.FlutterActivity

class WidgetActivity : FlutterActivity() {
    override fun getDartEntrypointFunctionName(): String {
        return "widgetMain"
    }
}
