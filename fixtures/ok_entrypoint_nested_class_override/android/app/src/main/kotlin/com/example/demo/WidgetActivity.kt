package com.example.demo

import io.flutter.embedding.android.FlutterActivity

class WidgetActivity : FlutterActivity() {
    class Helper {
        fun getDartEntrypointFunctionName(): String = "ghostMain"
    }
}
