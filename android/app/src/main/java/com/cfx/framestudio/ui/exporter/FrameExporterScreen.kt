package com.cfx.framestudio.ui.exporter

import android.graphics.Bitmap
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.OptIn
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.ui.PlayerView
import com.cfx.framestudio.engine.VideoEngine
import com.cfx.framestudio.engine.VideoInfo
import com.cfx.framestudio.ui.components.GlassCard
import com.cfx.framestudio.ui.theme.BorderHairline
import com.cfx.framestudio.ui.theme.BrandAccent
import com.cfx.framestudio.ui.theme.BrandGradient
import com.cfx.framestudio.ui.theme.ElevatedSurface
import com.cfx.framestudio.ui.theme.EmeraldAccent
import com.cfx.framestudio.ui.theme.GradientStart
import com.cfx.framestudio.ui.theme.SurfaceCard
import com.cfx.framestudio.ui.theme.TextMuted
import com.cfx.framestudio.ui.theme.TextPrimary
import com.cfx.framestudio.ui.theme.VoidCanvas
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(UnstableApi::class)
@Composable
fun FrameExporterScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var videoUri by remember { mutableStateOf<Uri?>(null) }
    var videoInfo by remember { mutableStateOf<VideoInfo?>(null) }
    var isPlaying by remember { mutableStateOf(false) }
    var isScrubbing by remember { mutableStateOf(false) }
    var wasPlayingBeforeScrub by remember { mutableStateOf(false) }
    var currentPositionMs by remember { mutableLongStateOf(0L) }
    var previewBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var selectedFormat by remember { mutableStateOf(Bitmap.CompressFormat.PNG) }
    var isExporting by remember { mutableStateOf(false) }
    var isPlayerMuted by remember { mutableStateOf(false) }

    val exoPlayer = remember {
        ExoPlayer.Builder(context).build().apply {
            repeatMode = Player.REPEAT_MODE_OFF
            addListener(object : Player.Listener {
                override fun onIsPlayingChanged(playing: Boolean) {
                    isPlaying = playing
                }
                override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                    prepare()
                }
            })
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            exoPlayer.release()
        }
    }

    // Video Picker
    val videoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetContent()
    ) { uri: Uri? ->
        if (uri != null) {
            videoUri = uri
            scope.launch {
                val info = VideoEngine.extractVideoInfo(context, uri)
                videoInfo = info
                exoPlayer.setMediaItem(MediaItem.fromUri(uri))
                exoPlayer.prepare()
            }
        }
    }

    // Live position sync loop
    LaunchedEffect(isPlaying) {
        while (isPlaying) {
            if (!isScrubbing) {
                currentPositionMs = exoPlayer.currentPosition
            }
            delay(33L) // ~30 FPS UI update
        }
    }

    val togglePlayPause: () -> Unit = {
        if (isPlaying) {
            exoPlayer.pause()
        } else {
            if (exoPlayer.playbackState == Player.STATE_ENDED) {
                exoPlayer.seekTo(0)
                currentPositionMs = 0L
            } else if (exoPlayer.playbackState == Player.STATE_IDLE) {
                exoPlayer.prepare()
            }
            previewBitmap = null
            exoPlayer.play()
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(VoidCanvas)
            .padding(16.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        // Top Bar
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = TextPrimary
                )
            }
            Text(
                text = "FRAME EXPORTER",
                color = TextPrimary,
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold
            )
            IconButton(onClick = { videoPickerLauncher.launch("video/*") }) {
                Icon(
                    imageVector = Icons.Default.VideoLibrary,
                    contentDescription = "Select Video",
                    tint = GradientStart
                )
            }
        }

        // Video Viewport / Empty State
        if (videoUri == null) {
            GlassCard(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(16f / 9f),
                onClick = { videoPickerLauncher.launch("video/*") }
            ) {
                Column(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Icon(
                        imageVector = Icons.Default.VideoLibrary,
                        contentDescription = null,
                        tint = GradientStart,
                        modifier = Modifier.size(48.dp)
                    )
                    Spacer(modifier = Modifier.height(12.dp))
                    Text(
                        text = "Tap to Select Video",
                        color = TextPrimary,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Bold
                    )
                    Text(
                        text = "Supports 4K, 60fps MP4, MKV, MOV",
                        color = TextMuted,
                        fontSize = 12.sp
                    )
                }
            }
        } else {
            // Player Card
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(16f / 9f)
                    .clip(RoundedCornerShape(16.dp))
                    .background(Color.Black)
                    .clickable { togglePlayPause() }
            ) {
                AndroidView(
                    factory = { ctx ->
                        PlayerView(ctx).apply {
                            player = exoPlayer
                            useController = false
                            setShowBuffering(PlayerView.SHOW_BUFFERING_NEVER)
                        }
                    },
                    modifier = Modifier.fillMaxSize()
                )

                // Exact Frame Overlay when stepping while paused
                if (!isPlaying && previewBitmap != null) {
                    Image(
                        bitmap = previewBitmap!!.asImageBitmap(),
                        contentDescription = null,
                        modifier = Modifier.fillMaxSize(),
                        contentScale = ContentScale.Fit
                    )
                }

                // Mute / Unmute Button
                IconButton(
                    onClick = {
                        isPlayerMuted = !isPlayerMuted
                        exoPlayer.volume = if (isPlayerMuted) 0f else 1f
                    },
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .padding(10.dp)
                        .size(36.dp)
                        .background(Color(0xCC0D0D11), CircleShape)
                ) {
                    Icon(
                        imageVector = if (isPlayerMuted) Icons.Default.VolumeOff else Icons.Default.VolumeUp,
                        contentDescription = if (isPlayerMuted) "Unmute" else "Mute",
                        tint = if (isPlayerMuted) Color(0xFFFF5252) else Color.White,
                        modifier = Modifier.size(18.dp)
                    )
                }

                // Resolution Badge
                videoInfo?.let { info ->
                    Box(
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .padding(10.dp)
                            .background(Color(0xCC0D0D11), RoundedCornerShape(8.dp))
                            .padding(horizontal = 8.dp, vertical = 4.dp)
                    ) {
                        Text(
                            text = "${info.width} × ${info.height} • ${"%.1f".format(info.fps)} FPS",
                            color = EmeraldAccent,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
            }

            // Timeline Controls
            videoInfo?.let { info ->
                val duration = info.durationMs.coerceAtLeast(1L)
                val currentSec = currentPositionMs / 1000.0
                val totalSec = duration / 1000.0
                val frameIdx = (currentSec * info.fps).toLong().coerceIn(0L, info.totalFrames)

                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(SurfaceCard, RoundedCornerShape(16.dp))
                        .border(1.dp, BorderHairline, RoundedCornerShape(16.dp))
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    // Timecode display
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            text = "%02d:%02d.%03d / %02d:%02d.%03d".format(
                                (currentPositionMs / 60000),
                                (currentPositionMs % 60000) / 1000,
                                currentPositionMs % 1000,
                                (duration / 60000),
                                (duration % 60000) / 1000,
                                duration % 1000
                            ),
                            color = TextPrimary,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold
                        )
                        Text(
                            text = "Frame $frameIdx / ${info.totalFrames}",
                            color = TextMuted,
                            fontSize = 12.sp
                        )
                    }

                    // Scrubber Slider (Real-Time Live Scrubbing)
                    Slider(
                        value = currentPositionMs.toFloat().coerceIn(0f, duration.toFloat()),
                        onValueChange = { pos ->
                            if (isPlaying) {
                                wasPlayingBeforeScrub = true
                                exoPlayer.pause()
                            }
                            previewBitmap = null
                            isScrubbing = true
                            val targetMs = pos.toLong()
                            currentPositionMs = targetMs
                            exoPlayer.setSeekParameters(SeekParameters.CLOSEST_SYNC)
                            exoPlayer.seekTo(targetMs)
                        },
                        onValueChangeFinished = {
                            isScrubbing = false
                            exoPlayer.setSeekParameters(SeekParameters.EXACT)
                            exoPlayer.seekTo(currentPositionMs)
                            if (wasPlayingBeforeScrub) {
                                exoPlayer.play()
                                wasPlayingBeforeScrub = false
                            } else {
                                scope.launch {
                                    if (videoUri != null) {
                                        val bmp = VideoEngine.getFrameAt(context, videoUri!!, currentPositionMs * 1000L)
                                        if (bmp != null) {
                                            previewBitmap = bmp
                                        }
                                    }
                                }
                            }
                        },
                        valueRange = 0f..duration.toFloat(),
                        colors = SliderDefaults.colors(
                            thumbColor = BrandAccent,
                            activeTrackColor = GradientStart,
                            inactiveTrackColor = ElevatedSurface
                        )
                    )

                    // Step Frames Helper
                    val stepFrames: (Long) -> Unit = { delta ->
                        if (isPlaying) {
                            exoPlayer.pause()
                        }
                        val frameDurationMs = (1000.0 / info.fps.coerceAtLeast(1f))
                        val target = (currentPositionMs + (frameDurationMs * delta).toLong()).coerceIn(0L, duration)
                        currentPositionMs = target

                        exoPlayer.setSeekParameters(SeekParameters.EXACT)
                        exoPlayer.seekTo(target)

                        scope.launch {
                            if (videoUri != null) {
                                val bmp = VideoEngine.getFrameAt(context, videoUri!!, target * 1000L)
                                if (bmp != null) {
                                    previewBitmap = bmp
                                }
                            }
                        }
                    }

                    // Step Buttons
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceEvenly,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        StepButton("-10f") { stepFrames(-10L) }
                        StepButton("-1f") { stepFrames(-1L) }

                        // Play/Pause
                        Box(
                            modifier = Modifier
                                .size(48.dp)
                                .clip(CircleShape)
                                .background(BrandGradient)
                                .clickable { togglePlayPause() },
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                                contentDescription = null,
                                tint = Color.White
                            )
                        }

                        StepButton("+1f") { stepFrames(1L) }
                        StepButton("+10f") { stepFrames(10L) }

                        IconButton(onClick = {
                            isPlayerMuted = !isPlayerMuted
                            exoPlayer.volume = if (isPlayerMuted) 0f else 1f
                        }) {
                            Icon(
                                imageVector = if (isPlayerMuted) Icons.Default.VolumeOff else Icons.Default.VolumeUp,
                                contentDescription = "Toggle Mute",
                                tint = if (isPlayerMuted) Color(0xFFFF5252) else TextMuted
                            )
                        }
                    }
                }

                // Format Picker & Export Action
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    FormatPill("PNG", selectedFormat == Bitmap.CompressFormat.PNG) {
                        selectedFormat = Bitmap.CompressFormat.PNG
                    }
                    FormatPill("JPG", selectedFormat == Bitmap.CompressFormat.JPEG) {
                        selectedFormat = Bitmap.CompressFormat.JPEG
                    }
                    FormatPill("WEBP", selectedFormat == Bitmap.CompressFormat.WEBP) {
                        selectedFormat = Bitmap.CompressFormat.WEBP
                    }
                }

                Button(
                    onClick = {
                        if (isExporting || videoUri == null) return@Button
                        val info = videoInfo ?: return@Button
                        isExporting = true
                        scope.launch {
                            try {
                                val timeUs = currentPositionMs * 1000L
                                val bmp = VideoEngine.getFrameAt(context, videoUri!!, timeUs)
                                if (bmp != null) {
                                    val savedUri = VideoEngine.saveBitmapToGallery(
                                        context = context,
                                        bitmap = bmp,
                                        baseName = "Frame_${frameIdx}",
                                        format = selectedFormat
                                    )
                                    if (savedUri != null) {
                                        Toast.makeText(context, "✓ Frame saved at ${info.width}x${info.height}!", Toast.LENGTH_SHORT).show()
                                    } else {
                                        Toast.makeText(context, "Failed to save frame to Gallery", Toast.LENGTH_SHORT).show()
                                    }
                                } else {
                                    Toast.makeText(context, "Could not extract frame", Toast.LENGTH_SHORT).show()
                                }
                            } catch (e: Exception) {
                                e.printStackTrace()
                                Toast.makeText(context, "Export error: ${e.message}", Toast.LENGTH_SHORT).show()
                            } finally {
                                isExporting = false
                                // Re-prime ExoPlayer hardware decoder so playback never stalls
                                exoPlayer.setSeekParameters(SeekParameters.EXACT)
                                exoPlayer.seekTo(currentPositionMs)
                            }
                        }
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(50.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = BrandAccent),
                    shape = RoundedCornerShape(14.dp),
                    enabled = !isExporting
                ) {
                    Icon(imageVector = Icons.Default.FileDownload, contentDescription = null, tint = Color.White)
                    Spacer(modifier = Modifier.size(8.dp))
                    Text(
                        text = if (isExporting) "Saving Original Frame..." else "Save Frame at ${info.width} × ${info.height}",
                        color = Color.White,
                        fontWeight = FontWeight.Bold
                    )
                }
            }
        }
    }
}

@Composable
private fun StepButton(label: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .background(ElevatedSurface, RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp)
    ) {
        Text(
            text = label,
            color = TextPrimary,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold
        )
    }
}

@Composable
private fun FormatPill(label: String, isSelected: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .background(
                if (isSelected) BrandAccent.copy(alpha = 0.2f) else ElevatedSurface,
                RoundedCornerShape(10.dp)
            )
            .border(
                1.dp,
                if (isSelected) BrandAccent else BorderHairline,
                RoundedCornerShape(10.dp)
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp)
    ) {
        Text(
            text = label,
            color = if (isSelected) GradientStart else TextMuted,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold
        )
    }
}
