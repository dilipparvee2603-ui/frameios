package com.cfx.framestudio.engine

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream

data class VideoInfo(
    val uri: Uri,
    val title: String,
    val width: Int,
    val height: Int,
    val durationMs: Long,
    val fps: Float,
    val totalFrames: Long
)

object VideoEngine {

    suspend fun extractVideoInfo(context: Context, videoUri: Uri): VideoInfo = withContext(Dispatchers.IO) {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(context, videoUri)
            val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 1920
            val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 1080
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            val frameRateStr = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)
            } else null

            val fps = frameRateStr?.toFloatOrNull() ?: 30.0f
            val totalFrames = ((durationMs / 1000.0) * fps).toLong().coerceAtLeast(1L)

            // Swap width & height if portrait rotated
            val finalW = if (rotation == 90 || rotation == 270) height else width
            val finalH = if (rotation == 90 || rotation == 270) width else height

            val title = queryFileName(context, videoUri) ?: "Video"

            VideoInfo(
                uri = videoUri,
                title = title,
                width = finalW,
                height = finalH,
                durationMs = durationMs,
                fps = fps,
                totalFrames = totalFrames
            )
        } finally {
            retriever.release()
        }
    }

    suspend fun getFrameAt(context: Context, videoUri: Uri, timeUs: Long): Bitmap? = withContext(Dispatchers.IO) {
        val retriever = MediaMetadataRetriever()
        val pfd = try {
            context.contentResolver.openFileDescriptor(videoUri, "r")
        } catch (e: Exception) {
            null
        }

        try {
            if (pfd != null) {
                retriever.setDataSource(pfd.fileDescriptor)
            } else {
                retriever.setDataSource(context, videoUri)
            }

            retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
                ?: retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: retriever.getFrameAtTime(timeUs)
        } catch (e: Exception) {
            e.printStackTrace()
            null
        } finally {
            try {
                retriever.release()
            } catch (e: Exception) {}
            try {
                pfd?.close()
            } catch (e: Exception) {}
        }
    }

    suspend fun saveBitmapToGallery(
        context: Context,
        bitmap: Bitmap,
        baseName: String,
        format: Bitmap.CompressFormat = Bitmap.CompressFormat.PNG,
        quality: Int = 100
    ): Uri? = withContext(Dispatchers.IO) {
        val ext = when (format) {
            Bitmap.CompressFormat.JPEG -> "jpg"
            Bitmap.CompressFormat.PNG -> "png"
            else -> "webp"
        }
        val mimeType = when (format) {
            Bitmap.CompressFormat.JPEG -> "image/jpeg"
            Bitmap.CompressFormat.PNG -> "image/png"
            else -> "image/webp"
        }

        val filename = "${baseName}_${System.currentTimeMillis()}.$ext"
        var outputStream: OutputStream? = null
        var imageUri: Uri? = null

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val contentValues = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, filename)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/FrameStudio")
                }
                val resolver = context.contentResolver
                imageUri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, contentValues)
                if (imageUri != null) {
                    outputStream = resolver.openOutputStream(imageUri)
                }
            } else {
                val imagesDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
                val appDir = File(imagesDir, "FrameStudio").apply { if (!exists()) mkdirs() }
                val imageFile = File(appDir, filename)
                outputStream = FileOutputStream(imageFile)
                imageUri = Uri.fromFile(imageFile)
            }

            if (outputStream != null) {
                bitmap.compress(format, quality, outputStream)
            }
            imageUri
        } catch (e: Exception) {
            e.printStackTrace()
            null
        } finally {
            outputStream?.close()
        }
    }

    private fun queryFileName(context: Context, uri: Uri): String? {
        if (uri.scheme == "content") {
            val cursor = context.contentResolver.query(uri, null, null, null, null)
            cursor?.use {
                if (it.moveToFirst()) {
                    val index = it.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
                    if (index >= 0) return it.getString(index)
                }
            }
        }
        return uri.path?.let { File(it).name }
    }
}
