"""
Sleek, Minimal Studio Launcher for Frame Exporter & Image Cropper.
Provides a clean, uncluttered entry point. Each tool opens separately,
and closing either tool gracefully returns to this launcher.
"""

import os
import sys
from pathlib import Path
from typing import Optional

from PySide6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QLabel,
    QPushButton, QFrame, QFileDialog, QSizePolicy, QApplication
)
from PySide6.QtGui import (
    QColor, QFont, QCursor, QDragEnterEvent, QDropEvent
)
from PySide6.QtCore import (
    Qt, Signal, QPoint, QRect, QPropertyAnimation,
    QEasingCurve, QParallelAnimationGroup, QTimer
)

from ..config import ConfigManager
from ..utils import open_in_explorer
from .frameless import CustomTitleBar, FramelessWindowMixin

VIDEO_EXTENSIONS = {".mp4", ".mov", ".mkv", ".webm", ".avi", ".flv", ".wmv", ".m4v"}
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tiff"}

def _hex_to_rgba(hex_color: str, alpha: float) -> str:
    h = hex_color.lstrip('#')
    if len(h) < 6:
        return f"rgba(100, 100, 100, {alpha})"
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return f"rgba({r}, {g}, {b}, {alpha})"


class StudioLaunchCard(QFrame):
    """
    Clean, minimal, high-end studio card for launching a tool.
    Entire card is clickable with interactive hover glow.
    """
    card_clicked = Signal()

    def __init__(
        self,
        icon_glyph: str,
        title: str,
        subtitle: str,
        btn_text: str,
        accent_color: str = "#4f46e5",
        parent=None
    ):
        super().__init__(parent)
        self.setObjectName("studioLaunchCard")
        self.accent_color = accent_color
        self.is_hovered = False
        self.setCursor(Qt.PointingHandCursor)
        self.setMouseTracking(True)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)

        self._setup_ui(icon_glyph, title, subtitle, btn_text)
        self._update_style()

    def _setup_ui(self, icon_glyph: str, title: str, subtitle: str, btn_text: str):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(24, 24, 24, 20)
        layout.setSpacing(12)
        layout.setAlignment(Qt.AlignCenter)

        # 1. Centered Glowing Circular Icon
        i_bg = _hex_to_rgba(self.accent_color, 0.15)
        i_border = _hex_to_rgba(self.accent_color, 0.35)
        self.lbl_icon = QLabel(icon_glyph)
        self.lbl_icon.setFixedSize(54, 54)
        self.lbl_icon.setAlignment(Qt.AlignCenter)
        self.lbl_icon.setStyleSheet(f"""
            QLabel {{
                background: qlineargradient(x1:0, y1:0, x2:1, y2:1, stop:0 {i_bg}, stop:1 #15151A);
                border: 1px solid {i_border};
                border-radius: 27px;
                font-size: 24px;
            }}
        """)
        layout.addWidget(self.lbl_icon, 0, Qt.AlignCenter)

        # 2. Tool Title
        lbl_title = QLabel(title)
        lbl_title.setAlignment(Qt.AlignCenter)
        lbl_title.setStyleSheet("""
            QLabel {
                color: #F4F5F7;
                font-size: 16px;
                font-weight: 800;
                letter-spacing: 0.3px;
                background: transparent;
            }
        """)
        layout.addWidget(lbl_title, 0, Qt.AlignCenter)

        # 3. Concise Subtitle
        lbl_sub = QLabel(subtitle)
        lbl_sub.setAlignment(Qt.AlignCenter)
        lbl_sub.setWordWrap(True)
        lbl_sub.setStyleSheet("""
            QLabel {
                color: #94A3B8;
                font-size: 11px;
                font-weight: 500;
                background: transparent;
            }
        """)
        layout.addWidget(lbl_sub, 0, Qt.AlignCenter)

        layout.addSpacing(6)

        # 4. Prominent Launch Button
        self.btn_launch = QPushButton(btn_text)
        self.btn_launch.setFixedHeight(34)
        self.btn_launch.setCursor(Qt.PointingHandCursor)
        self.btn_launch.setStyleSheet(f"""
            QPushButton {{
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 {self.accent_color}, stop:1 {self.accent_color}cc);
                color: #FFFFFF;
                border: 1px solid {_hex_to_rgba(self.accent_color, 0.4)};
                border-radius: 8px;
                font-weight: 700;
                font-size: 12px;
                padding: 0 16px;
            }}
            QPushButton:hover {{
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 {self.accent_color}, stop:1 #FFFFFF44);
                border: 1px solid {_hex_to_rgba(self.accent_color, 0.7)};
            }}
            QPushButton:pressed {{
                background-color: {self.accent_color};
            }}
        """)
        self.btn_launch.clicked.connect(self.card_clicked.emit)
        layout.addWidget(self.btn_launch)

    def _update_style(self):
        if self.is_hovered:
            border_c = _hex_to_rgba(self.accent_color, 0.60)
            self.setStyleSheet(f"""
                QFrame#studioLaunchCard {{
                    background: qlineargradient(x1:0, y1:0, x2:0, y2:1, stop:0 #1A1A22, stop:1 #15151A);
                    border: 1px solid {border_c};
                    border-radius: 12px;
                }}
            """)
        else:
            self.setStyleSheet("""
                QFrame#studioLaunchCard {
                    background-color: #15151A;
                    border: 1px solid rgba(255, 255, 255, 0.06);
                    border-radius: 12px;
                }
            """)

    def enterEvent(self, event):
        super().enterEvent(event)
        self.is_hovered = True
        self._update_style()

    def leaveEvent(self, event):
        super().leaveEvent(event)
        self.is_hovered = False
        self._update_style()

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.card_clicked.emit()
        super().mousePressEvent(event)


class LauncherWindow(FramelessWindowMixin, QMainWindow):
    """
    Minimal, high-end studio launcher.
    Frame Extractor and Image Cropper open as separate windows.
    Closing either window automatically returns to this launcher.
    """
    def __init__(self):
        super().__init__()
        self.setFixedSize(880, 360)

        self.config = ConfigManager()
        self.main_window = None
        self.cropper_window = None
        self.trimmer_window = None
        self._is_transitioning = False

        self.setAcceptDrops(True)
        self._setup_ui()
        self.setup_frameless(self.custom_title_bar)

        # Pre-warm child windows in the background so tool clicks are instant (0ms delay)
        QTimer.singleShot(150, self._prewarm_windows)

    def _prewarm_windows(self):
        """Pre-instantiate windows in the background to eliminate creation stutter."""
        try:
            if self.main_window is None:
                from .main_window import MainWindow
                self.main_window = MainWindow()
                self.main_window.return_to_launcher_on_close = True
                self.main_window.return_to_launcher_requested.connect(self._on_return_from_child)

            if self.cropper_window is None:
                from .cropper_window import ImageCropperWindow
                self.cropper_window = ImageCropperWindow()
                self.cropper_window.return_to_launcher_on_close = True
                self.cropper_window.btn_back.setText("← Back to Launcher")
                self.cropper_window.btn_launcher.hide()
                self.cropper_window.return_to_launcher_requested.connect(self._on_return_from_child)

            if self.trimmer_window is None:
                from .trim_window import VideoTrimmerWindow
                self.trimmer_window = VideoTrimmerWindow()
                self.trimmer_window.return_to_launcher_on_close = True
                self.trimmer_window.btn_back.setText("← Back to Launcher")
                self.trimmer_window.return_to_launcher_requested.connect(self._on_return_from_child)
        except Exception:
            # Non-critical background warm
            pass

    def _setup_ui(self):
        root_frame = QFrame(self)
        root_frame.setObjectName("windowRootFrame")
        self.setCentralWidget(root_frame)

        root_layout = QVBoxLayout(root_frame)
        root_layout.setContentsMargins(0, 0, 0, 0)
        root_layout.setSpacing(0)

        # 1. Clean Frameless Title Bar (No menus, No maximize button)
        self.custom_title_bar = CustomTitleBar(
            title="FRAME STUDIO",
            icon_text="✨",
            show_menus=False,
            show_maximize=False,
            parent=self
        )
        root_layout.addWidget(self.custom_title_bar)

        # 2. Main Content Container
        content = QWidget(self)
        content_layout = QVBoxLayout(content)
        content_layout.setContentsMargins(36, 20, 36, 24)
        content_layout.setSpacing(16)

        # --- A. Minimal Header ---
        header_box = QVBoxLayout()
        header_box.setSpacing(4)
        header_box.setAlignment(Qt.AlignCenter)

        lbl_hero_title = QLabel("Frame Studio")
        lbl_hero_title.setAlignment(Qt.AlignCenter)
        lbl_hero_title.setStyleSheet("""
            QLabel {
                font-size: 22px;
                font-weight: 800;
                color: #f8fafc;
                letter-spacing: 0.5px;
            }
        """)
        header_box.addWidget(lbl_hero_title)

        lbl_hero_sub = QLabel("Select a tool to begin")
        lbl_hero_sub.setAlignment(Qt.AlignCenter)
        lbl_hero_sub.setStyleSheet("font-size: 12px; color: #94A3B8; font-weight: 500;")
        header_box.addWidget(lbl_hero_sub)

        content_layout.addLayout(header_box)

        # --- B. Three Focused Choice Cards (Side by Side) ---
        cards_layout = QHBoxLayout()
        cards_layout.setSpacing(14)

        # Card 1: Frame Extractor (CFX Signature Coral-Scarlet Accent)
        self.card_extractor = StudioLaunchCard(
            icon_glyph="🎬",
            title="Frame Extractor",
            subtitle="Lossless 4K/8K frame extraction & contact sheet",
            btn_text="Open Frame Extractor →",
            accent_color="#E31B23",
            parent=self
        )
        self.card_extractor.card_clicked.connect(self._on_launch_extractor)
        cards_layout.addWidget(self.card_extractor)

        # Card 2: Video Trimmer (CFX Emerald Accent)
        self.card_trimmer = StudioLaunchCard(
            icon_glyph="✂️",
            title="Video Trimmer",
            subtitle="Original resolution lossless cutter & timeframes",
            btn_text="Open Video Trimmer →",
            accent_color="#10B981",
            parent=self
        )
        self.card_trimmer.card_clicked.connect(self._on_launch_trimmer)
        cards_layout.addWidget(self.card_trimmer)

        # Card 3: Image Cropper (CFX Studio Purple Accent)
        self.card_cropper = StudioLaunchCard(
            icon_glyph="📐",
            title="Image Cropper",
            subtitle="Precision aspect-ratio cropping & media bin",
            btn_text="Open Image Cropper →",
            accent_color="#8B5CF6",
            parent=self
        )
        self.card_cropper.card_clicked.connect(self._on_launch_cropper)
        cards_layout.addWidget(self.card_cropper)

        content_layout.addLayout(cards_layout, 1)

        root_layout.addWidget(content, 1)

    def _on_launch_extractor(self):
        self.launch_extractor()

    def _on_launch_trimmer(self):
        self.launch_trimmer()

    def _on_launch_cropper(self):
        self.launch_cropper()

    # --- Drag and Drop Routing ---
    def dragEnterEvent(self, event: QDragEnterEvent):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()

    def dropEvent(self, event: QDropEvent):
        urls = event.mimeData().urls()
        if not urls:
            return
        path = urls[0].toLocalFile()
        if not path or not os.path.exists(path):
            return

        ext = Path(path).suffix.lower()
        if ext in VIDEO_EXTENSIONS:
            self.launch_extractor(path)
        elif ext in IMAGE_EXTENSIONS:
            self.launch_cropper(path)
        else:
            self.launch_extractor(path)

    # --- Separate Window Launching & Graceful Closing Return ---
    def launch_extractor(self, video_path: Optional[str] = None):
        """Open Frame Extractor as a separate window; closing it returns to Launcher."""
        if self._is_transitioning:
            return
        self._is_transitioning = True

        from .main_window import MainWindow
        if self.main_window is None:
            self.main_window = MainWindow()
            self.main_window.return_to_launcher_on_close = True
            self.main_window.return_to_launcher_requested.connect(self._on_return_from_child)

        if video_path and os.path.exists(video_path):
            self.main_window.load_video(video_path)

        # Match center geometry cleanly on active screen
        screen = self.screen() or QApplication.primaryScreen()
        s_geo = screen.availableGeometry()
        w = max(1150, self.main_window.width())
        h = max(760, self.main_window.height())
        w = min(w, s_geo.width() - 20)
        h = min(h, s_geo.height() - 40)
        cx = self.geometry().center().x()
        cy = self.geometry().center().y()
        self.main_window.setGeometry(
            max(s_geo.x(), cx - w // 2),
            max(s_geo.y(), cy - h // 2),
            w, h
        )

        self._smooth_switch_to(self.main_window)

    def launch_trimmer(self, video_path: Optional[str] = None):
        """Open Video Trimmer as a separate window; closing it returns to Launcher."""
        if self._is_transitioning:
            return
        self._is_transitioning = True

        from .trim_window import VideoTrimmerWindow
        if self.trimmer_window is None:
            self.trimmer_window = VideoTrimmerWindow()
            self.trimmer_window.return_to_launcher_on_close = True
            self.trimmer_window.btn_back.setText("← Back to Launcher")
            self.trimmer_window.return_to_launcher_requested.connect(self._on_return_from_child)

        if video_path and os.path.exists(video_path):
            self.trimmer_window.load_video(video_path)

        # Match center geometry cleanly on active screen
        screen = self.screen() or QApplication.primaryScreen()
        s_geo = screen.availableGeometry()
        w = max(1150, self.trimmer_window.width())
        h = max(760, self.trimmer_window.height())
        w = min(w, s_geo.width() - 20)
        h = min(h, s_geo.height() - 40)
        cx = self.geometry().center().x()
        cy = self.geometry().center().y()
        self.trimmer_window.setGeometry(
            max(s_geo.x(), cx - w // 2),
            max(s_geo.y(), cy - h // 2),
            w, h
        )

        self._smooth_switch_to(self.trimmer_window)

    def launch_cropper(self, image_path: Optional[str] = None):
        """Open Image Cropper as a separate window; closing it returns to Launcher."""
        if self._is_transitioning:
            return
        self._is_transitioning = True

        from .cropper_window import ImageCropperWindow
        if self.cropper_window is None:
            self.cropper_window = ImageCropperWindow()
            self.cropper_window.return_to_launcher_on_close = True
            self.cropper_window.btn_back.setText("← Back to Launcher")
            self.cropper_window.btn_launcher.hide()
            self.cropper_window.return_to_launcher_requested.connect(self._on_return_from_child)
        else:
            self.cropper_window.btn_back.setText("← Back to Launcher")
            self.cropper_window.btn_launcher.hide()

        if image_path and os.path.exists(image_path):
            self.cropper_window.load_image_file(image_path)

        # Match center geometry cleanly on active screen
        screen = self.screen() or QApplication.primaryScreen()
        s_geo = screen.availableGeometry()
        w = max(1100, self.cropper_window.width())
        h = max(750, self.cropper_window.height())
        w = min(w, s_geo.width() - 20)
        h = min(h, s_geo.height() - 40)
        cx = self.geometry().center().x()
        cy = self.geometry().center().y()
        self.cropper_window.setGeometry(
            max(s_geo.x(), cx - w // 2),
            max(s_geo.y(), cy - h // 2),
            w, h
        )

        self._smooth_switch_to(self.cropper_window)

    def _smooth_switch_to(self, target_window):
        """
        Seamless, flicker-free window handover.
        Target window is presented directly in front before hiding the launcher,
        eliminating desktop bleed-through and DWM layered-window repainting glitches.
        """
        # Ensure full opacity (no layered window composition)
        target_window.setWindowOpacity(1.0)
        target_window.show()
        target_window.raise_()
        target_window.activateWindow()

        # Hide launcher once the target window is securely rendered in front
        def finish():
            self.hide()
            self._is_transitioning = False

        QTimer.singleShot(35, finish)

    def _on_return_from_child(self, child_window):
        """
        Seamless, flicker-free return to Launcher.
        Launcher is brought to front centered on the active screen before hiding
        the child window, preventing taskbar flashes and desktop peek-through.
        """
        if self._is_transitioning:
            return
        self._is_transitioning = True

        # Stop playback in extractor if running
        if hasattr(child_window, 'controls') and getattr(child_window.controls, 'is_playing', False):
            child_window.controls.pause()

        # Center launcher cleanly on the screen where the child window currently is
        screen = child_window.screen() or self.screen() or QApplication.primaryScreen()
        s_center = screen.availableGeometry().center()
        self.move(s_center.x() - self.width() // 2, s_center.y() - self.height() // 2)

        # Ensure launcher is fully opaque and present it in front
        self.setWindowOpacity(1.0)
        self.show()
        self.raise_()
        self.activateWindow()

        # Hide child window once launcher is visible
        def finish_return():
            child_window.hide()
            self._is_transitioning = False

        QTimer.singleShot(35, finish_return)

    def closeEvent(self, event):
        """Cleanly close child windows on exit so no hidden processes linger."""
        if self.main_window:
            self.main_window.return_to_launcher_on_close = False
            self.main_window.close()
        if self.cropper_window:
            self.cropper_window.return_to_launcher_on_close = False
            self.cropper_window.close()
        super().closeEvent(event)
