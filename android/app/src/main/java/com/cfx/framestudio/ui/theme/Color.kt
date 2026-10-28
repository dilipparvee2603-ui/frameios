package com.cfx.framestudio.ui.theme

import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

// CFX Studio Glassmorphic Dark Tokens
val VoidCanvas = Color(0xFF0D0D11)
val SurfaceCard = Color(0xFF15151A)
val ElevatedSurface = Color(0xFF1A1A22)
val BorderHairline = Color(0x14FFFFFF) // 8% white
val BorderHairlineBright = Color(0x28FFFFFF) // 16% white

// Brand Crimson Accents
val BrandAccent = Color(0xFFC0000A)
val BrandVibrant = Color(0xFFE31B23)
val GradientStart = Color(0xFFFF4A3D)
val GradientEnd = Color(0xFFD92A20)

// Status Accents
val EmeraldAccent = Color(0xFF10B981)
val SkyAccent = Color(0xFF38BDF8)
val AmberAccent = Color(0xFFF59E0B)

// Typography Foregrounds
val TextPrimary = Color(0xFFF4F5F7)
val TextMuted = Color(0xFF94A3B8)
val TextTertiary = Color(0xFF64748B)

// Brand CTA Gradient
val BrandGradient = Brush.horizontalGradient(
    colors = listOf(GradientStart, GradientEnd)
)
val AmbientGlowGradient = Brush.radialGradient(
    colors = listOf(Color(0x20FF4A3D), Color.Transparent)
)
