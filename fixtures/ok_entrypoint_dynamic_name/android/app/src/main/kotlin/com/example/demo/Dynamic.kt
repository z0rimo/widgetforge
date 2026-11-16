package com.example.demo

import io.flutter.embedding.android.FlutterActivity

class ConstActivity : FlutterActivity() {
    companion object { const val ENTRY = "ghostMain" }
    override fun getDartEntrypointFunctionName(): String = ENTRY
}

class LoggingActivity : FlutterActivity() {
    override fun getDartEntrypointFunctionName(): String {
        android.util.Log.d("widget", "choosing entrypoint")
        return "ghostMain"
    }
}
