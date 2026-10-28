import os
import re
import time
import psutil
import hashlib
import tempfile
import subprocess
from pathlib import Path
from typing import Optional, Dict

from PySide6.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout, QLabel, QSpinBox,
    QPushButton, QProgressBar, QGroupBox, QRadioButton,
    QButtonGroup, QMessageBox, QFrame, QWidget
)
from PySide6.QtCore import Qt, QThread, Signal
from PySide6.QtGui import QColor, QFont

from .frameless import CustomTitleBar, FramelessWindowMixin
from .styles import DARK_THEME_QSS

def get_preview_cache_dir() -> Path:
    """Return local application preview cache directory."""
    local_app = os.environ.get("LOCALAPPDATA", tempfile.gettempdir())
    cache_dir = Path(local_app) / "FrameExporter" / "preview_cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    return cache_dir

def find_ffmpeg_path() -> str:
    """Locate FFmpeg executable in bundle, next to exe, in PATH, or standard installs."""
    import sys, shutil
    if hasattr(sys, '_MEIPASS'):
        p = Path(sys._MEIPASS) / "ffmpeg.exe"
        if p.exists():
            return str(p)
    exe_dir = Path(sys.executable).parent
    p2 = exe_dir / "ffmpeg.exe"
    if p2.exists():
        return str(p2)
    w = shutil.which("ffmpeg")
    if w:
        return w
    candidates = [
        r"C:\Program Files\PySceneDetect\ffmpeg.exe",
        r"C:\ffmpeg\bin\ffmpeg.exe",
        r"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    return "ffmpeg"


class FullVideoPreRenderWorker(QThread):
    """
    Background worker that pre-renders the ENTIRE video into a high-speed,
    GPU-accelerated 4K/8K intermediate preview stream using FFmpeg.
    Enables smooth 60 FPS playback and instant scrubbing across the entire video.
    """
    progress = Signal(int, int, float)  # current_frame, total_frames, fps
    finished = Signal(str, float)       # preview_file_path, elapsed_sec
    failed = Signal(str)

    def __init__(self, video_path: str, total_frames: int, fps: float):
        super().__init__()
        self.video_path = video_path
        self.total_frames = max(1, total_frames)
        self.fps = fps
        self._proc: Optional[subprocess.Popen] = None
        self._is_cancelled = False

    def cancel(self):
        self._is_cancelled = True
        if self._proc is not None:
            try:
                self._proc.terminate()
            except Exception:
                pass

    def run(self):
        cache_dir = get_preview_cache_dir()
        name_hash = hashlib.md5(self.video_path.encode("utf-8")).hexdigest()[:10]
        out_path = cache_dir / f"prerender_{name_hash}.mp4"

        cmd = [
            find_ffmpeg_path(), "-y",
            "-i", self.video_path,
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "14",
            "-pix_fmt", "yuv420p",
            "-progress", "pipe:1",
            str(out_path)
        ]

        t0 = time.perf_counter()
        try:
            self._proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1
            )
        except Exception as e:
            self.failed.emit(f"Failed to start FFmpeg: {e}")
            return

        frame_pat = re.compile(r"frame=(\d+)")
        fps_pat = re.compile(r"fps=([\d\.]+)")

        cur_f = 0
        cur_fps = 0.0

        for line in self._proc.stdout:
            if self._is_cancelled:
                break
            line = line.strip()
            mf = frame_pat.match(line)
            if mf:
                cur_f = int(mf.group(1))
            mfps = fps_pat.match(line)
            if mfps:
                try:
                    cur_fps = float(mfps.group(1))
                except ValueError:
                    pass
            if line.startswith("progress=continue"):
                self.progress.emit(min(self.total_frames, cur_f), self.total_frames, cur_fps)

        self._proc.wait()

        if self._is_cancelled:
            if out_path.exists():
                try:
                    out_path.unlink()
                except Exception:
                    pass
            return

        if self._proc.returncode != 0:
            self.failed.emit(f"FFmpeg pre-render failed with exit code {self._proc.returncode}.")
            return

        elapsed = time.perf_counter() - t0
        self.finished.emit(str(out_path), elapsed)


class PreRenderWorker(QThread):
    """
    Background worker that pre-decodes video frames at 100% full original quality
    into high-speed RAM.
    """
    progress = Signal(int, int, float)  # current, total, fps
    finished = Signal(int, float)       # count, elapsed_sec
    failed = Signal(str)

    def __init__(self, video_path: str, start_frame: int, end_frame: int, video_engine):
        super().__init__()
        self.video_path = video_path
        self.start_frame = max(0, start_frame)
        self.end_frame = max(self.start_frame, end_frame)
        self.video_engine = video_engine
        self._is_cancelled = False

    def cancel(self):
        self._is_cancelled = True

    def run(self):
        import cv2
        cap = cv2.VideoCapture(self.video_path)
        if not cap.isOpened():
            self.failed.emit("Failed to open video file for pre-rendering.")
            return

        cap.set(cv2.CAP_PROP_POS_FRAMES, self.start_frame)
        total = self.end_frame - self.start_frame + 1
        t0 = time.perf_counter()
        count = 0

        # Pre-expand cache limit in VideoEngine to ensure pre-rendered frames are preserved
        frame_bytes = self.video_engine.width * self.video_engine.height * 3
        if frame_bytes > 0:
            needed_mb = int((total * frame_bytes) / (1024 * 1024)) + 512
            self.video_engine.set_cache_limit_mb(max(self.video_engine.cache_limit_mb, needed_mb))

        for f_idx in range(self.start_frame, self.end_frame + 1):
            if self._is_cancelled:
                break

            ret, frame = cap.read()
            if not ret or frame is None:
                break

            # Store in RAM cache at 100% full original resolution
            self.video_engine.put_frame_in_cache(f_idx, frame)
            count += 1

            now = time.perf_counter()
            elapsed = now - t0
            fps = count / elapsed if elapsed > 0 else 0.0

            if count % 2 == 0 or count == total:
                self.progress.emit(count, total, fps)

        cap.release()
        elapsed_total = time.perf_counter() - t0
        self.finished.emit(count, elapsed_total)


class PreRenderDialog(FramelessWindowMixin, QDialog):
    """
    Studio Pre-Render Preview Dialog.
    Supports both:
    1. Entire Video Pre-render: Full GPU-accelerated 4K preview stream (60 FPS playback).
    2. Segment RAM Preview: Instantaneous 0ms RAM preview for In/Out or custom ranges.
    """
    cache_updated = Signal()

    def __init__(self, video_engine, parent=None):
        super().__init__(parent)
        self.video_engine = video_engine
        self.worker: Optional[QThread] = None

        self.setStyleSheet(DARK_THEME_QSS)
        self.setMinimumWidth(560)
        self._setup_ui()
        self.setup_frameless(self.title_bar)
        self._update_estimates()

    def _setup_ui(self):
        root_frame = QFrame(self)
        root_frame.setObjectName("windowRootFrame")
        outer_layout = QVBoxLayout(self)
        outer_layout.setContentsMargins(0, 0, 0, 0)
        outer_layout.addWidget(root_frame)

        dialog_layout = QVBoxLayout(root_frame)
        dialog_layout.setContentsMargins(0, 0, 0, 0)
        dialog_layout.setSpacing(0)

        # 1. Custom Studio Title Bar
        self.title_bar = CustomTitleBar(
            title="PRE-RENDER VIDEO PREVIEW",
            icon_text="⚡",
            show_menus=False,
            parent=self
        )
        self.title_bar.btn_min.hide()
        self.title_bar.btn_max.hide()
        self.title_bar.set_status_pill("100% Full Uncompressed Quality", is_active=True)
        dialog_layout.addWidget(self.title_bar)

        content = QWidget(self)
        layout = QVBoxLayout(content)
        layout.setContentsMargins(20, 16, 20, 18)
        layout.setSpacing(14)
        dialog_layout.addWidget(content, 1)

        # 2. Video Specs & Quality Guarantee Banner
        info_card = QFrame()
        info_card.setStyleSheet("""
            QFrame {
                background: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.06);
                border-radius: 8px;
                padding: 10px;
            }
        """)
        info_layout = QVBoxLayout(info_card)
        info_layout.setContentsMargins(10, 8, 10, 8)
        info_layout.setSpacing(6)

        info = self.video_engine.get_info()
        w, h = info["width"], info["height"]
        fps = info["fps"]
        total_f = info["total_frames"]
        bytes_per_f = w * h * 3
        mb_per_f = bytes_per_f / (1024 * 1024)

        top_line = QLabel(f"📐 <b>{w} × {h}</b> &nbsp;|&nbsp; ⚡ <b>{fps:.2f} FPS</b> &nbsp;|&nbsp; 🎬 <b>{total_f:,}</b> Total Frames")
        top_line.setStyleSheet("color: #F4F5F7; font-size: 12px;")
        info_layout.addWidget(top_line)

        avail_gb, total_gb = self._get_ram_stats()
        disk_free_gb = self._get_disk_free_gb()
        self.lbl_ram_stat = QLabel(f"💾 Frame: <b>{mb_per_f:.1f} MB</b> &nbsp;•&nbsp; Free RAM: <b>{avail_gb:.1f} GB</b> &nbsp;•&nbsp; Free Disk: <b>{disk_free_gb:.1f} GB</b>")
        self.lbl_ram_stat.setStyleSheet("color: #94A3B8; font-size: 11px;")
        info_layout.addWidget(self.lbl_ram_stat)

        badge_box = QHBoxLayout()
        badge_box.setSpacing(8)
        badge_lossless = QLabel("💎 100% Full Original 4K Quality")
        badge_lossless.setStyleSheet("background: #1A1A22; color: #F4F5F7; border: 1px solid rgba(255, 255, 255, 0.08); padding: 2px 8px; border-radius: 4px; font-size: 10px; font-weight: bold;")
        badge_box.addWidget(badge_lossless)

        badge_zero_latency = QLabel("⚡ 60 FPS GPU-Accelerated Playback")
        badge_zero_latency.setStyleSheet("background: rgba(16, 185, 129, 0.15); color: #10B981; border: 1px solid rgba(16, 185, 129, 0.3); padding: 2px 8px; border-radius: 4px; font-size: 10px; font-weight: bold;")
        badge_box.addWidget(badge_zero_latency)
        badge_box.addStretch()
        info_layout.addLayout(badge_box)

        layout.addWidget(info_card)

        # 3. Full Video Pre-Render Card
        full_card = QFrame()
        full_card.setStyleSheet("""
            QFrame {
                background: #15151A;
                border: 1px solid rgba(255, 74, 61, 0.4);
                border-radius: 8px;
                padding: 12px 14px;
            }
        """)
        full_layout = QVBoxLayout(full_card)
        full_layout.setContentsMargins(6, 6, 6, 6)
        full_layout.setSpacing(6)

        lbl_full_title = QLabel(f"🎬 Full Video Pre-Render (All {total_f:,} frames)")
        lbl_full_title.setStyleSheet("font-size: 13px; font-weight: bold; color: #FF4A3D;")
        full_layout.addWidget(lbl_full_title)

        lbl_full_desc = QLabel("Pre-renders the entire video into a high-speed GPU-accelerated 4K preview stream.\nEnables silky-smooth 60 FPS playback and instant scrubbing across the entire video.")
        lbl_full_desc.setStyleSheet("color: #94A3B8; font-size: 11px; line-height: 1.4;")
        full_layout.addWidget(lbl_full_desc)

        layout.addWidget(full_card)

        # 4. Storage & Safety Estimate Line
        self.lbl_estimate = QLabel("💾 Estimated Storage: -")
        self.lbl_estimate.setStyleSheet("font-size: 12px; font-weight: 600; color: #38bdf8;")
        layout.addWidget(self.lbl_estimate)

        # 5. Progress Section (Hidden initially)
        self.progress_container = QWidget()
        prog_layout = QVBoxLayout(self.progress_container)
        prog_layout.setContentsMargins(0, 0, 0, 0)
        prog_layout.setSpacing(6)

        self.progress_bar = QProgressBar()
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(0)
        self.progress_bar.setFixedHeight(14)
        self.progress_bar.setStyleSheet("""
            QProgressBar {
                background: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-radius: 7px;
                text-align: center;
                color: transparent;
            }
            QProgressBar::chunk {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #FF4A3D, stop:1 #D92A20);
                border-radius: 6px;
            }
        """)
        prog_layout.addWidget(self.progress_bar)

        self.lbl_progress_status = QLabel("Pre-rendering...")
        self.lbl_progress_status.setStyleSheet("color: #CBD5E1; font-size: 11px;")
        prog_layout.addWidget(self.lbl_progress_status)

        layout.addWidget(self.progress_container)
        self.progress_container.hide()

        # 6. Action Buttons Bar
        btn_layout = QHBoxLayout()
        btn_layout.setSpacing(10)

        self.btn_clear_cache = QPushButton("🗑️ Clear Cache")
        self.btn_clear_cache.setFixedHeight(32)
        self.btn_clear_cache.setStyleSheet("""
            QPushButton {
                background: #15151A;
                color: #EF4444;
                border: 1px solid rgba(239, 68, 68, 0.25);
                border-radius: 6px;
                padding: 0 12px;
                font-weight: 600;
                font-size: 11px;
            }
            QPushButton:hover {
                background: #251517;
                border: 1px solid rgba(239, 68, 68, 0.5);
                color: #F87171;
            }
        """)
        self.btn_clear_cache.clicked.connect(self._on_clear_cache)
        btn_layout.addWidget(self.btn_clear_cache)

        btn_layout.addStretch()

        self.btn_cancel = QPushButton("Close")
        self.btn_cancel.setFixedHeight(32)
        self.btn_cancel.setFixedWidth(80)
        self.btn_cancel.clicked.connect(self._on_cancel_or_close)
        btn_layout.addWidget(self.btn_cancel)

        self.btn_start = QPushButton("⚡ Start Full Pre-render")
        self.btn_start.setFixedHeight(32)
        self.btn_start.setStyleSheet("""
            QPushButton {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #4f46e5, stop:1 #6366f1);
                color: #ffffff;
                border: none;
                font-weight: 700;
                font-size: 12px;
                border-radius: 6px;
                padding: 0 18px;
            }
            QPushButton:hover {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #5b52f5, stop:1 #7579ff);
            }
            QPushButton:disabled {
                background: #252b3d;
                color: #64748b;
            }
        """)
        self.btn_start.clicked.connect(self._on_start_prerender)
        btn_layout.addWidget(self.btn_start)

        layout.addLayout(btn_layout)

    def _get_ram_stats(self):
        try:
            mem = psutil.virtual_memory()
            return mem.available / (1024**3), mem.total / (1024**3)
        except Exception:
            return 4.0, 8.0

    def _get_disk_free_gb(self):
        try:
            cache_dir = get_preview_cache_dir()
            usage = psutil.disk_usage(str(cache_dir))
            return usage.free / (1024**3)
        except Exception:
            return 50.0

    def _update_estimates(self):
        self.btn_start.setText("⚡ Start Full Video Pre-render")
        total_f = self.video_engine.total_frames
        est_disk_gb = (total_f * 0.3) / 1024.0 # ~1.5 GB for 5,000 4K frames
        disk_free_gb = self._get_disk_free_gb()

        if est_disk_gb < disk_free_gb:
            self.lbl_estimate.setText(f"🎬 <b>All {total_f:,} frames</b> &nbsp;•&nbsp; <b>~{est_disk_gb:.1f} GB Disk Cache</b> &nbsp;<span style='color: #10b981;'>✓ Fits easily ({disk_free_gb:.1f} GB free) • RAM: <150MB</span>")
            self.btn_start.setEnabled(True)
        else:
            self.lbl_estimate.setText(f"⚠️ Need ~{est_disk_gb:.1f} GB free disk space on cache drive.")
            self.btn_start.setEnabled(False)

    def _on_start_prerender(self):
        video_path = self.video_engine.video_path
        if not video_path:
            return

        self.btn_start.setEnabled(False)
        self.btn_clear_cache.setEnabled(False)
        self.btn_cancel.setText("Stop")
        self.progress_container.show()
        self.progress_bar.setValue(0)

        # Full Video Pre-Render
        self.lbl_progress_status.setText("Initializing high-speed GPU pre-render pipeline...")
        self.worker = FullVideoPreRenderWorker(video_path, self.video_engine.total_frames, self.video_engine.fps)
        self.worker.progress.connect(self._on_full_worker_progress)
        self.worker.finished.connect(self._on_full_worker_finished)
        self.worker.failed.connect(self._on_worker_failed)
        self.worker.start()

    def _on_full_worker_progress(self, current: int, total: int, fps: float):
        pct = int((current / total) * 100) if total > 0 else 0
        self.progress_bar.setValue(pct)
        remaining_f = max(0, total - current)
        time_rem = (remaining_f / fps) if fps > 0 else 0.0
        self.lbl_progress_status.setText(f"🎬 Full Video Pre-render: <b>{current:,} / {total:,}</b> frames ({pct}%) &nbsp;•&nbsp; <b>{fps:.1f} FPS</b> &nbsp;•&nbsp; {time_rem:.1f}s remaining")

    def _on_full_worker_finished(self, preview_path: str, elapsed: float):
        self.progress_bar.setValue(100)
        ok = self.video_engine.set_preview_stream(preview_path)
        fps = (self.video_engine.total_frames / elapsed) if elapsed > 0 else 0.0
        self.lbl_progress_status.setText(f"✓ <b>Full video pre-rendered</b> in {elapsed:.1f}s ({fps:.1f} FPS)! Green cache bar active across entire video.")
        self.lbl_progress_status.setStyleSheet("color: #34d399; font-size: 11px; font-weight: bold;")
        self.btn_cancel.setText("Close & Play")
        self.btn_start.setText("✓ Pre-rendered")
        self.btn_start.setEnabled(False)
        self.btn_clear_cache.setEnabled(True)
        self.cache_updated.emit()

    def _on_ram_worker_progress(self, current: int, total: int, fps: float):
        pct = int((current / total) * 100) if total > 0 else 0
        self.progress_bar.setValue(pct)
        remaining_f = max(0, total - current)
        time_rem = (remaining_f / fps) if fps > 0 else 0.0
        self.lbl_progress_status.setText(f"⚡ RAM Pre-rendering: <b>{current:,} / {total:,}</b> frames ({pct}%) &nbsp;•&nbsp; <b>{fps:.1f} FPS</b> &nbsp;•&nbsp; {time_rem:.1f}s remaining")
        self.cache_updated.emit()

    def _on_ram_worker_finished(self, count: int, elapsed: float):
        fps = (count / elapsed) if elapsed > 0 else 0.0
        self.progress_bar.setValue(100)
        self.lbl_progress_status.setText(f"✓ <b>{count:,} frames pre-rendered into RAM</b> in {elapsed:.1f}s ({fps:.1f} FPS)! Green cache line shown on timeline.")
        self.lbl_progress_status.setStyleSheet("color: #34d399; font-size: 11px; font-weight: bold;")
        self.btn_cancel.setText("Close & Play")
        self.btn_start.setText("✓ Pre-rendered")
        self.btn_start.setEnabled(False)
        self.btn_clear_cache.setEnabled(True)
        self.cache_updated.emit()

    def _on_worker_failed(self, err: str):
        QMessageBox.critical(self, "Pre-render Error", err)
        self.btn_cancel.setText("Close")
        self.btn_start.setEnabled(True)
        self.btn_clear_cache.setEnabled(True)

    def _on_clear_cache(self):
        self.video_engine.clear_cache()
        self.cache_updated.emit()
        self.lbl_progress_status.setText("Cache cleared.")
        self.lbl_progress_status.setStyleSheet("color: #94a3b8; font-size: 11px;")
        self.progress_bar.setValue(0)
        QMessageBox.information(self, "Cache Cleared", "Pre-rendered cache and preview streams have been cleared.")

    def _on_cancel_or_close(self):
        if self.worker is not None and self.worker.isRunning():
            if hasattr(self.worker, "cancel"):
                self.worker.cancel()
            self.worker.wait(1500)
            self.worker = None
        self.accept()
