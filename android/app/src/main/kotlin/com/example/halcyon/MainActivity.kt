package com.example.halcyon

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// F-16 Open With delivery, mirrors macOS AppDelegate.swift's push-only
// pattern: native pushes an "openFile" call on halcyon/open_with, Dart's
// channel buffer holds it if OpenWithChannel.listen() hasn't registered yet
// (cold start). pendingPath covers the one gap buffers can't: an intent
// arriving before the FlutterEngine/channel exists at all.
//
// Path resolution note: ACTION_VIEW on Android commonly hands us a
// content:// URI, not a filesystem path. Resolving that to a real path (and
// the enclosing-folder access needed to act on it) is out of scope for this
// ticket -- see open_with_channel.dart doc comment and M6 matrix F-02/F-16.
// This only forwards file:// URIs' paths and content:// URIs' raw string
// form; the end-to-end mobile flow stays parked until folder-scan works on
// Android.
class MainActivity : FlutterActivity() {
    private val openWithChannelName = "halcyon/open_with"
    private var openWithChannel: MethodChannel? = null
    private var pendingPath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, openWithChannelName)
        openWithChannel = channel
        pendingPath?.let { path ->
            pendingPath = null
            channel.invokeMethod("openFile", path)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return
        val uri = intent.data ?: return
        val path = uri.path
        if (path.isNullOrEmpty()) return
        val channel = openWithChannel
        if (channel != null) {
            channel.invokeMethod("openFile", path)
        } else {
            pendingPath = path
        }
    }
}
