package com.audiocalm.app

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.os.ParcelFileDescriptor
import android.content.Context
import java.io.InputStream
import com.ryanheise.audioservice.AudioServiceActivity
import android.view.KeyEvent
import android.app.Activity
import android.view.WindowManager

class MainActivity : AudioServiceActivity() {
    private val CHANNEL = "com.example.audio_series_app/file_access"
    private val EQUALIZER_CHANNEL = "com.example.audio_series_app/equalizer"
    private val MUSIC_SCANNER_CHANNEL = "com.example.audio_series_app/music_scanner"
    private val PICK_AUDIO_REQUEST = 1001
    private val fileDescriptors = mutableMapOf<String, ParcelFileDescriptor>()
    private var pendingResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        println("🎵 🔵 BLUETOOTH: MainActivity created - Bluetooth controls enabled")
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // --- FILE ACCESS CHANNEL ---
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            println("📱 Native Channel Call: ${call.method} | Args: ${call.arguments}")

            when (call.method) {
                "pickAudioFiles" -> {
                    pendingResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "audio/*"
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    }
                    try {
                        startActivityForResult(intent, PICK_AUDIO_REQUEST)
                    } catch (e: Exception) {
                        println("❌ Exception starting file picker: ${e.message}")
                        result.error("PICKER_ERROR", "Could not launch file picker: ${e.message}", e.localizedMessage)
                        pendingResult = null
                    }
                }
                "takePersistableUriPermission" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        try {
                            val uri = Uri.parse(uriString)
                            val existingPermissions = contentResolver.persistedUriPermissions
                            val hasPermission = existingPermissions.any {
                                it.uri == uri && it.isReadPermission
                            }
                            if (!hasPermission) {
                                contentResolver.takePersistableUriPermission(
                                    uri,
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                                )
                            }
                            result.success(true)
                        } catch (e: SecurityException) {
                            result.error("PERMISSION_ERROR", "Permission not grantable: ${e.message}", e.localizedMessage)
                        } catch (e: Exception) {
                            result.error("PERMISSION_ERROR", "Error taking permission: ${e.message}", e.localizedMessage)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "URI string is null", null)
                    }
                }
                "checkUriPermission" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        try {
                            val uri = Uri.parse(uriString)
                            val existingPermissions = contentResolver.persistedUriPermissions
                            val hasPersistedPermission = existingPermissions.any {
                                it.uri == uri && it.isReadPermission
                            }
                            result.success(hasPersistedPermission)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    } else {
                        result.success(false)
                    }
                }
                "getFileInfo" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        try {
                            val uri = Uri.parse(uriString)
                            val cursor = contentResolver.query(
                                uri,
                                arrayOf(DocumentsContract.Document.COLUMN_SIZE),
                                null, null, null
                            )
                            cursor?.use {
                                if (it.moveToFirst()) {
                                    val sizeIndex = it.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                                    val size = if (sizeIndex != -1 && !it.isNull(sizeIndex)) it.getLong(sizeIndex) else null
                                    result.success(mapOf("size" to size))
                                } else {
                                    result.success(mapOf<String, Any?>())
                                }
                            } ?: run {
                                try {
                                    val pfd = contentResolver.openFileDescriptor(uri, "r")
                                    val size = pfd?.statSize
                                    pfd?.close()
                                    result.success(mapOf("size" to size))
                                } catch (pfdError: Exception) {
                                    result.success(mapOf<String, Any?>())
                                }
                            }
                        } catch (e: Exception) {
                            result.error("FILE_INFO_ERROR", "Error getting file info: ${e.message}", e.localizedMessage)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "URI string is null", null)
                    }
                }
                "openFileDescriptor" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        try {
                            val uri = Uri.parse(uriString)
                            val hasPermission = contentResolver.persistedUriPermissions.any {
                                it.uri == uri && it.isReadPermission
                            }
                            if (!hasPermission) {
                                result.error("PERMISSION_ERROR", "No persisted read permission for URI: $uriString", null)
                                return@setMethodCallHandler
                            }
                            val pfd = contentResolver.openFileDescriptor(uri, "r")
                            if (pfd != null) {
                                fileDescriptors[uriString]?.close()
                                fileDescriptors.remove(uriString)
                                fileDescriptors[uriString] = pfd
                                result.success(pfd.fd)
                            } else {
                                result.error("FD_ERROR", "Could not open file descriptor", null)
                            }
                        } catch (e: SecurityException) {
                            result.error("PERMISSION_ERROR", "SecurityException: ${e.message}", e.localizedMessage)
                        } catch (e: Exception) {
                            result.error("FD_ERROR", "Error opening FD: ${e.message}", e.localizedMessage)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "URI string is null", null)
                    }
                }
                "closeFileDescriptor" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString != null) {
                        try {
                            val pfd = fileDescriptors.remove(uriString)
                            pfd?.close()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("CLOSE_ERROR", "Error closing FD: ${e.message}", e.localizedMessage)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "URI string is null", null)
                    }
                }
                "readUriChunk" -> {
                    val uriString = call.argument<String>("uri")
                    val offset = call.argument<Int>("offset") ?: 0
                    val length = call.argument<Int>("length") ?: (2 * 1024 * 1024)

                    if (uriString != null) {
                        var inputStream: InputStream? = null
                        try {
                            val uri = Uri.parse(uriString)
                            inputStream = contentResolver.openInputStream(uri)
                            if (inputStream == null) {
                                result.error("STREAM_ERROR", "Could not open input stream", null)
                                return@setMethodCallHandler
                            }
                            val skipped = inputStream.skip(offset.toLong())
                            if (skipped < offset.toLong()) {
                                result.success(ByteArray(0))
                                return@setMethodCallHandler
                            }
                            val buffer = ByteArray(length)
                            val bytesRead = inputStream.read(buffer, 0, length)
                            if (bytesRead > 0) {
                                result.success(buffer.copyOf(bytesRead))
                            } else {
                                result.success(ByteArray(0))
                            }
                        } catch (e: Exception) {
                            result.error("READ_ERROR", "Error reading chunk: ${e.message}", e.localizedMessage)
                        } finally {
                            try { inputStream?.close() } catch (_: Exception) {}
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "URI string is null", null)
                    }
                }
                else -> {
                    println("⚠️ Method ${call.method} not implemented")
                    result.notImplemented()
                }
            }
        }

        // --- EQUALIZER CHANNEL ---
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EQUALIZER_CHANNEL).setMethodCallHandler { call, result ->
            println("🎧 Equalizer Channel Call: ${call.method}")
            when (call.method) {
                "getAudioSessionId" -> {
                    println("🎧 Returning session ID 0 (output mix) for Equalizer")
                    result.success(0)
                }
                else -> EqualizerManager.handleMethodCall(call, result, this)
            }
        }

        // --- MUSIC SCANNER CHANNEL ---
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MUSIC_SCANNER_CHANNEL).setMethodCallHandler { call, result ->
            println("🎵 Music Scanner Channel Call: ${call.method}")
            when (call.method) {
                "scanAllMusic" -> {
                    try {
                        val musicFiles = scanForMusicFiles()
                        result.success(musicFiles)
                    } catch (e: Exception) {
                        result.error("SCAN_ERROR", "Failed to scan music: ${e.message}", e.localizedMessage)
                    }
                }
                "getAudioDuration" -> {
                    val filePath = call.argument<String>("path")
                    if (filePath != null) {
                        try {
                            val duration = getAudioFileDuration(filePath)
                            result.success(duration)
                        } catch (e: Exception) {
                            result.error("DURATION_ERROR", "Failed to get duration: ${e.message}", e.localizedMessage)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "File path is null", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    // --- MUSIC SCANNER HELPER METHODS ---
    private fun scanForMusicFiles(): List<Map<String, Any?>> {
        val musicFiles = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            android.provider.MediaStore.Audio.Media._ID,
            android.provider.MediaStore.Audio.Media.DISPLAY_NAME,
            android.provider.MediaStore.Audio.Media.DATA,
            android.provider.MediaStore.Audio.Media.TITLE,
            android.provider.MediaStore.Audio.Media.ARTIST,
            android.provider.MediaStore.Audio.Media.ALBUM,
            android.provider.MediaStore.Audio.Media.DURATION,
            android.provider.MediaStore.Audio.Media.SIZE,
            android.provider.MediaStore.Audio.Media.MIME_TYPE
        )
        val selection = "${android.provider.MediaStore.Audio.Media.IS_MUSIC} != 0"
        val sortOrder = "${android.provider.MediaStore.Audio.Media.DISPLAY_NAME} ASC"
        val query = this.contentResolver.query(
            android.provider.MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            projection, selection, null, sortOrder
        )
        query?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media._ID)
            val nameColumn = cursor.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.DISPLAY_NAME)
            val pathColumn = cursor.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.DATA)
            val titleColumn = cursor.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.TITLE)
            val artistColumn = cursor.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.ARTIST)
            val albumColumn = cursor.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.ALBUM)
            val durationColumn = cursor.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.DURATION)
            val sizeColumn = cursor.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.SIZE)
            val mimeColumn = cursor.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.MIME_TYPE)
            while (cursor.moveToNext()) {
                val mimeType = cursor.getString(mimeColumn)
                val size = cursor.getLong(sizeColumn)
                if (mimeType?.startsWith("audio/") == true && size > 0) {
                    musicFiles.add(mapOf(
                        "id" to cursor.getLong(idColumn),
                        "name" to cursor.getString(nameColumn),
                        "path" to cursor.getString(pathColumn),
                        "title" to (cursor.getString(titleColumn) ?: cursor.getString(nameColumn)),
                        "artist" to (cursor.getString(artistColumn) ?: "Unknown Artist"),
                        "album" to (cursor.getString(albumColumn) ?: "Unknown Album"),
                        "duration" to cursor.getLong(durationColumn),
                        "size" to size,
                        "mimeType" to mimeType
                    ))
                }
            }
        }
        println("✅ Scanned ${musicFiles.size} music files")
        return musicFiles
    }

    private fun getAudioFileDuration(filePath: String): Long {
        val retriever = android.media.MediaMetadataRetriever()
        return try {
            retriever.setDataSource(filePath)
            val duration = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)
            duration?.toLongOrNull() ?: 0L
        } catch (e: Exception) {
            0L
        } finally {
            try { retriever.release() } catch (_: Exception) {}
        }
    }

    // --- BLUETOOTH / MEDIA BUTTON HANDLING ---
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        println("🎵 🔵 BLUETOOTH: KeyDown keyCode=$keyCode")
        return when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_NEXT,
            KeyEvent.KEYCODE_MEDIA_PREVIOUS,
            KeyEvent.KEYCODE_MEDIA_STOP,
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD,
            KeyEvent.KEYCODE_MEDIA_REWIND,
            KeyEvent.KEYCODE_HEADSETHOOK -> {
                println("🎵 🔵 BLUETOOTH: Media key $keyCode → AudioService")
                super.onKeyDown(keyCode, event)
            }
            else -> super.onKeyDown(keyCode, event)
        }
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        println("🎵 🔵 BLUETOOTH: KeyUp keyCode=$keyCode")
        return when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_NEXT,
            KeyEvent.KEYCODE_MEDIA_PREVIOUS,
            KeyEvent.KEYCODE_MEDIA_STOP,
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD,
            KeyEvent.KEYCODE_MEDIA_REWIND,
            KeyEvent.KEYCODE_HEADSETHOOK -> {
                println("🎵 🔵 BLUETOOTH: Media key released $keyCode → AudioService")
                super.onKeyUp(keyCode, event)
            }
            else -> super.onKeyUp(keyCode, event)
        }
    }

    // --- FILE PICKER RESULT ---
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PICK_AUDIO_REQUEST && pendingResult != null) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                val uris = mutableListOf<String>()
                data.data?.let { uri ->
                    try {
                        contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        uris.add(uri.toString())
                    } catch (_: Exception) {}
                }
                data.clipData?.let { clipData ->
                    for (i in 0 until clipData.itemCount) {
                        val uri = clipData.getItemAt(i).uri
                        try {
                            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            uris.add(uri.toString())
                        } catch (_: Exception) {}
                    }
                }
                pendingResult?.success(uris)
            } else {
                pendingResult?.success(emptyList<String>())
            }
            pendingResult = null
        }
    }

    override fun onDestroy() {
        println("🧹 🔵 BLUETOOTH: MainActivity onDestroy")
        fileDescriptors.values.forEach { try { it.close() } catch (_: Exception) {} }
        fileDescriptors.clear()
        EqualizerManager.releaseAll()
        super.onDestroy()
    }
}
