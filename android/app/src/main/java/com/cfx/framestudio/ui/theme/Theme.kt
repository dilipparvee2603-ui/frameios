package com.cfx.framestudio.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable

private val DarkColorScheme = darkColorScheme(
    primary = BrandAccent,
    onPrimary = TextPrimary,
    primaryContainer = ElevatedSurface,
    onPrimaryContainer = TextPrimary,
    secondary = GradientStart,
    onSecondary = TextPrimary,
    background = VoidCanvas,
    onBackground = TextPrimary,
    surface = SurfaceCard,
    onSurface = TextPrimary,
    surfaceVariant = ElevatedSurface,
    onSurfaceVariant = TextMuted
)

@Composable
fun FrameStudioTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = DarkColorScheme,
        content = content
    )
}
