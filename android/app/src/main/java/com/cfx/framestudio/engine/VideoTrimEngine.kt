package com.cfx.framestudio.engine

import android.content.ContentValues
import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import androidx.media3.common.MediaItem
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import kotlin.coroutines.resume

data class TrimResult(
    val success: Boolean,
    val outputUri: Uri? = null,
    val errorMessage: String? = null
)

object VideoTrimEngine {

    private const val TAG = "VideoTrimEngine"

    /**
     * Primary entry point for Video Trimming.
     * Tier 1: Attempts instant zero-loss direct stream copy if the container and audio
     * (e.g. AAC) are compatible with Android's native MediaMuxer.
     * Tier 2: Seamlessly falls back to Google's official Media3 Transformer if the audio
     * track uses Opus (standard on YouTube downloads), Vorbis, or non-standard container keys.
     */
    suspend fun trimVideoLossless(
        context: Context,
        srcUri: Uri,
        startMs: Long,
        endMs: Long,
        includeAudio: Boolean = true,
        onProgress: (Float) -> Unit
    ): TrimResult {
        // Check if video audio tracks are natively compatible with MediaMuxer MP4
        val compatibility = checkMuxerCompatibility(context, srcUri, includeAudio)

        if (compatibility.canUseFastMuxer) {
            try {
                Log.d(TAG, "Attempting high-speed stream-copy trim (includeAudio=$includeAudio)...")
                val fastResult = trimWithFastMuxer(context, srcUri, startMs, endMs, includeAudio, onProgress)
                if (fastResult.success) {
                    return fastResult
                }
                Log.w(TAG, "Fast muxer unsuccessful: ${fastResult.errorMessage}. Falling back to Media3 Transformer...")
            } catch (e: Exception) {
                Log.w(TAG, "Fast muxer exception: ${e.message}. Falling back to Media3 Transformer...", e)
            }
        } else {
            Log.d(TAG, "Audio codec '${compatibility.audioMime}' incompatible with native MediaMuxer. Routing directly to Media3 Transformer...")
        }

        // Tier 2: Media3 Transformer fallback (transcodes Opus/Vorbis -> AAC, clips exact frames, supports mute)
        return trimWithTransformer(context, srcUri, startMs, endMs, includeAudio, onProgress)
    }

    private data class CompatibilityInfo(
        val canUseFastMuxer: Boolean,
        val videoMime: String? = null,
        val audioMime: String? = null
    )

    private fun checkMuxerCompatibility(context: Context, srcUri: Uri, includeAudio: Boolean): CompatibilityInfo {
        val extractor = MediaExtractor()
        val pfd = try {
            context.contentResolver.openFileDescriptor(srcUri, "r")
        } catch (e: Exception) {
            null
        }

        return try {
            if (pfd != null) {
                extractor.setDataSource(pfd.fileDescriptor)
            } else {
                extractor.setDataSource(context, srcUri, null)
            }

            var videoMime: String? = null
            var audioMime: String? = null

            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("video/") && videoMime == null) {
                    videoMime = mime
                } else if (mime.startsWith("audio/") && audioMime == null) {
                    audioMime = mime
                }
            }

            if (videoMime == null) {
                return CompatibilityInfo(canUseFastMuxer = false)
            }

            // If audio is disabled by the user, we only stream-copy the video track! FastMuxer is 100% compatible.
            if (!includeAudio) {
                return CompatibilityInfo(canUseFastMuxer = true, videoMime = videoMime, audioMime = null)
            }

            // Android native MediaMuxer MP4 supports video (H.264, H.265, MPEG4)
            // AND ONLY audio (AAC, AMR-NB, AMR-WB).
            // Any Opus, Vorbis, MP3, AC-3 will throw "Failed to add track to muxer".
            val isAudioSupported = audioMime == null ||
                    audioMime.equals(MediaFormat.MIMETYPE_AUDIO_AAC, ignoreCase = true) ||
                    audioMime.equals("audio/mp4a-latm", ignoreCase = true) ||
                    audioMime.equals("audio/3gpp", ignoreCase = true) ||
                    audioMime.equals("audio/amr-wb", ignoreCase = true)

            CompatibilityInfo(
                canUseFastMuxer = isAudioSupported,
                videoMime = videoMime,
                audioMime = audioMime
            )
        } catch (e: Exception) {
            CompatibilityInfo(canUseFastMuxer = false)
        } finally {
            try { extractor.release() } catch (e: Exception) {}
            try { pfd?.close() } catch (e: Exception) {}
        }
    }

    /**
     * Tier 1: Instant stream-copy cut with Android native MediaExtractor and MediaMuxer.
     */
    private suspend fun trimWithFastMuxer(
        context: Context,
        srcUri: Uri,
        startMs: Long,
        endMs: Long,
        includeAudio: Boolean,
        onProgress: (Float) -> Unit
    ): TrimResult = withContext(Dispatchers.IO) {
        val startUs = (startMs * 1000L).coerceAtLeast(0L)
        val endUs = (endMs * 1000L).coerceAtLeast(startUs + 100_000L) // At least 100ms
        val durationUs = (endUs - startUs).coerceAtLeast(1L)

        val tempOutFile = File(context.cacheDir, "cfx_fast_trim_${System.currentTimeMillis()}.mp4")
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null

        val pfd = try {
            context.contentResolver.openFileDescriptor(srcUri, "r")
        } catch (e: Exception) {
            null
        }

        try {
            if (pfd != null) {
                extractor.setDataSource(pfd.fileDescriptor)
            } else {
                extractor.setDataSource(context, srcUri, null)
            }

            val trackCount = extractor.trackCount
            if (trackCount <= 0) {
                return@withContext TrimResult(false, null, "Could not read media tracks from source video")
            }

            muxer = MediaMuxer(tempOutFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

            val indexMap = HashMap<Int, Int>()
            var videoTrack = -1
            var audioTrack = -1
            var bufferSize = 2 * 1024 * 1024 // 2 MB buffer

            for (i in 0 until trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""

                if (mime.startsWith("video/") && videoTrack < 0) {
                    extractor.selectTrack(i)
                    val muxIndex = muxer.addTrack(format)
                    indexMap[i] = muxIndex
                    videoTrack = i
                    if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                        val sz = format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
                        if (sz > bufferSize) bufferSize = sz
                    }
                } else if (includeAudio && mime.startsWith("audio/") && audioTrack < 0) {
                    val isAac = mime.equals(MediaFormat.MIMETYPE_AUDIO_AAC, ignoreCase = true) ||
                            mime.equals("audio/mp4a-latm", ignoreCase = true) ||
                            mime.equals("audio/3gpp", ignoreCase = true) ||
                            mime.equals("audio/amr-wb", ignoreCase = true)

                    if (isAac) {
                        try {
                            extractor.selectTrack(i)
                            val muxIndex = muxer.addTrack(format)
                            indexMap[i] = muxIndex
                            audioTrack = i
                            if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                                val sz = format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
                                if (sz > bufferSize) bufferSize = sz
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "Audio track rejected by MediaMuxer: ${e.message}")
                            audioTrack = -1
                        }
                    }
                }
            }

            if (videoTrack < 0) {
                return@withContext TrimResult(false, null, "No supported video track found in file")
            }

            // Seek to start position at or before startUs keyframe
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            muxer.start()

            val buffer = ByteBuffer.allocateDirect(bufferSize)
            val bufferInfo = MediaCodec.BufferInfo()

            val lastPtsMap = HashMap<Int, Long>()
            val firstPtsMap = HashMap<Int, Long>()
            val trackFinished = HashMap<Int, Boolean>()

            var videoKeyFrameFound = false
            var samplesWritten = 0

            while (true) {
                val trackIndex = extractor.sampleTrackIndex
                if (trackIndex < 0) break

                val muxTrack = indexMap[trackIndex]
                if (muxTrack == null || trackFinished[trackIndex] == true) {
                    extractor.advance()
                    continue
                }

                bufferInfo.offset = 0
                bufferInfo.size = extractor.readSampleData(buffer, 0)
                if (bufferInfo.size < 0) break

                val sampleTime = extractor.sampleTime
                val flags = extractor.sampleFlags

                if (sampleTime > endUs) {
                    trackFinished[trackIndex] = true
                    val allDone = (trackFinished[videoTrack] == true) &&
                            (audioTrack < 0 || trackFinished[audioTrack] == true)
                    if (allDone) break
                    extractor.advance()
                    continue
                }

                val isKey = (flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0

                if (trackIndex == videoTrack) {
                    if (!videoKeyFrameFound) {
                        if (!isKey) {
                            extractor.advance()
                            continue
                        }
                        videoKeyFrameFound = true
                    }
                }

                if (!firstPtsMap.containsKey(trackIndex)) {
                    firstPtsMap[trackIndex] = sampleTime
                }
                val baseTime = firstPtsMap[trackIndex] ?: 0L
                var adjustedPts = (sampleTime - baseTime).coerceAtLeast(0L)

                val lastPts = lastPtsMap[muxTrack] ?: -1L
                if (adjustedPts <= lastPts) {
                    adjustedPts = lastPts + 1000L
                }
                lastPtsMap[muxTrack] = adjustedPts

                bufferInfo.presentationTimeUs = adjustedPts
                bufferInfo.flags = flags

                muxer.writeSampleData(muxTrack, buffer, bufferInfo)
                samplesWritten++

                if (trackIndex == videoTrack) {
                    val progress = ((sampleTime - startUs).toFloat() / durationUs).coerceIn(0f, 1f)
                    onProgress(progress)
                }

                extractor.advance()
            }

            if (samplesWritten == 0) {
                return@withContext TrimResult(false, null, "No samples written (verify selected range)")
            }

            muxer.stop()
            muxer.release()
            muxer = null

            val savedUri = saveToGallery(context, tempOutFile)
            if (savedUri != null) {
                TrimResult(true, savedUri, null)
            } else {
                TrimResult(false, null, "Failed to save trimmed video to Android Gallery")
            }
        } finally {
            try { extractor.release() } catch (e: Exception) {}
            try { muxer?.release() } catch (e: Exception) {}
            try { pfd?.close() } catch (e: Exception) {}
            if (tempOutFile.exists()) tempOutFile.delete()
        }
    }

    /**
     * Tier 2: Google Media3 Transformer engine.
     * Seamlessly handles all audio formats (Opus, Vorbis, PCM, MP3),
     * automatically transcodes non-standard audio to AAC, and ensures 100% compliant MP4.
     */
    private suspend fun trimWithTransformer(
        context: Context,
        srcUri: Uri,
        startMs: Long,
        endMs: Long,
        includeAudio: Boolean,
        onProgress: (Float) -> Unit
    ): TrimResult = withContext(Dispatchers.Main) {
        val tempOutFile = File(context.cacheDir, "cfx_trans_trim_${System.currentTimeMillis()}.mp4")

        val clippingConfig = MediaItem.ClippingConfiguration.Builder()
            .setStartPositionMs(startMs.coerceAtLeast(0L))
            .setEndPositionMs(endMs.coerceAtLeast(startMs + 100L))
            .build()

        val mediaItem = MediaItem.Builder()
            .setUri(srcUri)
            .setClippingConfiguration(clippingConfig)
            .build()

        val editedMediaItem = EditedMediaItem.Builder(mediaItem)
            .setRemoveAudio(!includeAudio)
            .build()

        suspendCancellableCoroutine { continuation ->
            var transformer: Transformer? = null
            var progressJob: Job? = null

            val listener = object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    progressJob?.cancel()
                    CoroutineScope(Dispatchers.IO).launch {
                        val savedUri = saveToGallery(context, tempOutFile)
                        if (tempOutFile.exists()) tempOutFile.delete()
                        if (savedUri != null) {
                            continuation.resume(TrimResult(true, savedUri, null))
                        } else {
                            continuation.resume(TrimResult(false, null, "Failed to save trimmed video to Android Gallery"))
                        }
                    }
                }

                override fun onError(
                    composition: Composition,
                    exportResult: ExportResult,
                    exportException: ExportException
                ) {
                    progressJob?.cancel()
                    if (tempOutFile.exists()) tempOutFile.delete()
                    continuation.resume(
                        TrimResult(
                            false,
                            null,
                            exportException.message ?: "Transformer export failed"
                        )
                    )
                }
            }

            try {
                val t = Transformer.Builder(context)
                    .addListener(listener)
                    .build()
                transformer = t

                t.start(editedMediaItem, tempOutFile.absolutePath)

                // Progress polling loop
                val progressHolder = ProgressHolder()
                progressJob = CoroutineScope(Dispatchers.Main).launch {
                    while (isActive) {
                        delay(120)
                        val state = t.getProgress(progressHolder)
                        if (state == Transformer.PROGRESS_STATE_AVAILABLE) {
                            onProgress(progressHolder.progress / 100f)
                        }
                    }
                }
            } catch (e: Exception) {
                progressJob?.cancel()
                if (tempOutFile.exists()) tempOutFile.delete()
                continuation.resume(TrimResult(false, null, e.localizedMessage ?: "Failed to initialize video exporter"))
            }

            continuation.invokeOnCancellation {
                progressJob?.cancel()
                transformer?.cancel()
                if (tempOutFile.exists()) tempOutFile.delete()
            }
        }
    }

    private fun saveToGallery(context: Context, srcFile: File): Uri? {
        val filename = "CFX_Trim_${System.currentTimeMillis()}.mp4"
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Video.Media.DISPLAY_NAME, filename)
                    put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                    put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/FrameStudio")
                    put(MediaStore.Video.Media.IS_PENDING, 1)
                }
                val resolver = context.contentResolver
                val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
                if (uri != null) {
                    resolver.openOutputStream(uri)?.use { out ->
                        FileInputStream(srcFile).use { input -> input.copyTo(out) }
                    }
                    values.clear()
                    values.put(MediaStore.Video.Media.IS_PENDING, 0)
                    resolver.update(uri, values, null, null)
                }
                uri
            } else {
                val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES), "FrameStudio").apply {
                    if (!exists()) mkdirs()
                }
                val dest = File(dir, filename)
                srcFile.copyTo(dest, overwrite = true)
                Uri.fromFile(dest)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error saving to gallery: ${e.message}", e)
            null
        }
    }
}
