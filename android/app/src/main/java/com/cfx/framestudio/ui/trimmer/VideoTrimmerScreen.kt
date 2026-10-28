package com.cfx.framestudio.ui.trimmer

import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.OptIn
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Audiotrack
import androidx.compose.material.icons.filled.ContentCut
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.MusicOff
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
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
import com.cfx.framestudio.engine.VideoTrimEngine
import com.cfx.framestudio.ui.components.GlassCard
import com.cfx.framestudio.ui.theme.BorderHairline
import com.cfx.framestudio.ui.theme.BorderHairlineBright
import com.cfx.framestudio.ui.theme.BrandAccent
import com.cfx.framestudio.ui.theme.BrandGradient
import com.cfx.framestudio.ui.theme.ElevatedSurface
import com.cfx.framestudio.ui.theme.EmeraldAccent
import com.cfx.framestudio.ui.theme.GradientStart
import com.cfx.framestudio.ui.theme.SkyAccent
import com.cfx.framestudio.ui.theme.SurfaceCard
import com.cfx.framestudio.ui.theme.TextMuted
import com.cfx.framestudio.ui.theme.TextPrimary
import com.cfx.framestudio.ui.theme.VoidCanvas
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(UnstableApi::class)
@Composable
fun VideoTrimmerScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var videoUri by remember { mutableStateOf<Uri?>(null) }
    var videoInfo by remember { mutableStateOf<VideoInfo?>(null) }
    var isPlaying by remember { mutableStateOf(false) }
    var isScrubbing by remember { mutableStateOf(false) }
    var wasPlayingBeforeScrub by remember { mutableStateOf(false) }
    var currentPositionMs by remember { mutableLongStateOf(0L) }

    var inPointMs by remember { mutableLongStateOf(0L) }
    var outPointMs by remember { mutableLongStateOf(0L) }

    var isTrimming by remember { mutableStateOf(false) }
    var trimProgress by remember { mutableFloatStateOf(0f) }
    var isPlayerMuted by remember { mutableStateOf(false) }
    var includeAudioInExport by remember { mutableStateOf(true) }

    // Timecode Edit Dialog State
    var showTimecodeDialog by remember { mutableStateOf<TimecodeTarget?>(null) }
    var timecodeEditText by remember { mutableStateOf("") }
    var timecodeErrorMessage by remember { mutableStateOf<String?>(null) }

    val exoPlayer = remember {
        ExoPlayer.Builder(context).build().apply {
            repeatMode = Player.REPEAT_MODE_OFF
            addListener(object : Player.Listener {
                override fun onIsPlayingChanged(playing: Boolean) {
                    isPlaying = playing
                }
            })
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            exoPlayer.release()
        }
    }

    val videoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetContent()
    ) { uri: Uri? ->
        if (uri != null) {
            videoUri = uri
            scope.launch {
                val info = VideoEngine.extractVideoInfo(context, uri)
                videoInfo = info
                inPointMs = 0L
                outPointMs = info.durationMs
                currentPositionMs = 0L
                exoPlayer.setMediaItem(MediaItem.fromUri(uri))
                exoPlayer.prepare()
            }
        }
    }

    // Live position sync loop during active playback
    LaunchedEffect(isPlaying) {
        while (isPlaying) {
            if (!isScrubbing) {
                val pos = exoPlayer.currentPosition
                currentPositionMs = pos
                if (outPointMs > 0 && pos >= outPointMs) {
                    exoPlayer.seekTo(inPointMs)
                }
            }
            delay(33L)
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
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = TextPrimary)
            }
            Text("VIDEO TRIMMER STUDIO", color = TextPrimary, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            IconButton(onClick = { videoPickerLauncher.launch("video/*") }) {
                Icon(Icons.Default.VideoLibrary, contentDescription = "Select Video", tint = GradientStart)
            }
        }

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
                    Icon(Icons.Default.ContentCut, contentDescription = null, tint = GradientStart, modifier = Modifier.size(48.dp))
                    Spacer(modifier = Modifier.height(12.dp))
                    Text("Select Video to Trim", color = TextPrimary, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                    Text("Lossless stream copy with 0s re-encode", color = TextMuted, fontSize = 12.sp)
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

                // Mute / Unmute Button (Top-Start)
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

                videoInfo?.let { info ->
                    Box(
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .padding(10.dp)
                            .background(Color(0xCC0D0D11), RoundedCornerShape(8.dp))
                            .padding(horizontal = 8.dp, vertical = 4.dp)
                    ) {
                        Text(
                            text = "${info.width} × ${info.height} • Lossless",
                            color = EmeraldAccent,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
            }

            videoInfo?.let { info ->
                val duration = info.durationMs.coerceAtLeast(1L)
                val trimDurationSec = (outPointMs - inPointMs).coerceAtLeast(0L) / 1000.0

                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(SurfaceCard, RoundedCornerShape(16.dp))
                        .border(1.dp, BorderHairline, RoundedCornerShape(16.dp))
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    // Header Timecode + Real-Time Live Playhead
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .clickable {
                                    timecodeEditText = formatMsToTimecode(currentPositionMs)
                                    timecodeErrorMessage = null
                                    showTimecodeDialog = TimecodeTarget.PLAYHEAD
                                }
                                .padding(horizontal = 4.dp, vertical = 2.dp)
                        ) {
                            Text(
                                text = "⏱ " + formatMsToTimecode(currentPositionMs),
                                color = TextPrimary,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Bold
                            )
                            Spacer(modifier = Modifier.width(4.dp))
                            Icon(
                                imageVector = Icons.Default.Edit,
                                contentDescription = "Edit Timecode",
                                tint = SkyAccent,
                                modifier = Modifier.size(13.dp)
                            )
                        }

                        Text(
                            text = "Trim: ${"%.2f".format(trimDurationSec)}s",
                            color = EmeraldAccent,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }

                    // REALTIME LIVE SCRUBBING SLIDER
                    Slider(
                        value = currentPositionMs.toFloat().coerceIn(0f, duration.toFloat()),
                        onValueChange = { pos ->
                            if (isPlaying) {
                                wasPlayingBeforeScrub = true
                                exoPlayer.pause()
                            }
                            isScrubbing = true
                            val targetMs = pos.toLong()
                            currentPositionMs = targetMs

                            // Instant real-time video seeking while dragging
                            exoPlayer.setSeekParameters(SeekParameters.CLOSEST_SYNC)
                            exoPlayer.seekTo(targetMs)
                        },
                        onValueChangeFinished = {
                            isScrubbing = false
                            // Refine to exact frame upon releasing finger
                            exoPlayer.setSeekParameters(SeekParameters.EXACT)
                            exoPlayer.seekTo(currentPositionMs)
                            if (wasPlayingBeforeScrub) {
                                exoPlayer.play()
                                wasPlayingBeforeScrub = false
                            }
                        },
                        valueRange = 0f..duration.toFloat(),
                        colors = SliderDefaults.colors(
                            thumbColor = BrandAccent,
                            activeTrackColor = GradientStart,
                            inactiveTrackColor = ElevatedSurface
                        )
                    )

                    // TIMECODE ENTER / SET CARDS ROW (IN-POINT & OUT-POINT)
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        // IN-POINT CARD
                        TimecodeCard(
                            title = "In-Point [I]",
                            timeMs = inPointMs,
                            accentColor = SkyAccent,
                            modifier = Modifier.weight(1f),
                            onEditClick = {
                                timecodeEditText = formatMsToTimecode(inPointMs)
                                timecodeErrorMessage = null
                                showTimecodeDialog = TimecodeTarget.IN_POINT
                            },
                            onSetCurrentClick = {
                                inPointMs = exoPlayer.currentPosition
                                if (outPointMs < inPointMs) outPointMs = duration
                            }
                        )

                        // OUT-POINT CARD
                        TimecodeCard(
                            title = "Out-Point [O]",
                            timeMs = outPointMs,
                            accentColor = BrandAccent,
                            modifier = Modifier.weight(1f),
                            onEditClick = {
                                timecodeEditText = formatMsToTimecode(outPointMs)
                                timecodeErrorMessage = null
                                showTimecodeDialog = TimecodeTarget.OUT_POINT
                            },
                            onSetCurrentClick = {
                                outPointMs = exoPlayer.currentPosition
                                if (inPointMs > outPointMs) inPointMs = 0L
                            }
                        )
                    }

                    // PLAYBACK & JUMP CONTROLS ROW
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceEvenly,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        // Jump In
                        IconButton(onClick = {
                            exoPlayer.seekTo(inPointMs)
                            currentPositionMs = inPointMs
                        }) {
                            Icon(Icons.Default.FastRewind, contentDescription = "Jump In", tint = SkyAccent)
                        }

                        // Play/Pause Button
                        Box(
                            modifier = Modifier
                                .size(48.dp)
                                .clip(CircleShape)
                                .background(BrandGradient)
                                .clickable {
                                    if (isPlaying) exoPlayer.pause() else exoPlayer.play()
                                },
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                                contentDescription = null,
                                tint = Color.White
                            )
                        }

                        // Jump Out
                        IconButton(onClick = {
                            exoPlayer.seekTo(outPointMs)
                            currentPositionMs = outPointMs
                        }) {
                            Icon(Icons.Default.FastForward, contentDescription = "Jump Out", tint = BrandAccent)
                        }

                        // Mute/Unmute Player
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

                // Audio Export Settings Card
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(SurfaceCard)
                        .border(1.dp, BorderHairline, RoundedCornerShape(14.dp))
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(38.dp)
                                .clip(CircleShape)
                                .background(if (includeAudioInExport) Color(0x2010B981) else Color(0x20FF5252)),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = if (includeAudioInExport) Icons.Default.Audiotrack else Icons.Default.MusicOff,
                                contentDescription = null,
                                tint = if (includeAudioInExport) EmeraldAccent else Color(0xFFFF5252),
                                modifier = Modifier.size(20.dp)
                            )
                        }
                        Column {
                            Text(
                                text = if (includeAudioInExport) "Include Audio Track" else "Mute Audio on Export",
                                color = TextPrimary,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.Bold
                            )
                            Text(
                                text = if (includeAudioInExport) "Keep original sound in exported clip" else "Mute audio (silent video export)",
                                color = TextMuted,
                                fontSize = 11.sp
                            )
                        }
                    }
                    Switch(
                        checked = includeAudioInExport,
                        onCheckedChange = { includeAudioInExport = it },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Color.White,
                            checkedTrackColor = EmeraldAccent,
                            uncheckedThumbColor = TextMuted,
                            uncheckedTrackColor = ElevatedSurface
                        )
                    )
                }

                // Progress indicator during export
                if (isTrimming) {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        LinearProgressIndicator(
                            progress = { trimProgress },
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(8.dp)
                                .clip(RoundedCornerShape(4.dp)),
                            color = BrandAccent,
                            trackColor = ElevatedSurface
                        )
                        Text(
                            text = "Exporting trimmed clip: ${(trimProgress * 100).toInt()}%",
                            color = TextMuted,
                            fontSize = 11.sp
                        )
                    }
                }

                // Export Button
                Button(
                    onClick = {
                        if (isTrimming || videoUri == null) return@Button
                        isTrimming = true
                        trimProgress = 0f
                        scope.launch {
                            val result = VideoTrimEngine.trimVideoLossless(
                                context = context,
                                srcUri = videoUri!!,
                                startMs = inPointMs,
                                endMs = outPointMs,
                                includeAudio = includeAudioInExport,
                                onProgress = { p -> trimProgress = p }
                            )
                            isTrimming = false
                            if (result.success && result.outputUri != null) {
                                val msg = if (includeAudioInExport) "✓ Trimmed video saved to Gallery!" else "✓ Trimmed silent video saved to Gallery!"
                                Toast.makeText(context, msg, Toast.LENGTH_LONG).show()
                            } else {
                                val err = result.errorMessage ?: "Unknown error"
                                Toast.makeText(context, "Export Error: $err", Toast.LENGTH_LONG).show()
                            }
                        }
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(50.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = BrandAccent),
                    shape = RoundedCornerShape(14.dp),
                    enabled = !isTrimming
                ) {
                    Icon(imageVector = Icons.Default.ContentCut, contentDescription = null, tint = Color.White)
                    Spacer(modifier = Modifier.size(8.dp))
                    Text(
                        text = if (isTrimming) "Trimming & Exporting Video..." 
                               else if (!includeAudioInExport) "Export Muted Video Clip" 
                               else "Export Trimmed Video",
                        color = Color.White,
                        fontWeight = FontWeight.Bold
                    )
                }
            }
        }
    }

    // TIMECODE ENTRY DIALOG
    showTimecodeDialog?.let { target ->
        AlertDialog(
            onDismissRequest = { showTimecodeDialog = null },
            containerColor = SurfaceCard,
            shape = RoundedCornerShape(20.dp),
            title = {
                Text(
                    text = when (target) {
                        TimecodeTarget.IN_POINT -> "Set In-Point Timecode"
                        TimecodeTarget.OUT_POINT -> "Set Out-Point Timecode"
                        TimecodeTarget.PLAYHEAD -> "Jump to Timecode"
                    },
                    color = TextPrimary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold
                )
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        text = "Enter timecode (HH:MM:SS.mmm, MM:SS.mmm, or seconds)",
                        color = TextMuted,
                        fontSize = 12.sp
                    )

                    OutlinedTextField(
                        value = timecodeEditText,
                        onValueChange = {
                            timecodeEditText = it
                            timecodeErrorMessage = null
                        },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(
                            keyboardType = KeyboardType.Number,
                            imeAction = ImeAction.Done
                        ),
                        keyboardActions = KeyboardActions(onDone = {
                            applyTimecode(
                                target = target,
                                input = timecodeEditText,
                                durationMs = videoInfo?.durationMs ?: 0L,
                                currentPos = exoPlayer.currentPosition,
                                onInPoint = { inPointMs = it },
                                onOutPoint = { outPointMs = it },
                                onSeek = {
                                    exoPlayer.seekTo(it)
                                    currentPositionMs = it
                                },
                                onError = { timecodeErrorMessage = it },
                                onSuccess = { showTimecodeDialog = null }
                            )
                        }),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = GradientStart,
                            unfocusedBorderColor = BorderHairlineBright,
                            focusedTextColor = TextPrimary,
                            unfocusedTextColor = TextPrimary,
                            cursorColor = GradientStart
                        ),
                        modifier = Modifier.fillMaxWidth()
                    )

                    timecodeErrorMessage?.let { err ->
                        Text(text = err, color = Color(0xFFEF4444), fontSize = 11.sp)
                    }

                    // Quick Shortcut Chips
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .background(ElevatedSurface, RoundedCornerShape(8.dp))
                                .clickable {
                                    timecodeEditText = formatMsToTimecode(exoPlayer.currentPosition)
                                }
                                .padding(horizontal = 8.dp, vertical = 6.dp)
                        ) {
                            Text("Current Playhead", color = SkyAccent, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                        }

                        if (target == TimecodeTarget.IN_POINT) {
                            Box(
                                modifier = Modifier
                                    .background(ElevatedSurface, RoundedCornerShape(8.dp))
                                    .clickable { timecodeEditText = "00:00:00.000" }
                                    .padding(horizontal = 8.dp, vertical = 6.dp)
                            ) {
                                Text("00:00.000", color = TextMuted, fontSize = 11.sp)
                            }
                        } else if (target == TimecodeTarget.OUT_POINT && videoInfo != null) {
                            Box(
                                modifier = Modifier
                                    .background(ElevatedSurface, RoundedCornerShape(8.dp))
                                    .clickable { timecodeEditText = formatMsToTimecode(videoInfo!!.durationMs) }
                                    .padding(horizontal = 8.dp, vertical = 6.dp)
                            ) {
                                Text("End of Video", color = TextMuted, fontSize = 11.sp)
                            }
                        }
                    }
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        applyTimecode(
                            target = target,
                            input = timecodeEditText,
                            durationMs = videoInfo?.durationMs ?: 0L,
                            currentPos = exoPlayer.currentPosition,
                            onInPoint = { inPointMs = it },
                            onOutPoint = { outPointMs = it },
                            onSeek = {
                                exoPlayer.seekTo(it)
                                currentPositionMs = it
                            },
                            onError = { timecodeErrorMessage = it },
                            onSuccess = { showTimecodeDialog = null }
                        )
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = BrandAccent)
                ) {
                    Text("Apply", color = Color.White, fontWeight = FontWeight.Bold)
                }
            },
            dismissButton = {
                TextButton(onClick = { showTimecodeDialog = null }) {
                    Text("Cancel", color = TextMuted)
                }
            }
        )
    }
}

private enum class TimecodeTarget {
    IN_POINT,
    OUT_POINT,
    PLAYHEAD
}

@Composable
private fun TimecodeCard(
    title: String,
    timeMs: Long,
    accentColor: Color,
    modifier: Modifier = Modifier,
    onEditClick: () -> Unit,
    onSetCurrentClick: () -> Unit
) {
    Box(
        modifier = modifier
            .background(ElevatedSurface, RoundedCornerShape(12.dp))
            .border(1.dp, BorderHairline, RoundedCornerShape(12.dp))
            .padding(10.dp)
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(title, color = TextMuted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
                Icon(
                    imageVector = Icons.Default.Edit,
                    contentDescription = "Edit Timecode",
                    tint = accentColor,
                    modifier = Modifier
                        .size(16.dp)
                        .clickable(onClick = onEditClick)
                )
            }

            Text(
                text = formatMsToTimecode(timeMs),
                color = TextPrimary,
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.clickable(onClick = onEditClick)
            )

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(accentColor.copy(alpha = 0.15f), RoundedCornerShape(6.dp))
                    .clickable(onClick = onSetCurrentClick)
                    .padding(vertical = 4.dp),
                contentAlignment = Alignment.Center
            ) {
                Text("Set Here", color = accentColor, fontSize = 10.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

private fun applyTimecode(
    target: TimecodeTarget,
    input: String,
    durationMs: Long,
    currentPos: Long,
    onInPoint: (Long) -> Unit,
    onOutPoint: (Long) -> Unit,
    onSeek: (Long) -> Unit,
    onError: (String) -> Unit,
    onSuccess: () -> Unit
) {
    val ms = parseTimecodeToMs(input)
    if (ms == null) {
        onError("Invalid timecode format")
        return
    }
    if (ms < 0 || ms > durationMs) {
        onError("Timecode must be between 00:00.000 and ${formatMsToTimecode(durationMs)}")
        return
    }

    when (target) {
        TimecodeTarget.IN_POINT -> {
            onInPoint(ms)
            onSeek(ms)
        }
        TimecodeTarget.OUT_POINT -> {
            onOutPoint(ms)
            onSeek(ms)
        }
        TimecodeTarget.PLAYHEAD -> {
            onSeek(ms)
        }
    }
    onSuccess()
}

fun parseTimecodeToMs(input: String): Long? {
    val clean = input.trim()
    if (clean.isEmpty()) return null

    // 1. Seconds format: "83.5" or "45"
    if (clean.matches(Regex("^\\d+(\\.\\d+)?$"))) {
        val sec = clean.toDoubleOrNull() ?: return null
        return (sec * 1000.0).toLong()
    }

    // 2. Colon-delimited format: MM:SS.mmm or HH:MM:SS.mmm
    val parts = clean.split(":")
    return try {
        when (parts.size) {
            2 -> {
                val min = parts[0].toLong()
                val secParts = parts[1].split(".")
                val sec = secParts[0].toLong()
                val ms = if (secParts.size > 1) secParts[1].padEnd(3, '0').take(3).toLong() else 0L
                (min * 60 + sec) * 1000L + ms
            }
            3 -> {
                val hr = parts[0].toLong()
                val min = parts[1].toLong()
                val secParts = parts[2].split(".")
                val sec = secParts[0].toLong()
                val ms = if (secParts.size > 1) secParts[1].padEnd(3, '0').take(3).toLong() else 0L
                ((hr * 60 + min) * 60 + sec) * 1000L + ms
            }
            else -> null
        }
    } catch (e: Exception) {
        null
    }
}

fun formatMsToTimecode(ms: Long): String {
    val totalSec = ms / 1000
    val millis = ms % 1000
    val sec = totalSec % 60
    val min = (totalSec / 60) % 60
    val hr = totalSec / 3600
    return "%02d:%02d:%02d.%03d".format(hr, min, sec, millis)
}
