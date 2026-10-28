package com.cfx.framestudio.engine

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream

object ImageCropEngine {

    suspend fun loadBitmap(context: Context, uri: Uri): Bitmap? = withContext(Dispatchers.IO) {
        try {
            context.contentResolver.openInputStream(uri)?.use { stream ->
                BitmapFactory.decodeStream(stream)
            }
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    suspend fun cropBitmap(src: Bitmap, cropRect: Rect): Bitmap = withContext(Dispatchers.Default) {
        val safeLeft = cropRect.left.coerceIn(0, src.width - 1)
        val safeTop = cropRect.top.coerceIn(0, src.height - 1)
        val safeWidth = cropRect.width().coerceIn(1, src.width - safeLeft)
        val safeHeight = cropRect.height().coerceIn(1, src.height - safeTop)

        Bitmap.createBitmap(src, safeLeft, safeTop, safeWidth, safeHeight)
    }

    suspend fun saveCroppedImage(
        context: Context,
        bitmap: Bitmap,
        format: Bitmap.CompressFormat = Bitmap.CompressFormat.PNG
    ): Uri? = withContext(Dispatchers.IO) {
        val ext = if (format == Bitmap.CompressFormat.JPEG) "jpg" else "png"
        val mime = if (format == Bitmap.CompressFormat.JPEG) "image/jpeg" else "image/png"
        val filename = "CFX_Crop_${System.currentTimeMillis()}.$ext"

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, filename)
                    put(MediaStore.Images.Media.MIME_TYPE, mime)
                    put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/FrameStudio")
                }
                val uri = context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                if (uri != null) {
                    context.contentResolver.openOutputStream(uri)?.use { out ->
                        bitmap.compress(format, 100, out)
                    }
                }
                uri
            } else {
                val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "FrameStudio").apply {
                    if (!exists()) mkdirs()
                }
                val dest = File(dir, filename)
                FileOutputStream(dest).use { out ->
                    bitmap.compress(format, 100, out)
                }
                Uri.fromFile(dest)
            }
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }
}
