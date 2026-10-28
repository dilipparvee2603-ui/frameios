import os
import time
from pathlib import Path
from PySide6.QtWidgets import (
    QWidget, QHBoxLayout, QVBoxLayout, QPushButton, QLabel,
    QSpinBox, QComboBox, QFrame, QSizePolicy, QLineEdit,
    QSlider, QCheckBox, QFileDialog, QGroupBox, QFormLayout
)
from PySide6.QtCore import Qt, Signal, QTimer
from ..utils import frames_to_timecode, format_file_size, open_in_explorer, generate_output_filename
from ..config import ConfigManager

def create_separator() -> QFrame:
    """Create a subtle vertical separator line between button groups."""
    sep = QFrame()
    sep.setFrameShape(QFrame.VLine)
    sep.setFrameShadow(QFrame.Plain)
    sep.setStyleSheet("color: #252b3d; margin: 2px 2px;")
    return sep

class PlaybackControls(QWidget):
    """
    Unified Media Toolbar and Settings Panel.
    - Single cohesive horizontal bar for Timecode, Transport, and Export Actions.
    - Collapsible settings drawer for Destination, Format, Quality, and Naming.
    """
    # Playback signals
    step_requested = Signal(int)       # delta frames (-1, +1, -10, +10)
    jump_to_frame = Signal(int)       # absolute frame
    play_pause_toggled = Signal(bool) # True = playing
    speed_changed = Signal(float)

    # Export signals
    export_current_frame_requested = Signal()
    crop_requested = Signal()
    copy_clipboard_requested = Signal()
    batch_export_requested = Signal()
    prerender_requested = Signal()
    trim_requested = Signal()
    output_dir_changed = Signal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.config = ConfigManager()
        
        # Video context
        self.fps = 30.0
        self.total_frames = 0
        self.video_width = 0
        self.video_height = 0
        self.current_video_path = ""
        self.current_frame_idx = 0
        
        # State
        self.is_playing = False
        self.playback_speed = 1.0
        
        # High-precision timer for real-time video playback
        self.play_timer = QTimer(self)
        self.play_timer.setTimerType(Qt.PreciseTimer)
        self.play_timer.timeout.connect(self._on_play_tick)
        self.playback_wall_start = 0.0
        self.playback_frame_start = 0
        
        self._setup_ui()
        self._load_saved_settings()

    def _setup_ui(self):
        main_layout = QVBoxLayout(self)
        main_layout.setContentsMargins(6, 2, 6, 2)
        main_layout.setSpacing(4)

        # ========================================================
        # 1. THE SINGLE UNIFIED MASTER TOOLBAR (Equally balanced 3-part layout)
        # ========================================================
        bar = QHBoxLayout()
        bar.setContentsMargins(0, 0, 0, 0)
        bar.setSpacing(6)

        # --- A. Timecode & Frame Info (Left Container) ---
        self.left_container = QWidget()
        time_box = QHBoxLayout(self.left_container)
        time_box.setContentsMargins(0, 0, 0, 0)
        time_box.setSpacing(6)
        time_box.setAlignment(Qt.AlignLeft | Qt.AlignVCenter)
        
        self.timecode_label = QLabel("00:00:00.000")
        self.timecode_label.setFixedHeight(28)
        self.timecode_label.setStyleSheet("""
            QLabel {
                font-family: 'Consolas', 'JetBrains Mono', monospace;
                font-size: 13px;
                font-weight: 700;
                color: #F4F5F7;
                background-color: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-radius: 6px;
                padding: 2px 8px;
            }
        """)
        time_box.addWidget(self.timecode_label)

        self.frame_label = QLabel("Frame: 0 / 0")
        self.frame_label.setStyleSheet("color: #94A3B8; font-size: 11px; font-weight: 600; font-family: 'Consolas', monospace;")
        time_box.addWidget(self.frame_label)
        
        self.res_badge = QLabel("")
        self.res_badge.setStyleSheet("""
            QLabel {
                color: #F4F5F7;
                background: #1A1A22;
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-radius: 4px;
                padding: 2px 6px;
                font-size: 10px;
                font-weight: bold;
            }
        """)
        self.res_badge.hide()
        time_box.addWidget(self.res_badge)

        # --- B. Symmetrical Transport Controls (True Center Container) ---
        self.center_container = QWidget()
        transport = QHBoxLayout(self.center_container)
        transport.setContentsMargins(0, 0, 0, 0)
        transport.setSpacing(2)
        transport.setAlignment(Qt.AlignCenter)

        # Start (Home)
        self.btn_start = QPushButton("⏮")
        self.btn_start.setToolTip("Jump to Start (Home)")
        self.btn_start.setProperty("class", "transportBtn")
        self.btn_start.setFixedSize(28, 28)
        self.btn_start.clicked.connect(lambda: self.jump_to_frame.emit(0))
        transport.addWidget(self.btn_start)

        # Step -10 frames
        self.btn_prev10 = QPushButton("« 10f")
        self.btn_prev10.setToolTip("Step Back 10 Frames (Shift + Left Arrow)")
        self.btn_prev10.setProperty("class", "transportBtn")
        self.btn_prev10.setFixedSize(38, 28)
        self.btn_prev10.clicked.connect(lambda: self.step_requested.emit(-10))
        transport.addWidget(self.btn_prev10)

        # Step -1 frame (Left Arrow)
        self.btn_prev1 = QPushButton("◀ 1f")
        self.btn_prev1.setToolTip("Step Back 1 Frame (Left Arrow ←)")
        self.btn_prev1.setProperty("class", "transportBtn")
        self.btn_prev1.setFixedSize(34, 28)
        self.btn_prev1.clicked.connect(lambda: self.step_requested.emit(-1))
        transport.addWidget(self.btn_prev1)

        # Play / Pause (Space)
        self.btn_play = QPushButton("▶")
        self.btn_play.setToolTip("Play / Pause (Spacebar)")
        self.btn_play.setFixedSize(36, 28)
        self.btn_play.setStyleSheet("""
            QPushButton {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #FF4A3D, stop:1 #D92A20);
                color: #FFFFFF;
                border: 1px solid rgba(255, 74, 61, 0.4);
                border-radius: 6px;
                font-size: 13px;
                font-weight: bold;
            }
            QPushButton:hover {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #FF6257, stop:1 #E83328);
                border: 1px solid rgba(255, 74, 61, 0.6);
            }
            QPushButton:pressed {
                background: #C0000A;
            }
        """)
        self.btn_play.clicked.connect(self.toggle_play)
        transport.addWidget(self.btn_play)

        # Step +1 frame (Right Arrow)
        self.btn_next1 = QPushButton("1f ▶")
        self.btn_next1.setToolTip("Step Forward 1 Frame (Right Arrow →)")
        self.btn_next1.setProperty("class", "transportBtn")
        self.btn_next1.setFixedSize(34, 28)
        self.btn_next1.clicked.connect(lambda: self.step_requested.emit(1))
        transport.addWidget(self.btn_next1)

        # Step +10 frames
        self.btn_next10 = QPushButton("10f »")
        self.btn_next10.setToolTip("Step Forward 10 Frames (Shift + Right Arrow)")
        self.btn_next10.setProperty("class", "transportBtn")
        self.btn_next10.setFixedSize(38, 28)
        self.btn_next10.clicked.connect(lambda: self.step_requested.emit(10))
        transport.addWidget(self.btn_next10)

        # End
        self.btn_end = QPushButton("⏭")
        self.btn_end.setToolTip("Jump to End (End)")
        self.btn_end.setProperty("class", "transportBtn")
        self.btn_end.setFixedSize(28, 28)
        self.btn_end.clicked.connect(lambda: self.jump_to_frame.emit(max(0, self.total_frames - 1)))
        transport.addWidget(self.btn_end)

        for btn in (self.btn_start, self.btn_prev10, self.btn_prev1, self.btn_play, self.btn_next1, self.btn_next10, self.btn_end):
            btn.setFocusPolicy(Qt.NoFocus)

        # --- C. Primary Export & Folder Actions (Right Container) ---
        self.right_container = QWidget()
        actions = QHBoxLayout(self.right_container)
        actions.setContentsMargins(0, 0, 4, 0)
        actions.setSpacing(5)
        actions.setAlignment(Qt.AlignRight | Qt.AlignVCenter)

        # Pre-render RAM Preview Button
        self.btn_prerender = QPushButton("⚡ Pre-render")
        self.btn_prerender.setObjectName("amberBtn")
        self.btn_prerender.setToolTip("Pre-render frames into high-speed RAM at 100% full quality for lag-free playback (Shortcut: P)")
        self.btn_prerender.setFixedHeight(28)
        self.btn_prerender.setStyleSheet("""
            QPushButton#amberBtn {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #D97706, stop:1 #F59E0B);
                color: #FFFFFF;
                font-weight: 700;
                font-size: 11px;
                border: 1px solid rgba(245, 158, 11, 0.4);
                border-radius: 6px;
                padding: 0 12px;
            }
            QPushButton#amberBtn:hover {
                background: #F59E0B;
                border: 1px solid rgba(245, 158, 11, 0.6);
            }
            QPushButton#amberBtn:pressed {
                background: #B45309;
            }
        """)
        self.btn_prerender.clicked.connect(self.prerender_requested.emit)
        actions.addWidget(self.btn_prerender)

        # Video Trim & Export Button
        self.btn_trim = QPushButton("✂️ Trim Video")
        self.btn_trim.setToolTip("Trim video segment with precise timeframe inputs in 100% original resolution (Shortcut: Ctrl+T)")
        self.btn_trim.setFixedHeight(28)
        self.btn_trim.setStyleSheet("""
            QPushButton {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #059669, stop:1 #10B981);
                border: 1px solid rgba(16, 185, 129, 0.4);
                color: #FFFFFF;
                font-weight: 700;
                font-size: 11px;
                border-radius: 6px;
                padding: 0 12px;
            }
            QPushButton:hover {
                background: #10B981;
                border: 1px solid rgba(16, 185, 129, 0.6);
            }
            QPushButton:pressed {
                background: #047857;
            }
        """)
        self.btn_trim.clicked.connect(self.trim_requested.emit)
        actions.addWidget(self.btn_trim)

        # Export Frame Button
        self.btn_export = QPushButton("📸 Export Frame")
        self.btn_export.setObjectName("primaryBtn")
        self.btn_export.setToolTip("Export frame at 100% original pixel resolution (Shortcut: E or Ctrl+S)")
        self.btn_export.setFixedHeight(28)
        self.btn_export.clicked.connect(self.export_current_frame_requested.emit)
        actions.addWidget(self.btn_export)

        # Crop Tool Button (Separate Window)
        self.btn_crop = QPushButton("✂️ Crop Frame")
        self.btn_crop.setToolTip("Open in separate Image Cropper window (4:5, 16:9, 9:16, 1:1)")
        self.btn_crop.setFixedHeight(28)
        self.btn_crop.setStyleSheet("""
            QPushButton {
                background-color: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #F4F5F7;
                font-weight: 600;
                font-size: 11px;
                border-radius: 6px;
                padding: 0 12px;
            }
            QPushButton:hover {
                background-color: #1E1E26;
                border: 1px solid rgba(255, 255, 255, 0.16);
                color: #FFFFFF;
            }
            QPushButton:pressed {
                background-color: #111116;
            }
        """)
        self.btn_crop.clicked.connect(self.crop_requested.emit)
        actions.addWidget(self.btn_crop)

        # Open Output Folder
        self.btn_open_folder = QPushButton("📁 Folder")
        self.btn_open_folder.setToolTip("Open output directory in Windows Explorer")
        self.btn_open_folder.setFixedHeight(28)
        self.btn_open_folder.setStyleSheet("""
            QPushButton {
                background-color: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.06);
                border-radius: 6px;
                padding: 3px 10px;
                color: #CBD5E1;
                font-weight: 600;
                font-size: 11px;
            }
            QPushButton:hover {
                background-color: #1E1E26;
                border: 1px solid rgba(255, 255, 255, 0.12);
                color: #FFFFFF;
            }
        """)
        self.btn_open_folder.clicked.connect(self._on_open_folder)
        actions.addWidget(self.btn_open_folder)

        # Settings Toggle Button
        self.btn_toggle_settings = QPushButton("⚙️ Settings ▾")
        self.btn_toggle_settings.setToolTip("Toggle destination and format settings")
        self.btn_toggle_settings.setCheckable(True)
        self.btn_toggle_settings.setFixedHeight(28)
        self.btn_toggle_settings.setStyleSheet("""
            QPushButton {
                background-color: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.06);
                border-radius: 6px;
                padding: 3px 10px;
                color: #CBD5E1;
                font-weight: 600;
                font-size: 11px;
            }
            QPushButton:hover {
                background-color: #1E1E26;
                border: 1px solid rgba(255, 255, 255, 0.14);
                color: #FFFFFF;
            }
            QPushButton:checked {
                background-color: #1A1A22;
                border: 1px solid #C0000A;
                color: #FF4A3D;
            }
        """)
        self.btn_toggle_settings.clicked.connect(self._toggle_settings_panel)
        actions.addWidget(self.btn_toggle_settings)

        # Assemble master toolbar: Left (stretch 1), Center (transport), Right (stretch 1)
        bar.addWidget(self.left_container, 1, Qt.AlignLeft | Qt.AlignVCenter)
        bar.addWidget(self.center_container, 0, Qt.AlignCenter)
        bar.addWidget(self.right_container, 1, Qt.AlignRight | Qt.AlignVCenter)
        main_layout.addLayout(bar)

        # ========================================================
        # 2. COLLAPSIBLE SETTINGS DRAWER (Tucked underneath)
        # ========================================================
        self.settings_drawer = QFrame()
        self.settings_drawer.setStyleSheet("""
            QFrame#settingsDrawer {
                background-color: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.06);
                border-radius: 8px;
                padding: 6px;
            }
        """)
        self.settings_drawer.setObjectName("settingsDrawer")
        
        drawer_layout = QVBoxLayout(self.settings_drawer)
        drawer_layout.setContentsMargins(8, 6, 8, 8)
        drawer_layout.setSpacing(8)

        # Row 1: Destination
        folder_group = QGroupBox("📁 Output Destination")
        folder_layout = QHBoxLayout(folder_group)
        folder_layout.setContentsMargins(8, 8, 8, 6)
        folder_layout.setSpacing(6)

        self.path_edit = QLineEdit()
        self.path_edit.setPlaceholderText("Select output folder...")
        self.path_edit.setFixedHeight(26)
        self.path_edit.textChanged.connect(self._on_path_edited)
        folder_layout.addWidget(self.path_edit, 3)

        self.btn_browse = QPushButton("Browse...")
        self.btn_browse.setFixedHeight(26)
        self.btn_browse.clicked.connect(self._on_browse_folder)
        folder_layout.addWidget(self.btn_browse)

        self.btn_set_default = QPushButton("★ Set as Default")
        self.btn_set_default.setToolTip("Permanently remember this folder as default")
        self.btn_set_default.setFixedHeight(26)
        self.btn_set_default.clicked.connect(self._on_set_as_default)
        folder_layout.addWidget(self.btn_set_default)

        self.chk_use_video_dir = QCheckBox("Save to video's folder")
        self.chk_use_video_dir.toggled.connect(self._on_use_video_dir_toggled)
        folder_layout.addWidget(self.chk_use_video_dir)

        drawer_layout.addWidget(folder_group)

        # Row 2: Format & Naming
        fmt_group = QGroupBox("⚙️ Export Format & Naming")
        fmt_layout = QHBoxLayout(fmt_group)
        fmt_layout.setContentsMargins(8, 8, 8, 6)
        fmt_layout.setSpacing(10)

        # Format
        fmt_lbl = QLabel("Format:")
        fmt_layout.addWidget(fmt_lbl)
        self.combo_format = QComboBox()
        self.combo_format.addItems(["PNG (Lossless)", "JPEG (High Quality)", "WEBP"])
        self.combo_format.setFixedHeight(26)
        self.combo_format.currentIndexChanged.connect(self._on_format_changed)
        fmt_layout.addWidget(self.combo_format)

        self.quality_label = QLabel("Quality: 95%")
        self.quality_slider = QSlider(Qt.Horizontal)
        self.quality_slider.setRange(50, 100)
        self.quality_slider.setValue(95)
        self.quality_slider.setFixedWidth(100)
        self.quality_slider.valueChanged.connect(self._on_quality_changed)
        self.quality_slider.hide()
        self.quality_label.hide()
        fmt_layout.addWidget(self.quality_label)
        fmt_layout.addWidget(self.quality_slider)

        # Naming pattern
        name_lbl = QLabel("Pattern:")
        fmt_layout.addWidget(name_lbl)
        self.pattern_edit = QLineEdit("{video_name}_frame_{frame:06d}")
        self.pattern_edit.setFixedHeight(26)
        self.pattern_edit.textChanged.connect(self._update_preview)
        fmt_layout.addWidget(self.pattern_edit, 2)

        # Batch export button in drawer
        self.btn_batch = QPushButton("⚡ Batch Export...")
        self.btn_batch.setToolTip("Export frame range or interval (Shortcut: B)")
        self.btn_batch.setFixedHeight(26)
        self.btn_batch.clicked.connect(self.batch_export_requested.emit)
        fmt_layout.addWidget(self.btn_batch)

        drawer_layout.addWidget(fmt_group)

        # Preview label
        self.preview_label = QLabel("Preview: -")
        self.preview_label.setStyleSheet("color: #38bdf8; font-family: monospace; font-size: 11px; padding-left: 4px;")
        drawer_layout.addWidget(self.preview_label)

        main_layout.addWidget(self.settings_drawer)

        # Collapsed by default!
        self.settings_drawer.hide()

    def _toggle_settings_panel(self, checked: bool):
        self.settings_drawer.setVisible(checked)
        self.btn_toggle_settings.setChecked(checked)
        if checked:
            self.btn_toggle_settings.setText("⚙️ Settings ▴")
        else:
            self.btn_toggle_settings.setText("⚙️ Settings ▾")
        self.config.set("settings_expanded", checked)

    def _load_saved_settings(self):
        saved_dir = self.config.get("default_output_dir", "")
        use_video_dir = self.config.get("use_video_folder", False)
        self.chk_use_video_dir.setChecked(use_video_dir)
        
        if saved_dir and os.path.exists(saved_dir):
            self.path_edit.setText(saved_dir)
        else:
            pictures = Path(os.environ.get("USERPROFILE", ".")) / "Pictures" / "Frames"
            self.path_edit.setText(str(pictures))

        fmt = self.config.get("export_format", "PNG")
        idx = 0
        if fmt == "JPG":
            idx = 1
        elif fmt == "WEBP":
            idx = 2
        self.combo_format.setCurrentIndex(idx)
        
        self.quality_slider.setValue(self.config.get("jpeg_quality", 95))
        self.pattern_edit.setText(self.config.get("naming_pattern", "{video_name}_frame_{frame:06d}"))
        self._on_format_changed(idx)

        is_expanded = self.config.get("settings_expanded", False)
        if is_expanded:
            self._toggle_settings_panel(True)

    # --- Video Context & Synchronization ---
    def set_video_info(self, total_frames: int, fps: float, width: int, height: int):
        self.total_frames = max(1, total_frames)
        self.fps = max(0.1, fps)
        self.video_width = width
        self.video_height = height
        
        if width > 0 and height > 0:
            self.res_badge.setText(f"{width} × {height}")
            self.res_badge.show()
        else:
            self.res_badge.hide()
            
        self.btn_export.setText("📸 Export Frame")
        self.update_position(0)
        self._update_timer_interval()
        self._update_preview()

    def set_video_context(self, video_path: str, width: int, height: int, fps: float):
        self.current_video_path = video_path
        self.set_video_info(self.total_frames, fps, width, height)
        
        if self.chk_use_video_dir.isChecked() and video_path:
            self.path_edit.setText(str(Path(video_path).parent))
        self._update_preview()

    def update_position(self, frame_idx: int):
        self.current_frame_idx = max(0, min(frame_idx, self.total_frames - 1))
        self.timecode_label.setText(frames_to_timecode(self.current_frame_idx, self.fps))
        self.frame_label.setText(f"Frame: {self.current_frame_idx:,} / {self.total_frames:,}")
        # Only update export filename string when paused / scrubbing to keep 4K playback ultra-fast!
        if not self.is_playing:
            self._update_preview()

    def update_frame_position(self, frame_idx: int):
        self.update_position(frame_idx)

    # --- Playback Actions ---
    def toggle_play(self):
        if self.is_playing:
            self.pause()
        else:
            self.play()

    def play(self):
        if self.total_frames <= 0:
            return
        # If at the very end of video, restart from beginning
        if self.current_frame_idx >= self.total_frames - 1:
            self.current_frame_idx = 0
            self.jump_to_frame.emit(0)

        self.is_playing = True
        self.btn_play.setText("⏸")
        self.btn_play.setStyleSheet("""
            QPushButton {
                background-color: #ea580c;
                color: white;
                border-radius: 4px;
                font-size: 13px;
                font-weight: bold;
            }
            QPushButton:hover {
                background-color: #f97316;
            }
        """)
        self.playback_wall_start = time.perf_counter()
        self.playback_frame_start = self.current_frame_idx
        # High precision 8ms poll interval ensures real-time accuracy and eliminates timer quantization
        self.play_timer.setInterval(8)
        self.play_timer.start()
        self.play_pause_toggled.emit(True)

    def pause(self):
        self.is_playing = False
        self.btn_play.setText("▶")
        self.btn_play.setStyleSheet("""
            QPushButton {
                background-color: #4f46e5;
                color: white;
                border: none;
                border-radius: 4px;
                font-size: 13px;
                font-weight: bold;
            }
            QPushButton:hover {
                background-color: #6366f1;
                border: none;
            }
        """)
        self.play_timer.stop()
        self._update_preview()
        self.play_pause_toggled.emit(False)

    def reset_playback_anchor(self):
        """Reset wall-clock anchor when scrubbing or jumping during playback."""
        self.playback_wall_start = time.perf_counter()
        self.playback_frame_start = self.current_frame_idx

    def _update_timer_interval(self):
        pass

    def _on_play_tick(self):
        if not self.is_playing or self.total_frames <= 0 or self.fps <= 0:
            return
        now = time.perf_counter()
        elapsed = now - self.playback_wall_start
        target = self.playback_frame_start + int(elapsed * self.fps * self.playback_speed)

        if target >= self.total_frames:
            # Seamless loop
            self.playback_wall_start = now
            self.playback_frame_start = 0
            target = 0
        elif target < 0:
            target = 0

        if target != self.current_frame_idx:
            self.jump_to_frame.emit(target)

    def _on_speed_changed(self):
        speeds = [0.25, 0.5, 1.0, 2.0]
        if hasattr(self, "speed_combo"):
            idx = self.speed_combo.currentIndex()
            if 0 <= idx < len(speeds):
                self.playback_speed = speeds[idx]
                self.reset_playback_anchor()
                self.speed_changed.emit(self.playback_speed)

    def _on_goto_spin(self, val):
        self.jump_to_frame.emit(val)

    # --- Export Accessors & Success Animation ---
    def _get_export_btn_text(self) -> str:
        return "📸 Export Frame"

    def show_export_success(self):
        """Show clean '✓ Frame Saved' on the button without any overlapping popup."""
        orig_text = self._get_export_btn_text()
        self.btn_export.setText("✓ Frame Saved")
        self.btn_export.setStyleSheet("""
            QPushButton {
                background: #059669 !important;
                color: #ffffff !important;
                border: none !important;
                font-weight: bold;
                font-size: 12px;
                border-radius: 5px;
            }
        """)
        QTimer.singleShot(1400, lambda: self._reset_export_btn(orig_text))

    def _reset_export_btn(self, text: str):
        self.btn_export.setStyleSheet("")
        self.btn_export.setText(text)

    def show_copy_success(self):
        """Pass-through if copy is triggered via Ctrl+C shortcut."""
        pass

    def get_output_directory(self) -> str:
        dest = self.path_edit.text().strip()
        if not dest:
            dest = str(Path.home() / "Pictures" / "Frames")
        return dest

    def get_export_extension(self) -> str:
        idx = self.combo_format.currentIndex()
        if idx == 1:
            return "jpg"
        elif idx == 2:
            return "webp"
        return "png"

    def get_quality(self) -> int:
        return self.quality_slider.value()

    def get_naming_template(self) -> str:
        return self.pattern_edit.text().strip() or "{video_name}_frame_{frame:06d}"

    def get_target_filepath(self, frame_idx: int = None) -> str:
        if frame_idx is None:
            frame_idx = self.current_frame_idx
        filename = generate_output_filename(
            self.current_video_path,
            frame_idx,
            self.fps,
            self.video_width,
            self.video_height,
            self.get_naming_template(),
            self.get_export_extension()
        )
        return str(Path(self.get_output_directory()) / filename)

    def _update_preview(self):
        if not self.settings_drawer.isVisible():
            return
        filename = generate_output_filename(
            self.current_video_path,
            self.current_frame_idx,
            self.fps,
            self.video_width,
            self.video_height,
            self.get_naming_template(),
            self.get_export_extension()
        )
        self.preview_label.setText(f"{filename}  [{self.video_width}×{self.video_height}]")

    def _on_browse_folder(self):
        start_dir = self.path_edit.text() or str(Path.home())
        chosen = QFileDialog.getExistingDirectory(self, "Select Output Folder", start_dir)
        if chosen:
            self.path_edit.setText(chosen)
            self.output_dir_changed.emit(chosen)

    def _on_set_as_default(self):
        current_dir = self.path_edit.text().strip()
        if current_dir:
            self.config.set("default_output_dir", current_dir)
            self.btn_set_default.setText("✓ Saved!")
            self.btn_set_default.setStyleSheet("color: #10b981; font-weight: bold;")
            QTimer.singleShot(2000, lambda: self.btn_set_default.setText("★ Set as Default"))
            QTimer.singleShot(2000, lambda: self.btn_set_default.setStyleSheet(""))

    def _on_use_video_dir_toggled(self, checked: bool):
        self.config.set("use_video_folder", checked)
        if checked and self.current_video_path:
            self.path_edit.setText(str(Path(self.current_video_path).parent))
        elif not checked:
            default_dir = self.config.get("default_output_dir", "")
            if default_dir:
                self.path_edit.setText(default_dir)

    def _on_path_edited(self, new_path: str):
        self.output_dir_changed.emit(new_path)

    def _on_open_folder(self):
        dest = self.get_output_directory()
        Path(dest).mkdir(parents=True, exist_ok=True)
        open_in_explorer(dest)

    def _on_format_changed(self, idx: int):
        is_lossy = (idx != 0)
        self.quality_slider.setVisible(is_lossy)
        self.quality_label.setVisible(is_lossy)
        
        fmt = "PNG" if idx == 0 else ("JPG" if idx == 1 else "WEBP")
        self.config.set("export_format", fmt)
        self._update_preview()

    def _on_quality_changed(self, val: int):
        self.quality_label.setText(f"Quality: {val}%")
        self.config.set("jpeg_quality", val)

    def showEvent(self, event):
        super().showEvent(event)
        self._balance_toolbar()

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._balance_toolbar()

    def _balance_toolbar(self):
        """Ensures left and right containers maintain balanced widths without pushing buttons off-screen."""
        if not hasattr(self, 'left_container') or not hasattr(self, 'right_container') or not hasattr(self, 'center_container'):
            return

        avail_total = self.width() - 20
        if avail_total <= 0:
            return

        center_w = self.center_container.sizeHint().width()
        w_left = self.left_container.sizeHint().width()
        w_right = self.right_container.sizeHint().width()

        remaining_for_sides = avail_total - center_w
        avail_per_side = remaining_for_sides // 2

        if avail_per_side >= w_right:
            # Symmetrical centering: both sides equal
            self.left_container.setFixedWidth(avail_per_side)
            self.right_container.setFixedWidth(avail_per_side)
        else:
            # Graceful fallback: right container keeps its natural sizeHint (no clipping!)
            # Left container takes remaining available space
            left_avail = max(w_left, avail_total - center_w - w_right)
            self.left_container.setFixedWidth(left_avail)
            self.right_container.setFixedWidth(w_right)

