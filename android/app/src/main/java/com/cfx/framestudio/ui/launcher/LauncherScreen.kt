package com.cfx.framestudio.ui.launcher

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.cfx.framestudio.ui.components.GlassCard
import com.cfx.framestudio.ui.theme.BrandAccent
import com.cfx.framestudio.ui.theme.BrandGradient
import com.cfx.framestudio.ui.theme.EmeraldAccent
import com.cfx.framestudio.ui.theme.TextMuted
import com.cfx.framestudio.ui.theme.TextPrimary
import com.cfx.framestudio.ui.theme.VoidCanvas

@Composable
fun LauncherScreen(
    onNavigateToExporter: () -> Unit,
    onNavigateToTrimmer: () -> Unit,
    onNavigateToCropper: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(VoidCanvas)
            .padding(horizontal = 20.dp, vertical = 12.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // Header
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column {
                Text(
                    text = "CFX STUDIO",
                    color = TextPrimary,
                    fontSize = 24.sp,
                    fontWeight = FontWeight.Black,
                    letterSpacing = 1.sp
                )
                Text(
                    text = "Professional Media Tools",
                    color = TextMuted,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium
                )
            }

            Box(
                modifier = Modifier
                    .background(BrandGradient, RoundedCornerShape(12.dp))
                    .padding(horizontal = 12.dp, vertical = 6.dp)
            ) {
                Text(
                    text = "60 FPS GPU",
                    color = Color.White,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold
                )
            }
        }

        Spacer(modifier = Modifier.height(8.dp))

        // Studio Card 1: Frame Exporter
        StudioCard(
            badge = "LOSSLESS CAPTURE",
            badgeColor = EmeraldAccent,
            icon = "🎞️",
            title = "Frame Exporter",
            description = "Extract exact video frames at original 4K resolution in lossless PNG, JPG, or WEBP with millisecond precision.",
            onClick = onNavigateToExporter
        )

        // Studio Card 2: Video Trimmer
        StudioCard(
            badge = "0s STREAM COPY",
            badgeColor = BrandAccent,
            icon = "✂️",
            title = "Video Trimmer",
            description = "High-speed stream copy cut with zero re-encoding and zero quality degradation. Mark in/out points effortlessly.",
            onClick = onNavigateToTrimmer
        )

        // Studio Card 3: Image Cropper
        StudioCard(
            badge = "PRECISION CROP",
            badgeColor = Color(0xFF38BDF8),
            icon = "📐",
            title = "Image Cropper",
            description = "Touch pinch-to-zoom cropping with locked aspect ratios (1:1, 16:9, 9:16, 4:5), rotation, and lossless export.",
            onClick = onNavigateToCropper
        )

        Spacer(modifier = Modifier.height(16.dp))

        // Footer status
        Box(
            modifier = Modifier.fillMaxWidth(),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = "Native Android Jetpack Compose • Hardware Accelerated",
                color = TextMuted.copy(alpha = 0.6f),
                fontSize = 11.sp
            )
        }
    }
}

@Composable
private fun StudioCard(
    badge: String,
    badgeColor: Color,
    icon: String,
    title: String,
    description: String,
    onClick: () -> Unit
) {
    GlassCard(
        modifier = Modifier.fillMaxWidth(),
        onClick = onClick
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = icon,
                    fontSize = 28.sp
                )
                Box(
                    modifier = Modifier
                        .background(badgeColor.copy(alpha = 0.15f), RoundedCornerShape(8.dp))
                        .padding(horizontal = 8.dp, vertical = 4.dp)
                ) {
                    Text(
                        text = badge,
                        color = badgeColor,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Black
                    )
                }
            }

            Text(
                text = title,
                color = TextPrimary,
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold
            )

            Text(
                text = description,
                color = TextMuted,
                fontSize = 13.sp,
                lineHeight = 18.sp
            )
        }
    }
}
