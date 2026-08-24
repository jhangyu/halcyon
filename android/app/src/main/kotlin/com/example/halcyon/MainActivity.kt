package com.example.halcyon

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException

// F-16 Open With delivery, mirrors macOS AppDelegate.swift's push-only
// pattern: native pushes an "openFile" call on halcyon/open_with, Dart's
// channel buffer holds it if OpenWithChannel.listen() hasn't registered yet
// (cold start). pendingPath covers the one gap buffers can't: an intent
// arriving before the FlutterEngine/channel exists at all.
//
// Path resolution: ACTION_VIEW on Android commonly hands us a content://
// URI, not a filesystem path -- uri.path is then an opaque provider-internal
// segment (e.g. /document/image:1234.jpg). resolveToFilePath() turns the
// intent into something dart:io can actually open: file:// URIs forward
// uri.path as-is, content:// URIs are streamed out of the ContentResolver and
// copied into the app's cacheDir (the Storage Access Framework exposes no real
// path, and no storage permission is declared or needed for cacheDir), and any
// other scheme is dropped silently. What is forwarded on halcyon/open_with is
// therefore always a path that exists.
//
// STILL PARKED: this does not complete the mobile Open With flow. The
// enclosing folder still cannot be scanned on Android (M6 matrix F-02), so
// Dart receives one readable file and shows a one-photo folder at best. See
// open_with_channel.dart's doc comment.
class MainActivity : FlutterActivity() {
    private val logTag = "Halcyon"
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
        val path = resolveToFilePath(uri)
        if (path.isNullOrEmpty()) return
        val channel = openWithChannel
        if (channel != null) {
            channel.invokeMethod("openFile", path)
        } else {
            pendingPath = path
        }
    }

    // Resolves an ACTION_VIEW uri to a path dart:io can open, or null if it
    // cannot be resolved (the intent is then dropped silently, as before).
    private fun resolveToFilePath(uri: Uri): String? {
        return when (uri.scheme) {
            ContentResolver.SCHEME_FILE -> uri.path?.takeIf { it.isNotEmpty() }
            ContentResolver.SCHEME_CONTENT -> copyContentToCache(uri)
            else -> null
        }
    }

    // The SAF gives no real path, so the provider stream is copied into
    // cacheDir -- app-private, needs no permission, and is reclaimable by the
    // system. The copy is overwritten on each open of the same display name.
    private fun copyContentToCache(uri: Uri): String? {
        val name = displayNameFor(uri) ?: uri.lastPathSegment ?: return null
        val safeName = name.substringAfterLast('/').substringAfterLast(':')
        if (safeName.isEmpty()) return null
        return try {
            val target = File(File(cacheDir, "open_with").apply { mkdirs() }, safeName)
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(target).use { output -> input.copyTo(output) }
            } ?: return null
            target.absolutePath
        } catch (e: IOException) {
            Log.w(logTag, "Open With: could not copy $uri into cacheDir", e)
            null
        } catch (e: SecurityException) {
            Log.w(logTag, "Open With: no read access to $uri", e)
            null
        }
    }

    private fun displayNameFor(uri: Uri): String? {
        return try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (column >= 0 && cursor.moveToFirst()) cursor.getString(column) else null
            }
        } catch (e: Exception) {
            Log.w(logTag, "Open With: DISPLAY_NAME query failed for $uri", e)
            null
        }
    }
}
