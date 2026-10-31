package com.nearlink.nearlink

import android.app.Activity
import android.content.Intent
import android.content.ActivityNotFoundException
import android.net.Uri
import android.provider.OpenableColumns
import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.UUID
import java.io.IOException
import java.io.BufferedInputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.Locale

/**
 * v0.1.1: Export an app-private received file via Android's system file picker
 * (Storage Access Framework). This does not request all-files access.
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "nearlink/files"
        private const val EXPORT_DOCUMENT_REQUEST = 46730
        private const val PICK_GALLERY_REQUEST = 46731
        private const val MAX_GALLERY_SELECTION = 50
        private const val MAX_GALLERY_MEDIA_BYTES = 1024L * 1024L * 1024L
    }

    private var pendingResult: MethodChannel.Result? = null
    private var bluetoothPoc: BluetoothPocBridge? = null
    private var pendingSource: File? = null
    private var pendingGalleryResult: MethodChannel.Result? = null
    private val activePublishedFiles = ConcurrentHashMap.newKeySet<String>()

    // E13: Only app-private received originals can be published to shared
    // media storage. Retain a best-effort persistent URI association so
    // repeated taps/automatic archive do not create duplicate user media.
    private fun verifiedReceivedSource(path: String?): File {
        if (path.isNullOrBlank()) throw IOException("未指定接收文件")
        val allowed = File(applicationInfo.dataDir, "app_flutter/NearLinkReceived").canonicalFile
        val source = File(path).canonicalFile
        if (source.parentFile != allowed || !source.isFile || !source.canRead() ||
            source.name.startsWith(".linyue_part_") || source.name.contains(".part.")) {
            throw IOException("只允许保存邻跃接收目录的普通文件")
        }
        return source
    }

    private fun saveKey(file: File): String {
        val basis = "${file.canonicalPath}|${file.length()}|${file.lastModified()}"
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(basis.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

    private fun alreadyPublished(source: File): String? {
        val prefs = getSharedPreferences("linyue_received_exports_v1", MODE_PRIVATE)
        val stored = prefs.getString(saveKey(source), null) ?: return null
        return try {
            val uri = Uri.parse(stored)
            contentResolver.openFileDescriptor(uri, "r")?.use {
                if (it.statSize == source.length()) return stored
            }
            null
        } catch (_: Exception) { null }
    }

    private fun rememberPublished(source: File, uri: Uri) {
        getSharedPreferences("linyue_received_exports_v1", MODE_PRIVATE)
            .edit().putString(saveKey(source), uri.toString()).commit()
    }

    override fun onDestroy() {
        bluetoothPoc?.dispose("activity-onDestroy")
        bluetoothPoc = null
        super.onDestroy()
    }

    override fun onPause() {
        bluetoothPoc?.noteLifecycle("activity-onPause")
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        bluetoothPoc?.noteLifecycle("activity-onResume")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if ((applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            bluetoothPoc?.dispose("engine-reconfigure")
            bluetoothPoc = BluetoothPocBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        }
        NativeVideoFrameBridge.register(this, flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "exportReceivedFile" -> {
                        if (pendingResult != null || pendingGalleryResult != null) {
                            result.error("BUSY", "请先完成当前文件保存操作", null)
                            return@setMethodCallHandler
                        }
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("BAD_PATH", "未指定需要保存的文件", null)
                            return@setMethodCallHandler
                        }
                        val source: File
                        try {
                            // Never grant the Dart UI a bridge to export an arbitrary path.
                            val expected = File(applicationInfo.dataDir,
                                "app_flutter/NearLinkReceived").canonicalFile
                            source = File(path).canonicalFile
                            if (source.parentFile != expected || !source.isFile) {
                                result.error("BAD_PATH", "仅允许导出邻传已接收的文件", null)
                                return@setMethodCallHandler
                            }
                        } catch (e: Exception) {
                            result.error("BAD_PATH", e.message, null)
                            return@setMethodCallHandler
                        }

                        pendingResult = result
                        pendingSource = source
                        val extension = source.extension.lowercase(Locale.ROOT)
                        val mime = MimeTypeMap.getSingleton()
                            .getMimeTypeFromExtension(extension) ?: "application/octet-stream"
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = mime
                            putExtra(Intent.EXTRA_TITLE, source.name)
                        }
                        try {
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, EXPORT_DOCUMENT_REQUEST)
                        } catch (e: Exception) {
                            pendingResult = null
                            pendingSource = null
                            result.error("NO_PICKER", e.message, null)
                        }
                    }
                    "commitBluetoothReceivedFile" -> {
                        val path=call.argument<String>("path")
                        val name=call.argument<String>("name")
                        val size=(call.argument<Number>("size"))?.toLong() ?: -1L
                        val sha=call.argument<String>("sha256")
                        Thread {
                            try {
                                val committed=BluetoothReceivedFileCommit.commit(this,path,name,size,sha,call.argument<String>("transferId"),call.argument<String>("commitNonce"),call.argument<Boolean>("verifyOnly") == true) { fields ->
                                    bluetoothPoc?.noteFileCommit(fields)
                                }
                                runOnUiThread { result.success(committed) }
                            } catch(e: Exception) {
                                val failure=e as? BluetoothReceivedFileCommit.CommitFailure
                                runOnUiThread { result.error("BT_FILE_COMMIT", failure?.friendly ?: "手机保存文件失败，请保留诊断。", failure?.diagnostic ?: mapOf("stage" to "android-dispatch", "exceptionType" to e.javaClass.name)) }
                            }
                        }.start()
                    }
                    "quickSaveReceivedDocument" -> {
                        // E13: one tap to Downloads/LinYue; never requests
                        // MANAGE_EXTERNAL_STORAGE or overwrites an existing item.
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                            result.error("UNSUPPORTED", "快捷保存需要 Android 10 或更高版本", null)
                            return@setMethodCallHandler
                        }
                        val source = try {
                            verifiedReceivedSource(call.argument<String>("path"))
                        } catch (e: Exception) {
                            result.error("BAD_PATH", e.message, null)
                            return@setMethodCallHandler
                        }
                        val ext = source.extension.lowercase(Locale.ROOT)
                        if (ext in setOf("jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif",
                            "mp4", "m4v", "mov", "3gp", "3g2", "webm", "mkv", "avi", "wmv", "mpg", "mpeg")) {
                            result.error("MEDIA", "图片和视频请使用相册保存方式", null)
                            return@setMethodCallHandler
                        }
                        if (!activePublishedFiles.add(source.path)) {
                            result.error("BUSY", "文件正在自动入相册或保存，请稍后重试", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            var newUri: Uri? = null
                            try {
                                val existing = alreadyPublished(source)
                                if (existing != null) {
                                    runOnUiThread { result.success("existing:$existing") }
                                    return@Thread
                                }
                                val size = source.length()
                                val mime = MimeTypeMap.getSingleton()
                                    .getMimeTypeFromExtension(ext) ?: "application/octet-stream"
                                val values = ContentValues().apply {
                                    put(MediaStore.MediaColumns.DISPLAY_NAME, source.name)
                                    put(MediaStore.MediaColumns.MIME_TYPE, mime)
                                    put(MediaStore.MediaColumns.RELATIVE_PATH,
                                        Environment.DIRECTORY_DOWNLOADS + "/LinYue")
                                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                                }
                                newUri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                                    ?: throw IOException("无法创建下载文件")
                                val written = contentResolver.openOutputStream(newUri!!, "w")?.use { output ->
                                    BufferedInputStream(FileInputStream(source)).use { input ->
                                        input.copyTo(output, bufferSize = 65536)
                                    }
                                } ?: throw IOException("无法写入系统下载目录")
                                if (written != size || source.length() != size) {
                                    throw IOException("导出长度校验失败")
                                }
                                val ready = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                                if (contentResolver.update(newUri!!, ready, null, null) <= 0) {
                                    throw IOException("下载文件提交失败")
                                }
                                rememberPublished(source, newUri!!)
                                val saved = newUri.toString()
                                runOnUiThread { result.success("saved:$saved") }
                            } catch (e: Exception) {
                                newUri?.let { try { contentResolver.delete(it, null, null) }
                                    catch (_: Exception) { } }
                                runOnUiThread { result.error("QUICK_SAVE_FAILED", e.message, null) }
                            } finally {
                                activePublishedFiles.remove(source.path)
                            }
                        }.start()
                    }
                    "pickFromDeviceGallery" -> {
                        if (pendingGalleryResult != null || pendingResult != null) {
                            result.error("BUSY", "请先完成当前系统文件选择操作", null)
                            return@setMethodCallHandler
                        }
                        pendingGalleryResult = result
                        // Ask Android for mixed gallery media rather than
                        // images only; handler UI depends on EMUI/system apps.
                        // Do not hard-code any vendor package name or request
                        // broad storage permissions.
                        // Using MediaStore.Files instead of Images removes
                        // the implicit image-only filter. Android/EMUI may
                        // choose different picker UIs for mixed media types.
                        val galleryIntent = Intent(Intent.ACTION_PICK,
                            MediaStore.Files.getContentUri("external")).apply {
                            type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES,
                                arrayOf("image/*", "video/*"))
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        try {
                            @Suppress("DEPRECATION")
                            startActivityForResult(galleryIntent, PICK_GALLERY_REQUEST)
                        } catch (_: ActivityNotFoundException) {
                            // No gallery handler; retain multi-select through
                            // the standard Android content selection UI.
                            val fallback = Intent(Intent.ACTION_GET_CONTENT).apply {
                                type = "*/*"
                                putExtra(Intent.EXTRA_MIME_TYPES,
                                    arrayOf("image/*", "video/*"))
                                addCategory(Intent.CATEGORY_OPENABLE)
                                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            try {
                                @Suppress("DEPRECATION")
                                startActivityForResult(fallback, PICK_GALLERY_REQUEST)
                            } catch (e: Exception) {
                                pendingGalleryResult = null
                                result.error("NO_GALLERY", e.message, null)
                            }
                        } catch (e: Exception) {
                            pendingGalleryResult = null
                            result.error("NO_GALLERY", e.message, null)
                        }
                    }
                    "archiveReceivedMedia" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("BAD_PATH", "没有可以保存的媒体文件", null)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                            result.error("UNSUPPORTED", "自动保存相册需要 Android 10 或更高版本", null)
                            return@setMethodCallHandler
                        }
                        // Bridge accepts ONLY files in the app-private received
                        // directory, not arbitrary paths from the Flutter layer.
                        val source: File
                        try {
                            val allowed = File(applicationInfo.dataDir,
                                "app_flutter/NearLinkReceived").canonicalFile
                            source = File(path).canonicalFile
                            if (source.parentFile != allowed || !source.isFile) {
                                result.error("BAD_PATH", "仅允许保存邻跃接收目录中的文件", null)
                                return@setMethodCallHandler
                            }
                            // Also reject incomplete internal paths at the native boundary.
                            verifiedReceivedSource(path)
                        } catch (e: Exception) {
                            result.error("BAD_PATH", e.message, null)
                            return@setMethodCallHandler
                        }

                        val ext = source.extension.lowercase(Locale.ROOT)
                        val imageMime = when (ext) {
                            "jpg", "jpeg" -> "image/jpeg"
                            "png" -> "image/png"
                            "gif" -> "image/gif"
                            "webp" -> "image/webp"
                            "heic" -> "image/heic"
                            "heif" -> "image/heif"
                            "bmp" -> "image/bmp"
                            else -> null
                        }
                        val videoMime = when (ext) {
                            "mp4", "m4v" -> "video/mp4"
                            "mov" -> "video/quicktime"
                            "3gp", "3g2" -> "video/3gpp"
                            "webm" -> "video/webm"
                            "mkv" -> "video/x-matroska"
                            "avi" -> "video/x-msvideo"
                            "wmv" -> "video/x-ms-wmv"
                            "mpg", "mpeg" -> "video/mpeg"
                            else -> null
                        }
                        if (imageMime == null && videoMime == null) {
                            result.error("NOT_MEDIA", "此文件不是支持的图片或视频格式", null)
                            return@setMethodCallHandler
                        }
                        val isVideo = videoMime != null
                        val mime = videoMime ?: imageMime!!
                        if (!activePublishedFiles.add(source.path)) {
                            result.error("BUSY", "文件正在保存，请稍后重试", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            var mediaUri: Uri? = null
                            try {
                                val existing = alreadyPublished(source)
                                if (existing != null) {
                                    runOnUiThread { result.success("existing:$existing") }
                                    return@Thread
                                }
                                val countExpected = source.length()
                                if (countExpected <= 0L || !source.isFile) {
                                    throw IOException("原始媒体文件已不存在或为空")
                                }
                                val values = ContentValues().apply {
                                    put(MediaStore.MediaColumns.DISPLAY_NAME, source.name)
                                    put(MediaStore.MediaColumns.MIME_TYPE, mime)
                                    put(MediaStore.MediaColumns.RELATIVE_PATH,
                                        (if (isVideo) Environment.DIRECTORY_MOVIES
                                         else Environment.DIRECTORY_PICTURES) + "/LinYue")
                                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                                }
                                // insert() creates a NEW media item: never
                                // edit or replace an existing user photo/video.
                                val target = if (isVideo)
                                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                                else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                                mediaUri = contentResolver.insert(target, values)
                                    ?: throw IOException("无法创建系统相册条目")
                                val stream = contentResolver.openOutputStream(mediaUri!!, "w")
                                    ?: throw IOException("无法写入系统相册")
                                val count = stream.use { output ->
                                    BufferedInputStream(FileInputStream(source)).use { input ->
                                        input.copyTo(output, bufferSize = 65536)
                                    }
                                }
                                if (count != countExpected || source.length() != countExpected) {
                                    throw IOException("媒体文件复制长度不一致，已取消入相册")
                                }
                                val ready = ContentValues().apply {
                                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                                }
                                if (contentResolver.update(mediaUri!!, ready, null, null) <= 0) {
                                    throw IOException("相册媒体条目提交失败")
                                }
                                rememberPublished(source, mediaUri!!)
                                val saved = mediaUri.toString()
                                runOnUiThread { result.success("saved:$saved") }
                            } catch (e: Exception) {
                                mediaUri?.let {
                                    try { contentResolver.delete(it, null, null) }
                                    catch (_: Exception) { /* best-effort rollback */ }
                                }
                                runOnUiThread { result.error("ALBUM_SAVE_FAILED", e.message, null) }
                            } finally {
                                activePublishedFiles.remove(source.path)
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun collectGalleryUris(data: Intent?): List<Uri> {
        if (data == null) return emptyList()
        val urls = linkedSetOf<Uri>()
        val items = data.clipData
        if (items != null) {
            for (i in 0 until items.itemCount) {
                items.getItemAt(i).uri?.let { urls.add(it) }
            }
        }
        data.data?.let { urls.add(it) }
        if (urls.size > MAX_GALLERY_SELECTION) {
            throw IOException("单次最多选择 $MAX_GALLERY_SELECTION 个媒体文件")
        }
        return urls.toList()
    }

    private fun galleryDisplayName(uri: Uri, mime: String): String {
        var original: String? = null
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME),
                null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) original = cursor.getString(index)
                }
            }
        } catch (_: Exception) { /* content providers may omit metadata */ }
        val cleaned = (original ?: "").substringAfterLast('/').substringAfterLast('\\')
            .replace(Regex("[\\/:*?\"<>|\\p{Cntrl}]"), "_")
            .trim().take(150)
        val imageNames = setOf("jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "bmp")
        val videoNames = setOf("mp4", "m4v", "mov", "3gp", "3g2", "webm",
            "mkv", "avi", "wmv", "mpg", "mpeg")
        val imageSuffix = mapOf(
            "image/jpeg" to "jpg", "image/jpg" to "jpg", "image/png" to "png",
            "image/webp" to "webp", "image/gif" to "gif",
            "image/heic" to "heic", "image/heif" to "heif",
            "image/bmp" to "bmp", "image/x-ms-bmp" to "bmp")
        val videoSuffix = mapOf(
            "video/mp4" to "mp4", "video/quicktime" to "mov",
            "video/3gpp" to "3gp", "video/3gpp2" to "3g2",
            "video/webm" to "webm", "video/x-matroska" to "mkv",
            "video/x-msvideo" to "avi", "video/x-ms-wmv" to "wmv",
            "video/mpeg" to "mpeg")
        val isImage = mime.startsWith("image/")
        val isVideo = mime.startsWith("video/")
        if (!isImage && !isVideo) {
            throw IOException("图库返回不支持的媒体类型：$mime")
        }
        val expectedNames = if (isImage) imageNames else videoNames
        val filenameSuffix = cleaned.substringAfterLast('.', "").lowercase(Locale.ROOT)
        // Prefer a supported original suffix, otherwise resolve a known MIME.
        val ext = if (filenameSuffix in expectedNames) filenameSuffix else
            (if (isImage) imageSuffix[mime] else videoSuffix[mime])
                ?: throw IOException("图库返回不支持的媒体格式：$mime")
        val safeBase = if (cleaned.isBlank() || cleaned == "." || cleaned == "..") {
            "gallery_${System.currentTimeMillis()}"
        } else {
            cleaned.substringBeforeLast('.', cleaned)
                .ifBlank { "gallery_${System.currentTimeMillis()}" }
        }
        return if (filenameSuffix in expectedNames && cleaned.isNotBlank()) {
            cleaned
        } else {
            "$safeBase.$ext"
        }
    }

    private fun importGallerySelection(uris: List<Uri>): List<String> {
        val root = File(cacheDir, "LinYueGalleryPicker")
        val created = mutableListOf<File>()
        try {
            val result = mutableListOf<String>()
            for (uri in uris) {
                val mime = contentResolver.getType(uri)
                    ?.lowercase(Locale.ROOT)
                if (mime == null ||
                    (!mime.startsWith("image/") && !mime.startsWith("video/"))) {
                    throw IOException("所选项目不是受支持的图片或视频")
                }
                val name = galleryDisplayName(uri, mime)
                val folder = File(root, UUID.randomUUID().toString())
                if (!folder.mkdirs()) throw IOException("无法创建图库临时目录")
                val file = File(folder, name)
                created.add(file)
                val input = contentResolver.openInputStream(uri)
                    ?: throw IOException("图库文件不可读取，请重新选择")
                var total = 0L
                input.use { source ->
                    FileOutputStream(file).use { output ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            val count = source.read(buffer)
                            if (count < 0) break
                            total += count
                            if (total > MAX_GALLERY_MEDIA_BYTES) {
                                throw IOException("单个媒体文件超过 1 GiB 限制")
                            }
                            output.write(buffer, 0, count)
                        }
                        output.fd.sync()
                    }
                }
                if (total == 0L) throw IOException("图库返回了空媒体文件")
                result.add(file.absolutePath)
            }
            return result
        } catch (e: Exception) {
            for (file in created) {
                try { file.delete() } catch (_: Exception) {}
                try { file.parentFile?.delete() } catch (_: Exception) {}
            }
            throw e
        }
    }

    @Deprecated("Uses Activity result for broad Flutter/Android API compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PICK_GALLERY_REQUEST) {
            val callback = pendingGalleryResult ?: return
            pendingGalleryResult = null
            if (resultCode != Activity.RESULT_OK) {
                callback.success(emptyList<String>())
                return
            }
            val uris = try { collectGalleryUris(data) } catch (e: Exception) {
                callback.error("GALLERY_SELECTION", e.message, null)
                return
            }
            if (uris.isEmpty()) {
                callback.success(emptyList<String>())
                return
            }
            Thread {
                try {
                    val paths = importGallerySelection(uris)
                    runOnUiThread { callback.success(paths) }
                } catch (e: Exception) {
                    runOnUiThread { callback.error("GALLERY_IMPORT", e.message, null) }
                }
            }.start()
            return
        }
        if (requestCode != EXPORT_DOCUMENT_REQUEST) return
        val callback = pendingResult ?: return
        val source = pendingSource
        pendingResult = null
        pendingSource = null

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || source == null) {
            callback.success(null)
            return
        }
        Thread {
            try {
                val stream = contentResolver.openOutputStream(uri, "w")
                    ?: throw IOException("无法打开所选保存位置")
                val bytesCopied = stream.use { output ->
                    FileInputStream(source).use { input ->
                        input.copyTo(output, bufferSize = 65536)
                    }
                }
                if (bytesCopied != source.length()) {
                    throw IOException("保存长度不一致，请检查目标文件")
                }
                runOnUiThread { callback.success(uri.toString()) }
            } catch (e: Exception) {
                runOnUiThread { callback.error("EXPORT_FAILED", e.message, null) }
            }
        }.start()
    }
}
