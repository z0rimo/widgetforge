package com.example.demo

import io.flutter.embedding.android.FlutterActivity

import io.flutter.embedding.android.FlutterFragmentActivity

class PlainActivity : FlutterActivity()

class WidgetActivity : FlutterActivity() {
    override fun getDartEntrypointFunctionName(): String = "widgetMain"
}

class FragmentWidgetActivity : FlutterFragmentActivity() {
    override fun getDartEntrypointFunctionName(): String = "widgetMain"
}
