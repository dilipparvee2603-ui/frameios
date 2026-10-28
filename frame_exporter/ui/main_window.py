import os
import cv2
from pathlib import Path
from PySide6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QFileDialog,
    QMessageBox, QSplitter, QLabel, QFrame, QMenu
)
from PySide6.QtGui import QAction, QKeySequence, QGuiApplication, QImage, QIcon
from PySide6.QtCore import Qt, QTimer, QEvent, QPropertyAnimation, QEasingCurve, QParallelAnimationGroup, Signal

from ..video_engine import VideoEngine
from ..config import ConfigManager
from ..utils import format_file_size, open_in_explorer
from .video_canvas import VideoCanvas
from .timeline import TimelineSlider
from .controls import PlaybackControls
from .export_panel import ExportPanel
from .batch_dialog import BatchExportDialog
from .pre_render_dialog import PreRenderDialog
from .cropper_window import ImageCropperWindow
from .frameless import CustomTitleBar, FramelessWindowMixin, DarkModalDialog
from .scrub_worker import ScrubDecodeWorker

class MainWindow(FramelessWindowMixin, QMainWindow):
    """
    Main Application Window for Frame Exporter.
    Orchestrates playback, precise frame-by-frame navigation, and lossless frame extraction.
    Frameless, polished studio UI with hardware-accelerated title bar and custom chrome.
    """
    return_to_launcher_requested = Signal(object)

    def __init__(self):
        super().__init__()
        self.resize(1200, 820)
        self.setMinimumSize(850, 600)

        self.config = ConfigManager()
        self.video_engine = VideoEngine(cache_size=120)
        self.cropper_window = None
        self.trimmer_window = None
        self._is_transitioning = False
        self.transition_group = None
        self._last_key_step_time = 0.0
        self._is_stepping_busy = False

        # Dedicated Background Video Scrub Engine for 144Hz Butter-Smooth Playhead
        self.scrub_worker = ScrubDecodeWorker(self)
        self.scrub_worker.frame_ready.connect(self._on_scrub_frame_ready)
        self.scrub_worker.start()
        
        self._setup_ui()
        self._setup_menus()
        self._setup_shortcuts()
        self.setup_frameless(self.custom_title_bar)
        from PySide6.QtCore import QCoreApplication
        app = QCoreApplication.instance()
        if app is not None:
            app.installEventFilter(self)
        else:
            self.installEventFilter(self)

    def _setup_ui(self):
        # 1. Master Root Frame with subtle 1px studio border
        root_frame = QFrame(self)
        root_frame.setObjectName("windowRootFrame")
        self.setCentralWidget(root_frame)
        
        root_layout = QVBoxLayout(root_frame)
        root_layout.setContentsMargins(0, 0, 0, 0)
        root_layout.setSpacing(0)

        # 2. Custom Frameless Title Bar with integrated menus & document status
        self.custom_title_bar = CustomTitleBar(
            title="FRAME EXPORTER",
            icon_text="🎞️",
            show_menus=True,
            parent=self
        )
        root_layout.addWidget(self.custom_title_bar)

        # 3. Main Workspace Area
        workspace = QWidget(self)
        main_layout = QVBoxLayout(workspace)
        main_layout.setContentsMargins(8, 6, 8, 4)
        main_layout.setSpacing(4)

        # Video Canvas
        self.canvas = VideoCanvas(self)
        self.canvas.file_dropped.connect(self.load_video)
        self.canvas.open_file_requested.connect(self._on_open_file_dialog)
        self.canvas.zoom_changed.connect(self._on_zoom_changed)
        main_layout.addWidget(self.canvas, 1)

        # Timeline Scrubber
        self.timeline = TimelineSlider(Qt.Horizontal, self)
        self.timeline.setRange(0, 0)
        self.timeline.frame_jumped.connect(self._on_timeline_seek)
        self.timeline.scrub_started.connect(self._on_scrub_start)
        self.timeline.scrub_finished.connect(self._on_scrub_end)
        main_layout.addWidget(self.timeline)

        # Unified Media Toolbar & Settings
        self.controls = PlaybackControls(self)
        self.controls.step_requested.connect(self._on_step_requested)
        self.controls.jump_to_frame.connect(self._seek_to_frame)
        self.controls.play_pause_toggled.connect(self._on_playback_toggled)
        self.controls.export_current_frame_requested.connect(self.export_current_frame)
        self.controls.crop_requested.connect(self.open_cropper_window)
        self.controls.copy_clipboard_requested.connect(self.copy_frame_to_clipboard)
        self.controls.batch_export_requested.connect(self.open_batch_dialog)
        self.controls.prerender_requested.connect(self.open_prerender_dialog)
        self.controls.trim_requested.connect(self.open_trim_window)
        self.export_panel = self.controls
        main_layout.addWidget(self.controls)

        root_layout.addWidget(workspace, 1)

        # 4. Modern Studio Footer Dock
        self.footer_bar = QWidget(self)
        self.footer_bar.setFixedHeight(26)
        self.footer_bar.setStyleSheet("""
            QWidget {
                background-color: #0D0D11;
                border-top: 1px solid rgba(255, 255, 255, 0.06);
                color: #94A3B8;
                font-size: 11px;
            }
        """)
        footer_layout = QHBoxLayout(self.footer_bar)
        footer_layout.setContentsMargins(10, 0, 10, 0)
        footer_layout.setSpacing(10)

        self.status_label = QLabel("● Ready • Drag & drop a video file or click Open")
        self.status_label.setStyleSheet("color: #94A3B8; font-weight: 500;")
        footer_layout.addWidget(self.status_label)

        footer_layout.addStretch()

        self.lbl_res_badge = QLabel("📐 0 × 0")
        self.lbl_res_badge.setStyleSheet("color: #F4F5F7; font-family: 'Consolas', monospace;")
        footer_layout.addWidget(self.lbl_res_badge)

        self.lbl_fps_badge = QLabel("⚡ 0 FPS")
        self.lbl_fps_badge.setStyleSheet("color: #38BDF8; font-family: 'Consolas', monospace;")
        footer_layout.addWidget(self.lbl_fps_badge)

        self.lbl_dur_badge = QLabel("⏱ 0.0s")
        self.lbl_dur_badge.setStyleSheet("color: #CBD5E1; font-family: 'Consolas', monospace;")
        footer_layout.addWidget(self.lbl_dur_badge)

        self.lbl_zoom_badge = QLabel("🔍 100%")
        self.lbl_zoom_badge.setStyleSheet("color: #A78BFA; font-family: 'Consolas', monospace;")
        footer_layout.addWidget(self.lbl_zoom_badge)

        self.lbl_quality_badge = QLabel("💎 100% Full Quality")
        self.lbl_quality_badge.setStyleSheet("color: #10B981; font-weight: 700; font-family: 'Consolas', monospace;")
        footer_layout.addWidget(self.lbl_quality_badge)

        root_layout.addWidget(self.footer_bar)

    def _setup_menus(self):
        menu_bar = self.custom_title_bar.menu_bar
        if not menu_bar:
            return

        # File Menu
        file_menu = menu_bar.addMenu("&File")

        launcher_act = QAction("✨ &Launcher Hub...", self)
        launcher_act.setShortcut("Ctrl+H")
        launcher_act.triggered.connect(lambda: self.return_to_launcher_requested.emit(self))
        file_menu.addAction(launcher_act)

        open_act = QAction("&Open Video...", self)
        open_act.setShortcut(QKeySequence.Open)
        open_act.triggered.connect(self._on_open_file_dialog)
        file_menu.addAction(open_act)

        self.recent_menu = QMenu("Open &Recent", self)
        file_menu.addMenu(self.recent_menu)
        self._update_recent_menu()

        file_menu.addSeparator()

        export_act = QAction("&Export Current Frame", self)
        export_act.setShortcut("Ctrl+S")
        export_act.triggered.connect(self.export_current_frame)
        file_menu.addAction(export_act)

        crop_act = QAction("&Crop Frame (Separate Window)...", self)
        crop_act.setShortcut("Ctrl+K")
        crop_act.triggered.connect(self.open_cropper_window)
        file_menu.addAction(crop_act)

        trim_act = QAction("✂️ &Trim & Export Video...", self)
        trim_act.setShortcut("Ctrl+T")
        trim_act.triggered.connect(self.open_trim_window)
        file_menu.addAction(trim_act)

        batch_act = QAction("&Batch Export...", self)
        batch_act.setShortcut("B")
        batch_act.triggered.connect(self.open_batch_dialog)
        file_menu.addAction(batch_act)

        open_folder_act = QAction("Open &Output Folder", self)
        open_folder_act.triggered.connect(lambda: open_in_explorer(self.export_panel.get_output_directory()))
        file_menu.addAction(open_folder_act)

        file_menu.addSeparator()

        exit_act = QAction("E&xit", self)
        exit_act.setShortcut("Ctrl+Q")
        exit_act.triggered.connect(self.close)
        file_menu.addAction(exit_act)

        # Playback Menu
        play_menu = menu_bar.addMenu("&Playback")

        play_act = QAction("&Play / Pause", self)
        play_act.setShortcut(Qt.Key_Space)
        play_act.triggered.connect(self.controls.toggle_play)
        play_menu.addAction(play_act)

        play_menu.addSeparator()

        next_act = QAction("Next Frame\t→", self)
        next_act.setShortcut(Qt.Key_Right)
        next_act.triggered.connect(lambda: self._on_step_requested(1))
        play_menu.addAction(next_act)

        prev_act = QAction("Previous Frame\t←", self)
        prev_act.setShortcut(Qt.Key_Left)
        prev_act.triggered.connect(lambda: self._on_step_requested(-1))
        play_menu.addAction(prev_act)

        next10_act = QAction("Step +10 Frames\tShift+→", self)
        next10_act.setShortcut("Shift+Right")
        next10_act.triggered.connect(lambda: self._on_step_requested(10))
        play_menu.addAction(next10_act)

        prev10_act = QAction("Step -10 Frames\tShift+←", self)
        prev10_act.setShortcut("Shift+Left")
        prev10_act.triggered.connect(lambda: self._on_step_requested(-10))
        play_menu.addAction(prev10_act)

        play_menu.addSeparator()

        start_act = QAction("Jump to Start", self)
        start_act.setShortcut(Qt.Key_Home)
        start_act.triggered.connect(lambda: self._seek_to_frame(0))
        play_menu.addAction(start_act)

        end_act = QAction("Jump to End", self)
        end_act.setShortcut(Qt.Key_End)
        end_act.triggered.connect(lambda: self._seek_to_frame(self.video_engine.total_frames - 1))
        play_menu.addAction(end_act)

        play_menu.addSeparator()

        in_act = QAction("Mark In-Point", self)
        in_act.setShortcut("I")
        in_act.triggered.connect(self._mark_in_point)
        play_menu.addAction(in_act)

        out_act = QAction("Mark Out-Point", self)
        out_act.setShortcut("O")
        out_act.triggered.connect(self._mark_out_point)
        play_menu.addAction(out_act)

        clear_markers_act = QAction("Clear In/Out Markers", self)
        clear_markers_act.triggered.connect(self._clear_range_markers)
        play_menu.addAction(clear_markers_act)

        play_menu.addSeparator()

        next_shot_act = QAction("Jump to Next Shot Cut\tPageDown / Alt+→", self)
        next_shot_act.triggered.connect(self._jump_to_next_scene_cut)
        play_menu.addAction(next_shot_act)

        prev_shot_act = QAction("Jump to Previous Shot Cut\tPageUp / Alt+←", self)
        prev_shot_act.triggered.connect(self._jump_to_prev_scene_cut)
        play_menu.addAction(prev_shot_act)

        play_menu.addSeparator()

        prerender_act = QAction("⚡ Pre-render RAM Preview...", self)
        prerender_act.setShortcut("P")
        prerender_act.triggered.connect(self.open_prerender_dialog)
        play_menu.addAction(prerender_act)

        clear_ram_act = QAction("Clear RAM Preview Cache", self)
        clear_ram_act.triggered.connect(self._clear_ram_cache)
        play_menu.addAction(clear_ram_act)

        # View Menu
        view_menu = menu_bar.addMenu("&View")

        zoom_in_act = QAction("Zoom &In", self)
        zoom_in_act.setShortcut(QKeySequence.ZoomIn)
        zoom_in_act.triggered.connect(self.canvas.zoom_in)
        view_menu.addAction(zoom_in_act)

        zoom_out_act = QAction("Zoom &Out", self)
        zoom_out_act.setShortcut(QKeySequence.ZoomOut)
        zoom_out_act.triggered.connect(self.canvas.zoom_out)
        view_menu.addAction(zoom_out_act)

        fit_act = QAction("&Fit to Window", self)
        fit_act.setShortcut("0")
        fit_act.triggered.connect(self.canvas.reset_view)
        view_menu.addAction(fit_act)

        actual_act = QAction("&100% Actual Size", self)
        actual_act.setShortcut("1")
        actual_act.triggered.connect(self.canvas.set_actual_size)
        view_menu.addAction(actual_act)

        view_menu.addSeparator()

        fullscreen_act = QAction("Toggle &Fullscreen", self)
        fullscreen_act.setShortcut(Qt.Key_F11)
        fullscreen_act.triggered.connect(self._toggle_fullscreen)
        view_menu.addAction(fullscreen_act)

        # Help Menu
        help_menu = menu_bar.addMenu("&Help")

        shortcuts_act = QAction("&Keyboard Shortcuts...", self)
        shortcuts_act.triggered.connect(self._show_shortcuts_dialog)
        help_menu.addAction(shortcuts_act)

        about_act = QAction("&About Frame Exporter", self)
        about_act.triggered.connect(self._show_about_dialog)
        help_menu.addAction(about_act)

    def _setup_shortcuts(self):
        # Quick export shortcut key 'E'
        export_action = QAction(self)
        export_action.setShortcut("E")
        export_action.triggered.connect(self.export_current_frame)
        self.addAction(export_action)

        # Quick copy shortcut key 'Ctrl+C'
        copy_action = QAction(self)
        copy_action.setShortcut(QKeySequence.Copy)
        copy_action.triggered.connect(self.copy_frame_to_clipboard)
        self.addAction(copy_action)

        # Quick pre-render RAM preview shortcut 'P'
        prerender_action = QAction(self)
        prerender_action.setShortcut("P")
        prerender_action.triggered.connect(self.open_prerender_dialog)
        self.addAction(prerender_action)

    def eventFilter(self, watched, event):
        """Global key event filter to ensure arrow keys work anywhere in the window."""
        if event.type() == QEvent.KeyPress:
            # Only intercept if this window is visible and active (or contains focus)
            from PySide6.QtWidgets import QApplication
            if not self.isVisible() or not (self.isActiveWindow() or QApplication.activeWindow() == self or self.isAncestorOf(QApplication.focusWidget())):
                return super().eventFilter(watched, event)

            # If user is currently typing in a line edit, don't hijack text keys
            focused = QApplication.focusWidget()
            from PySide6.QtWidgets import QLineEdit, QSpinBox
            if isinstance(focused, (QLineEdit, QSpinBox)):
                return super().eventFilter(watched, event)

            key = event.key()
            modifiers = event.modifiers()

            if key == Qt.Key_Left:
                import time
                now = time.perf_counter()
                if event.isAutoRepeat() and (now - self._last_key_step_time) < 0.040:
                    return True
                if self._is_stepping_busy:
                    return True
                self._last_key_step_time = now

                if modifiers & Qt.AltModifier:
                    self._jump_to_prev_scene_cut()
                elif modifiers & Qt.ShiftModifier:
                    self._on_step_requested(-10)
                elif modifiers & Qt.ControlModifier:
                    self._on_step_requested(-int(self.video_engine.fps))
                else:
                    self._on_step_requested(-1)
                return True
            elif key == Qt.Key_Right:
                import time
                now = time.perf_counter()
                if event.isAutoRepeat() and (now - self._last_key_step_time) < 0.040:
                    return True
                if self._is_stepping_busy:
                    return True
                self._last_key_step_time = now

                if modifiers & Qt.AltModifier:
                    self._jump_to_next_scene_cut()
                elif modifiers & Qt.ShiftModifier:
                    self._on_step_requested(10)
                elif modifiers & Qt.ControlModifier:
                    self._on_step_requested(int(self.video_engine.fps))
                else:
                    self._on_step_requested(1)
                return True
            elif key == Qt.Key_PageDown:
                self._jump_to_next_scene_cut()
                return True
            elif key == Qt.Key_PageUp:
                self._jump_to_prev_scene_cut()
                return True
            elif key == Qt.Key_Space:
                self.controls.toggle_play()
                return True
            elif key == Qt.Key_E and not (modifiers & Qt.ControlModifier):
                self.export_current_frame()
                return True
            elif key == Qt.Key_P and not (modifiers & Qt.ControlModifier):
                self.open_prerender_dialog()
                return True
            elif key == Qt.Key_T and (modifiers & Qt.ControlModifier):
                self.open_trim_window()
                return True

        return super().eventFilter(watched, event)

    # --- Video Operations ---
    def load_video(self, file_path: str):
        if not file_path or not os.path.exists(file_path):
            return

        self.controls.pause()
        ok = self.video_engine.open(file_path)
        if not ok:
            QMessageBox.critical(self, "Error", f"Could not open video file:\n{file_path}")
            return

        info = self.video_engine.get_info()
        w, h, fps, total = info["width"], info["height"], info["fps"], info["total_frames"]
        self.scrub_worker.set_source(file_path)

        # Update Timeline
        self.timeline.blockSignals(True)
        self.timeline.setRange(0, total - 1)
        self.timeline.setValue(0)
        self.timeline.set_fps(fps)
        self.timeline.set_range_markers(None, None)
        self.timeline.set_scene_cuts([])
        self.timeline.blockSignals(False)

        # Update Controls
        self.controls.set_video_info(total, fps, w, h)

        # Update Export Panel
        self.export_panel.set_video_context(file_path, w, h, fps)

        # Display first frame
        first_frame = self.video_engine.get_frame(0)
        self.canvas.set_frame(first_frame)
        self.canvas.reset_view()

        # Update Window title bar and Status Badges
        self.custom_title_bar.set_status_pill(f"🎬 {info['filename']}  •  {w}×{h}  •  {fps:.2f} fps", is_active=True)
        self.status_label.setText(f"● {info['filename']} ({total:,} frames)")
        self.status_label.setStyleSheet("color: #10b981; font-weight: 600;")
        self.lbl_res_badge.setText(f"📐 {w} × {h}")
        self.lbl_fps_badge.setText(f"⚡ {fps:.2f} FPS")
        self.lbl_dur_badge.setText(f"⏱ {self.video_engine.duration_sec:.1f}s")

        self.config.add_recent_file(file_path)
        self._update_recent_menu()
        self._update_timeline_cache_bar()

    def _on_zoom_changed(self, zoom: float):
        self.lbl_zoom_badge.setText(f"🔍 {int(round(zoom * 100))}%")

    def _on_step_requested(self, delta: int):
        if not self.video_engine.is_loaded:
            return
            
        current = self.video_engine.current_frame_idx
        target = current + delta
        
        # Loop playback if playing
        if self.controls.is_playing:
            if target >= self.video_engine.total_frames:
                target = 0
            elif target < 0:
                target = self.video_engine.total_frames - 1
        else:
            target = max(0, min(target, self.video_engine.total_frames - 1))

        self._seek_to_frame(target)
        if self.controls.is_playing:
            self.controls.reset_playback_anchor()

    def _seek_to_frame(self, target_frame: int):
        if not self.video_engine.is_loaded:
            return
            
        self._is_stepping_busy = True
        try:
            frame = self.video_engine.get_frame(target_frame)
            if frame is not None:
                self.canvas.set_frame(frame)
                current_idx = self.video_engine.current_frame_idx
                
                # Sync timeline slider without looping back signals
                self.timeline.blockSignals(True)
                self.timeline.setValue(current_idx)
                self.timeline.blockSignals(False)
                
                # Sync controls & timecode
                self.controls.update_position(current_idx)

                # Proactively pre-fetch adjacent frames in background for 0ms arrow stepping
                if not self.controls.is_playing:
                    self.video_engine.trigger_adjacent_prefetch(current_idx)
        finally:
            self._is_stepping_busy = False

    def _on_scrub_frame_ready(self, frame, frame_idx: int):
        """Asynchronously stream decoded preview frame into main canvas."""
        if not self.video_engine.is_loaded:
            return
        self.video_engine.put_frame_in_cache(frame_idx, frame)
        self.canvas.set_frame(frame)

    def _on_timeline_seek(self, frame_idx: int):
        if getattr(self.timeline, "_is_scrubbing", False):
            # Instant UI feedback (0ms latency)
            self.controls.update_position(frame_idx)
            # Check RAM cache first (0ms latency)
            cached = self.video_engine.frame_cache.get(frame_idx)
            if cached is not None:
                self.canvas.set_frame(cached)
                return
            # Async background decode without locking the UI
            self.scrub_worker.request_frame(frame_idx)
        else:
            self._seek_to_frame(frame_idx)
            if self.controls.is_playing:
                self.controls.reset_playback_anchor()

    def _on_scrub_start(self):
        self._was_playing_before_scrub = self.controls.is_playing
        if self.controls.is_playing:
            self.controls.pause()

    def _on_scrub_end(self):
        if self.video_engine.is_loaded:
            self._seek_to_frame(self.timeline.value())
        if getattr(self, "_was_playing_before_scrub", False):
            self.controls.play()

    def _on_playback_toggled(self, is_playing: bool):
        pass

    # --- In / Out Range Markers ---
    def _mark_in_point(self):
        if self.video_engine.is_loaded:
            self.video_engine.in_point = self.video_engine.current_frame_idx
            self.timeline.set_range_markers(self.video_engine.in_point, self.video_engine.out_point)
            self.status_label.setText(f"In-point marked at frame {self.video_engine.in_point}")

    def _mark_out_point(self):
        if self.video_engine.is_loaded:
            self.video_engine.out_point = self.video_engine.current_frame_idx
            self.timeline.set_range_markers(self.video_engine.in_point, self.video_engine.out_point)
            self.status_label.setText(f"Out-point marked at frame {self.video_engine.out_point}")

    def _clear_range_markers(self):
        if self.video_engine.is_loaded:
            self.video_engine.in_point = None
            self.video_engine.out_point = None
            self.timeline.set_range_markers(None, None)
            self.status_label.setText("In/Out markers cleared")

    # --- Frame Export & Clipboard ---
    def export_current_frame(self):
        if not self.video_engine.is_loaded:
            QMessageBox.information(self, "No Video", "Please open a video before exporting frames.")
            return

        frame_idx = self.video_engine.current_frame_idx
        dest_path = self.export_panel.get_target_filepath(frame_idx)
        ext = self.export_panel.get_export_extension()
        quality = self.export_panel.get_quality()

        # Immediate zero-latency UI confirmation
        self.export_panel.show_export_success()

        # Grab in-memory frame directly without touching video decoder pointer
        frame = None
        if self.video_engine.last_decoded_frame is not None:
            frame = self.video_engine.last_decoded_frame.copy()
        elif frame_idx in self.video_engine.frame_cache:
            frame = self.video_engine.frame_cache[frame_idx].copy()
        else:
            raw = self.video_engine.get_frame(frame_idx)
            frame = raw.copy() if raw is not None else None

        if frame is None:
            QMessageBox.critical(self, "Export Error", f"Could not read frame {frame_idx}")
            return

        # Perform PNG/JPEG encoding & disk I/O in background thread so Left/Right arrows respond instantly!
        import threading
        def _bg_save(f_data, out_p, f_ext, q, idx):
            success, saved_file, file_size = self.video_engine.save_frame_to_file(f_data, out_p, f_ext, q)
            if success:
                self.status_label.setText(f"✓ Frame {idx} saved ({format_file_size(file_size)})")

        threading.Thread(target=_bg_save, args=(frame, dest_path, ext, quality, frame_idx), daemon=True).start()
        # Ensure adjacent frames are pre-cached so subsequent Left/Right arrows respond in 0ms
        self.video_engine.trigger_adjacent_prefetch(frame_idx)

    def copy_frame_to_clipboard(self):
        if not self.video_engine.is_loaded or self.canvas.current_qimage is None:
            return

        full_img = self.canvas.get_full_res_qimage()
        if full_img is not None:
            clipboard = QGuiApplication.clipboard()
            clipboard.setImage(full_img)
            self.export_panel.show_copy_success()
            self.status_label.setText("✓ Frame copied to clipboard at original resolution")

    def open_cropper_window(self):
        if self._is_transitioning:
            return
        self._is_transitioning = True

        # Pause playback if playing
        if self.controls.is_playing:
            self.controls.pause()

        if self.cropper_window is None:
            # Independent top-level window so hiding main window does not hide the cropper
            self.cropper_window = ImageCropperWindow(parent=None)
            self.cropper_window.window_closed.connect(self._on_cropper_window_closed)

        self.cropper_window.btn_back.setText("← Back to Video")
        self.cropper_window.btn_launcher.show()

        if self.video_engine.is_loaded:
            current_idx = self.video_engine.current_frame_idx
            frame = self.video_engine.get_frame(current_idx)
            if frame is not None:
                info = self.video_engine.get_info()
                source_stem = Path(info["filename"]).stem if info["filename"] else "frame"
                self.cropper_window.load_frame(frame, source_name=source_stem, frame_idx=current_idx)

        # 1. Match geometry and maximized state precisely so window never jumps on screen
        is_max = self.isMaximized()
        current_geom = self.geometry()

        if is_max:
            self.cropper_window.showMaximized()
        else:
            self.cropper_window.setGeometry(current_geom)
            self.cropper_window.showNormal()

        self.cropper_window.setWindowOpacity(1.0)
        self.cropper_window.raise_()
        self.cropper_window.activateWindow()

        # Hide main window after cropper is painted in foreground
        def on_open_finished():
            self.hide()
            self._is_transitioning = False

        QTimer.singleShot(35, on_open_finished)

    def _on_cropper_window_closed(self):
        # Seamlessly return from cropper_window back to main window
        if self._is_transitioning:
            return
        self._is_transitioning = True

        # Synchronize geometry and maximized state back
        is_max = self.cropper_window.isMaximized()
        cropper_geom = self.cropper_window.geometry()

        if is_max:
            self.showMaximized()
        else:
            self.setGeometry(cropper_geom)
            self.showNormal()

        self.setWindowOpacity(1.0)
        self.raise_()
        self.activateWindow()

        # Hide cropper after main window is painted in foreground
        def on_return_finished():
            self.cropper_window.hide()
            self._is_transitioning = False

        QTimer.singleShot(35, on_return_finished)

    def closeEvent(self, event):
        from PySide6.QtCore import QCoreApplication
        app = QCoreApplication.instance()
        if app is not None:
            try:
                app.removeEventFilter(self)
            except Exception:
                pass
        if hasattr(self, 'controls') and getattr(self.controls, 'is_playing', False):
            self.controls.pause()
        if hasattr(self, 'scrub_worker') and self.scrub_worker:
            self.scrub_worker.stop()
        if self.cropper_window:
            self.cropper_window.force_close()
        if getattr(self, "return_to_launcher_on_close", False):
            self.return_to_launcher_requested.emit(self)
            event.ignore()
            return
        super().closeEvent(event)

    def open_batch_dialog(self):
        if not self.video_engine.is_loaded:
            QMessageBox.information(self, "No Video", "Please open a video first.")
            return

        dlg = BatchExportDialog(
            self.video_engine,
            self.export_panel.get_output_directory(),
            self.export_panel.get_naming_template(),
            self.export_panel.get_export_extension(),
            self.export_panel.get_quality(),
            self
        )
        dlg.exec()

    def open_prerender_dialog(self):
        """Open high-speed RAM Preview Pre-render dialog."""
        if not self.video_engine.is_loaded:
            QMessageBox.information(self, "No Video", "Please open a video before pre-rendering.")
            return

        dlg = PreRenderDialog(self.video_engine, self)
        dlg.cache_updated.connect(self._update_timeline_cache_bar)
        dlg.exec()
        self._update_timeline_cache_bar()

    def _update_timeline_cache_bar(self):
        """Update timeline glowing green RAM preview cache bar."""
        if self.video_engine.is_loaded:
            ranges = self.video_engine.get_cached_ranges()
            self.timeline.set_cached_ranges(ranges)

    def _clear_ram_cache(self):
        """Purge pre-rendered RAM cache and clear timeline cache line."""
        self.video_engine.clear_cache()
        self._update_timeline_cache_bar()
        self.status_label.setText("● RAM preview cache cleared")

    # --- Shot Cut Navigation ---
    def _jump_to_next_scene_cut(self):
        if not self.video_engine.is_loaded:
            return
        if not self.video_engine.scene_cuts:
            self.status_label.setText("● No shot cuts detected")
            return
        curr = self.video_engine.current_frame_idx
        nxt = self.video_engine.get_next_scene_cut(curr)
        if nxt is not None:
            self._seek_to_frame(nxt)
            self.status_label.setText(f"🎬 Jumped to Next Shot Cut at frame {nxt}")
        else:
            self.status_label.setText("● Already at the last detected shot cut")

    def _jump_to_prev_scene_cut(self):
        if not self.video_engine.is_loaded:
            return
        if not self.video_engine.scene_cuts:
            self.status_label.setText("● No shot cuts detected")
            return
        curr = self.video_engine.current_frame_idx
        prev = self.video_engine.get_prev_scene_cut(curr)
        if prev is not None:
            self._seek_to_frame(prev)
            self.status_label.setText(f"🎬 Jumped to Previous Shot Cut at frame {prev}")
        else:
            self.status_label.setText("● Already at the first detected shot cut")

    def open_trim_window(self):
        """Open Video Trimmer Window as an independent studio window."""
        if self._is_transitioning:
            return
        self._is_transitioning = True

        # Pause playback if playing
        if self.controls.is_playing:
            self.controls.pause()

        if self.trimmer_window is None:
            from .trim_window import VideoTrimmerWindow
            self.trimmer_window = VideoTrimmerWindow(parent=None)
            self.trimmer_window.btn_back.setText("← Back to Extractor")
            self.trimmer_window.window_closed.connect(self._on_trimmer_window_closed)

        if self.video_engine.is_loaded:
            self.trimmer_window.load_video(self.video_engine.video_path)
            if getattr(self.video_engine, 'has_preview_stream', False) and getattr(self.video_engine, 'preview_path', None):
                self.trimmer_window.video_engine.open_preview_stream(self.video_engine.preview_path)
            if self.video_engine.in_point is not None:
                self.trimmer_window.set_in_point(self.video_engine.in_point)
            if self.video_engine.out_point is not None:
                self.trimmer_window.set_out_point(self.video_engine.out_point)
            self.trimmer_window.seek_to_frame(self.video_engine.current_frame_idx)

        # Match geometry and maximized state precisely
        is_max = self.isMaximized()
        current_geom = self.geometry()

        if is_max:
            self.trimmer_window.showMaximized()
        else:
            self.trimmer_window.setGeometry(current_geom)
            self.trimmer_window.showNormal()

        self.trimmer_window.setWindowOpacity(1.0)
        self.trimmer_window.raise_()
        self.trimmer_window.activateWindow()

        def on_open_finished():
            self.hide()
            self._is_transitioning = False

        QTimer.singleShot(35, on_open_finished)

    def _on_trimmer_window_closed(self):
        """Return from trimmer window back to main window."""
        if self._is_transitioning:
            return
        self._is_transitioning = True

        is_max = self.trimmer_window.isMaximized()
        trim_geom = self.trimmer_window.geometry()

        if is_max:
            self.showMaximized()
        else:
            self.setGeometry(trim_geom)
            self.showNormal()

        self.setWindowOpacity(1.0)
        self.raise_()
        self.activateWindow()

        # Sync back In/Out markers if set in trimmer
        if self.trimmer_window.in_point != 0 or self.trimmer_window.out_point != (self.video_engine.total_frames - 1):
            self.video_engine.in_point = self.trimmer_window.in_point
            self.video_engine.out_point = self.trimmer_window.out_point
            self.timeline.set_range_markers(self.video_engine.in_point, self.video_engine.out_point)

        def on_return_finished():
            self._is_transitioning = False

        QTimer.singleShot(35, on_return_finished)

    # --- UI Actions ---
    def _on_open_file_dialog(self):
        filter_str = "Video Files (*.mp4 *.mkv *.mov *.avi *.webm *.m4v *.flv *.wmv *.ts);;All Files (*.*)"
        chosen, _ = QFileDialog.getOpenFileName(self, "Open Video File", "", filter_str)
        if chosen:
            self.load_video(chosen)

    def _update_recent_menu(self):
        self.recent_menu.clear()
        recents = self.config.get("recent_files", [])
        if not recents:
            empty_act = self.recent_menu.addAction("No recent files")
            empty_act.setEnabled(False)
            return

        for path in recents:
            if os.path.exists(path):
                act = self.recent_menu.addAction(Path(path).name)
                act.setData(path)
                act.triggered.connect(lambda checked, p=path: self.load_video(p))

    def _toggle_fullscreen(self):
        if self.isFullScreen():
            self.showNormal()
        else:
            self.showFullScreen()

    def _show_shortcuts_dialog(self):
        dlg = DarkModalDialog(title="Keyboard Shortcuts", parent=self)
        dlg.resize(480, 520)
        lbl = QLabel(dlg.content_widget)
        lbl.setTextFormat(Qt.RichText)
        lbl.setStyleSheet("color: #cbd5e1; font-size: 12px;")
        lbl.setText("""
        <table border="0" cellpadding="4" cellspacing="0" style="color: #cbd5e1; width: 100%;">
            <tr style="background-color: #141824;"><td style="color: #38bdf8;"><b>← / →</b></td><td>Step 1 frame backward / forward</td></tr>
            <tr><td style="color: #38bdf8;"><b>Shift + ← / →</b></td><td>Step 10 frames backward / forward</td></tr>
            <tr style="background-color: #141824;"><td style="color: #38bdf8;"><b>Ctrl + ← / →</b></td><td>Jump 1 second backward / forward</td></tr>
            <tr><td style="color: #38bdf8;"><b>Spacebar</b></td><td>Play / Pause video playback</td></tr>
            <tr><td style="color: #34d399;"><b>E or Ctrl+S</b></td><td><b>Export Frame (100% Original Quality)</b></td></tr>
            <tr style="background-color: #141824;"><td style="color: #10b981;"><b>Ctrl+T</b></td><td><b>Video Trimmer & Lossless Cutter</b></td></tr>
            <tr><td style="color: #a78bfa;"><b>Ctrl+K</b></td><td><b>Open Image Cropper Window</b></td></tr>
            <tr><td style="color: #38bdf8;"><b>Ctrl+C</b></td><td>Copy frame to clipboard</td></tr>
            <tr style="background-color: #141824;"><td style="color: #38bdf8;"><b>Home / End</b></td><td>Jump to video start / end</td></tr>
            <tr><td style="color: #38bdf8;"><b>I / O</b></td><td>Set In / Out markers for range export</td></tr>
            <tr style="background-color: #141824;"><td style="color: #38bdf8;"><b>P</b></td><td>Pre-render RAM Preview</td></tr>
            <tr><td style="color: #38bdf8;"><b>B</b></td><td>Open Batch Export dialog</td></tr>
            <tr style="background-color: #141824;"><td style="color: #38bdf8;"><b>0 / 1</b></td><td>Fit to window / 100% Actual size</td></tr>
            <tr><td style="color: #38bdf8;"><b>Mouse Wheel</b></td><td>Smooth canvas zoom</td></tr>
            <tr style="background-color: #141824;"><td style="color: #38bdf8;"><b>F11</b></td><td>Toggle Fullscreen mode</td></tr>
        </table>
        """)
        dlg.content_layout.addWidget(lbl)
        
        btn_ok = QPushButton("Got it", dlg.content_widget)
        btn_ok.setFixedHeight(30)
        btn_ok.setObjectName("primaryBtn")
        btn_ok.clicked.connect(dlg.close)
        dlg.content_layout.addWidget(btn_ok)
        dlg.show()

    def _show_about_dialog(self):
        dlg = DarkModalDialog(title="About Frame Exporter", parent=self)
        dlg.resize(420, 260)
        lbl = QLabel(dlg.content_widget)
        lbl.setTextFormat(Qt.RichText)
        lbl.setStyleSheet("color: #cbd5e1; font-size: 12px; line-height: 1.6;")
        lbl.setText("""
        <h3 style="color: #ffffff; margin-top: 0;">🎞️ Frame Exporter Studio</h3>
        <p style="color: #94a3b8;">High-Precision 4K Video Frame Extraction & Cropping Suite</p>
        <ul style="color: #cbd5e1; padding-left: 20px;">
            <li>Zero-Copy SIMD hardware-accelerated playback</li>
            <li>Lossless export at 100% original pixel resolution</li>
            <li>Smart Cropper with active letterbox / black bar detection</li>
            <li>Sub-pixel precision zoom loupe & 1px keyboard nudging</li>
        </ul>
        """)
        dlg.content_layout.addWidget(lbl)

        btn_ok = QPushButton("Close", dlg.content_widget)
        btn_ok.setFixedHeight(30)
        btn_ok.setObjectName("primaryBtn")
        btn_ok.clicked.connect(dlg.close)
        dlg.content_layout.addWidget(btn_ok)
        dlg.show()
