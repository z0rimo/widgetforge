package com.example.demo

import io.flutter.embedding.android.FlutterActivity

class WidgetActivity : FlutterActivity() {
    override fun getDartEntrypointFunctionName(): String = "widgetMain"
    override fun getDartEntrypointLibraryUri(): String? = "package:other_pkg/entry.dart"
}
