package com.nearlink.nearlink

import android.app.Activity
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

/**
 * E20-C3B. Native read-only frame sampling from a local video original.
 * A short JPEG is returned to Flutter for a display-only preview.
 * Never modifies the source, never exposes a content provider, no media upload.
 */
internal object NativeVideoFrameBridge {
    private const val CHANNEL = "linyue/video_thumbnail"
    private const val MAX_VIDEO_BYTES = 1024L * 1024L * 1024L
    private const val PREVIEW_MAX_DIMENSION = 360
    private const val PREVIEW_LIMIT_BYTES = 2 * 1024 * 1024
    private val workers = Executors.newFixedThreadPool(2)
    private val VIDEO_EXTENSIONS = setOf(
        "mp4", "m4v", "mov", "3gp", "3g2", "webm", "mkv", "avi", "wmv", "mpg", "mpeg"
    )

    fun register(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, reply ->
                if (call.method != "extractPreview") {
                    reply.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                if (path.isNullOrBlank() || path.indexOf('\u0000') >= 0) {
                    reply.success(null)
                    return@setMethodCallHandler
                }
                // Video decoding belongs off the Android UI thread.
                workers.execute {
                    val preview = try { extractPreview(path) } catch (_: Exception) { null }
                    activity.runOnUiThread { reply.success(preview) }
                }
            }
    }

    private fun extractPreview(path: String): ByteArray? {
        val source = File(path)
        val canonical = source.canonicalFile
        // Do not follow symlink aliases onto unrelated private files.
        if (canonical.absolutePath != source.absoluteFile.normalize().path) return null
        if (!canonical.isFile || !canonical.canRead()) return null
        if (canonical.length() <= 0L || canonical.length() > MAX_VIDEO_BYTES) return null
        if (canonical.extension.lowercase(Locale.ROOT) !in VIDEO_EXTENSIONS) return null
        val metadata = MediaMetadataRetriever()
        try {
            metadata.setDataSource(canonical.absolutePath)
            val durationMs = metadata.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            val targetMicros = if (durationMs > 0L) min(1000L, max(0L, durationMs / 3L)) * 1000L else 0L
            val frame = metadata.getFrameAtTime(
                targetMicros, MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            ) ?: metadata.getFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: return null
            try {
                val ratio = min(1.0, PREVIEW_MAX_DIMENSION.toDouble() / max(frame.width, frame.height))
                val outWidth = max(1, (frame.width * ratio).toInt())
                val outHeight = max(1, (frame.height * ratio).toInt())
                val resized = if (outWidth == frame.width && outHeight == frame.height) frame
                    else Bitmap.createScaledBitmap(frame, outWidth, outHeight, true)
                try {
                    val stream = ByteArrayOutputStream()
                    if (!resized.compress(Bitmap.CompressFormat.JPEG, 78, stream)) return null
                    val bytes = stream.toByteArray()
                    return if (bytes.isNotEmpty() && bytes.size <= PREVIEW_LIMIT_BYTES) bytes else null
                } finally {
                    if (resized !== frame) resized.recycle()
                }
            } finally {
                frame.recycle()
            }
        } finally {
            metadata.release()
        }
    }
}
