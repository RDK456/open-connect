package com.openconnect.app

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

// One Flutter engine for the whole process: swiping the app out of recents must not stop the file server.
// The foreground service keeps the process (and so this engine) alive; reopening reattaches the UI.
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        return cache.get("main") ?: FlutterEngine(context.applicationContext).also {
            GeneratedPluginRegistrant.registerWith(it) // FlutterActivity skips this for host-provided engines
            it.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            cache.put("main", it)
        }
    }

    override fun shouldDestroyEngineWithHost() = false
}
