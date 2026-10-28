package com.cfx.framestudio

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.cfx.framestudio.ui.cropper.ImageCropperScreen
import com.cfx.framestudio.ui.exporter.FrameExporterScreen
import com.cfx.framestudio.ui.launcher.LauncherScreen
import com.cfx.framestudio.ui.theme.FrameStudioTheme
import com.cfx.framestudio.ui.theme.VoidCanvas
import com.cfx.framestudio.ui.trimmer.VideoTrimmerScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
        )
        setContent {
            FrameStudioTheme {
                Surface(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(VoidCanvas)
                        .statusBarsPadding()
                        .navigationBarsPadding(),
                    color = VoidCanvas
                ) {
                    val navController = rememberNavController()

                    NavHost(
                        navController = navController,
                        startDestination = "launcher"
                    ) {
                        composable("launcher") {
                            LauncherScreen(
                                onNavigateToExporter = { navController.navigate("exporter") },
                                onNavigateToTrimmer = { navController.navigate("trimmer") },
                                onNavigateToCropper = { navController.navigate("cropper") }
                            )
                        }

                        composable("exporter") {
                            FrameExporterScreen(
                                onBack = { navController.popBackStack() }
                            )
                        }

                        composable("trimmer") {
                            VideoTrimmerScreen(
                                onBack = { navController.popBackStack() }
                            )
                        }

                        composable("cropper") {
                            ImageCropperScreen(
                                onBack = { navController.popBackStack() }
                            )
                        }
                    }
                }
            }
        }
    }
}
