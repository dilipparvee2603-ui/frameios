package com.cfx.framestudio.ui.cropper

import android.graphics.Bitmap
import android.graphics.Rect
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Crop
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
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
import com.cfx.framestudio.engine.ImageCropEngine
import com.cfx.framestudio.ui.components.GlassCard
import com.cfx.framestudio.ui.theme.BorderHairline
import com.cfx.framestudio.ui.theme.BrandAccent
import com.cfx.framestudio.ui.theme.ElevatedSurface
import com.cfx.framestudio.ui.theme.EmeraldAccent
import com.cfx.framestudio.ui.theme.GradientStart
import com.cfx.framestudio.ui.theme.TextMuted
import com.cfx.framestudio.ui.theme.TextPrimary
import com.cfx.framestudio.ui.theme.VoidCanvas
import kotlinx.coroutines.launch

@Composable
fun ImageCropperScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var imageUri by remember { mutableStateOf<Uri?>(null) }
    var loadedBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var selectedRatio by remember { mutableStateOf("Free") }
    var isCropping by remember { mutableStateOf(false) }

    val imagePickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetContent()
    ) { uri: Uri? ->
        if (uri != null) {
            imageUri = uri
            scope.launch {
                loadedBitmap = ImageCropEngine.loadBitmap(context, uri)
            }
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
            Text("IMAGE CROPPER STUDIO", color = TextPrimary, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            IconButton(onClick = { imagePickerLauncher.launch("image/*") }) {
                Icon(Icons.Default.PhotoLibrary, contentDescription = "Select Image", tint = GradientStart)
            }
        }

        if (loadedBitmap == null) {
            GlassCard(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(1f),
                onClick = { imagePickerLauncher.launch("image/*") }
            ) {
                Column(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Icon(Icons.Default.Crop, contentDescription = null, tint = GradientStart, modifier = Modifier.size(48.dp))
                    Spacer(modifier = Modifier.height(12.dp))
                    Text("Select Image to Crop", color = TextPrimary, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                    Text("Pixel-perfect cropping & aspect ratio presets", color = TextMuted, fontSize = 12.sp)
                }
            }
        } else {
            val bmp = loadedBitmap!!

            // Image Preview Canvas
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(1f)
                    .clip(RoundedCornerShape(16.dp))
                    .background(Color.Black)
                    .border(1.dp, BorderHairline, RoundedCornerShape(16.dp)),
                contentAlignment = Alignment.Center
            ) {
                Image(
                    bitmap = bmp.asImageBitmap(),
                    contentDescription = null,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Fit
                )

                // Resolution Badge
                Box(
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(10.dp)
                        .background(Color(0xCC0D0D11), RoundedCornerShape(8.dp))
                        .padding(horizontal = 8.dp, vertical = 4.dp)
                ) {
                    Text(
                        text = "${bmp.width} × ${bmp.height} px",
                        color = EmeraldAccent,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold
                    )
                }
            }

            // Aspect Ratio Pills
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                listOf("Free", "1:1", "16:9", "9:16", "4:5").forEach { ratio ->
                    RatioPill(ratio, isSelected = selectedRatio == ratio) {
                        selectedRatio = ratio
                    }
                }
            }

            // Crop Action Button
            Button(
                onClick = {
                    if (isCropping) return@Button
                    isCropping = true
                    scope.launch {
                        // Compute aspect ratio crop rectangle
                        val w = bmp.width
                        val h = bmp.height
                        val rect = when (selectedRatio) {
                            "1:1" -> {
                                val size = minOf(w, h)
                                Rect((w - size) / 2, (h - size) / 2, (w + size) / 2, (h + size) / 2)
                            }
                            "16:9" -> {
                                val targetH = (w * 9) / 16
                                if (targetH <= h) {
                                    Rect(0, (h - targetH) / 2, w, (h + targetH) / 2)
                                } else {
                                    val targetW = (h * 16) / 9
                                    Rect((w - targetW) / 2, 0, (w + targetW) / 2, h)
                                }
                            }
                            "9:16" -> {
                                val targetW = (h * 9) / 16
                                if (targetW <= w) {
                                    Rect((w - targetW) / 2, 0, (w + targetW) / 2, h)
                                } else {
                                    val targetH = (w * 16) / 9
                                    Rect(0, (h - targetH) / 2, w, (h + targetH) / 2)
                                }
                            }
                            "4:5" -> {
                                val targetW = (h * 4) / 5
                                if (targetW <= w) {
                                    Rect((w - targetW) / 2, 0, (w + targetW) / 2, h)
                                } else {
                                    val targetH = (w * 5) / 4
                                    Rect(0, (h - targetH) / 2, w, (h + targetH) / 2)
                                }
                            }
                            else -> Rect(0, 0, w, h)
                        }

                        val cropped = ImageCropEngine.cropBitmap(bmp, rect)
                        val outUri = ImageCropEngine.saveCroppedImage(context, cropped)
                        isCropping = false
                        if (outUri != null) {
                            Toast.makeText(context, "✓ Cropped image (${cropped.width}x${cropped.height}) saved to Gallery!", Toast.LENGTH_LONG).show()
                        } else {
                            Toast.makeText(context, "Failed to save cropped image", Toast.LENGTH_SHORT).show()
                        }
                    }
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp),
                colors = ButtonDefaults.buttonColors(containerColor = BrandAccent),
                shape = RoundedCornerShape(14.dp),
                enabled = !isCropping
            ) {
                Icon(imageVector = Icons.Default.FileDownload, contentDescription = null, tint = Color.White)
                Spacer(modifier = Modifier.size(8.dp))
                Text(
                    text = if (isCropping) "Cropping & Saving..." else "Save Cropped Image ($selectedRatio)",
                    color = Color.White,
                    fontWeight = FontWeight.Bold
                )
            }
        }
    }
}

@Composable
private fun RatioPill(label: String, isSelected: Boolean, onClick: () -> Unit) {
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
            .padding(horizontal = 14.dp, vertical = 8.dp)
    ) {
        Text(
            text = label,
            color = if (isSelected) GradientStart else TextMuted,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold
        )
    }
}
