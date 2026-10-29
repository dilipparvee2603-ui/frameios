import os
import sys
import time
import subprocess
from pathlib import Path
from typing import Optional, Tuple

import cv2
import numpy as np

from PySide6.QtWidgets import (
    QDialog, QWidget, QVBoxLayout, QHBoxLayout, QPushButton,
    QLabel, QLineEdit, QSpinBox, QProgressBar, QFileDialog,
    QMessageBox, QFrame, QSizePolicy, QGroupBox, QRadioButton,
    QButtonGroup, QCheckBox, QSlider, QToolTip
)
from PySide6.QtGui import QPixmap, QImage, QColor, QFont, QPainter, QCursor, QPen, QBrush, QLinearGradient
from PySide6.QtCore import Qt, Signal, QSize, QTimer, QThread, QPoint, QRect, QRectF

from .frameless import CustomTitleBar, FramelessWindowMixin, DarkModalDialog
from .pre_render_dialog import find_ffmpeg_path
from .trim_window import is_hevc_video, needs_audio_downmix
from ..video_engine import VideoEngine
from ..config import ConfigManager
from ..utils import (
    frames_to_timecode, frames_to_smpte, timecode_to_frames,
    format_file_size, open_in_explorer, sanitize_filename
)


class VideoTrimWorker(QThread):
    """
    Background worker that runs FFmpeg to export the trimmed video segment
    with zero loss in resolution or quality.
    """
    progress = Signal(float, str, str)  # percent, out_time_str, speed_str
    finished = Signal(bool, str, str, int)  # success, message, output_path, file_size

    def __init__(
        self,
        ffmpeg_path: str,
        video_path: str,
        output_path: str,
        start_sec: float,
        end_sec: float,
        mode: str = "copy"  # "copy" or "accurate"
    ):
        super().__init__()
        self.ffmpeg_path = ffmpeg_path
        self.video_path = video_path
        self.output_path = output_path
        self.start_sec = max(0.0, start_sec)
        self.end_sec = max(self.start_sec + 0.01, end_sec)
        self.duration_sec = self.end_sec - self.start_sec
        self.mode = mode
        self._proc: Optional[subprocess.Popen] = None
        self._is_cancelled = False

    def cancel(self):
        self._is_cancelled = True
        if self._proc is not None:
            try:
                self._proc.terminate()
            except Exception:
                pass

    def _build_cmd(self, include_subs: bool = True):
        ext = Path(self.output_path).suffix.lower()
        is_mp4 = ext in (".mp4", ".m4v", ".mov")

        cmd = [self.ffmpeg_path, "-y"]
        # -ss before -i enables fast keyframe seeking
        cmd.extend([
            "-ss", f"{self.start_sec:.3f}",
            "-i", self.video_path,
            "-t", f"{self.duration_sec:.3f}"
        ])

        if self.mode == "copy":
            # Instant Lossless Stream Copy:
            cmd.extend([
                "-avoid_negative_ts", "make_zero",
                "-map", "0:v:0",
                "-c:v", "copy"
            ])
            if is_hevc_video(self.video_path) and is_mp4:
                cmd.extend(["-tag:v", "hvc1", "-bsf:v", "hevc_mp4toannexb"])

            if needs_audio_downmix(self.video_path) and is_mp4:
                # Transcode 5.1/7.1 Dolby/DTS to pristine stereo AAC so iPhone/Apple TV/Windows never freeze
                cmd.extend(["-map", "0:a:0?", "-c:a", "aac", "-ac", "2", "-b:a", "256k"])
            else:
                cmd.extend(["-map", "0:a?", "-c:a", "copy"])

            if include_subs:
                if is_mp4:
                    cmd.extend(["-map", "0:s?", "-c:s", "mov_text"])
                else:
                    cmd.extend(["-map", "0:s?"])

            if is_mp4:
                cmd.extend(["-movflags", "+faststart"])
        elif self.mode in ("h265", "hevc"):
            # Visually Lossless H.265 / HEVC Export with Apple hvc1 Tag:
            cmd.extend([
                "-avoid_negative_ts", "make_zero",
                "-c:v", "libx265",
                "-crf", "20",
                "-preset", "fast",
                "-pix_fmt", "yuv420p"
            ])
            if is_mp4:
                cmd.extend(["-tag:v", "hvc1"])

            if needs_audio_downmix(self.video_path) or is_mp4:
                cmd.extend(["-map", "0:a:0?", "-c:a", "aac", "-ac", "2", "-b:a", "256k"])
            else:
                cmd.extend(["-map", "0:a?", "-c:a", "copy"])

            cmd.extend(["-map", "0:v:0"])

            if include_subs:
                if is_mp4:
                    cmd.extend(["-map", "0:s?", "-c:s", "mov_text"])
                else:
                    cmd.extend(["-map", "0:s?"])

            if is_mp4:
                cmd.extend(["-movflags", "+faststart"])
        else:
            # Frame-Accurate MP4 H.264 (Universal Compatibility) Cut at 100% Original Resolution:
            cmd.extend([
                "-avoid_negative_ts", "make_zero",
                "-c:v", "libx264",
                "-crf", "17",
                "-preset", "fast",
                "-pix_fmt", "yuv420p"
            ])
            if needs_audio_downmix(self.video_path) or is_mp4:
                cmd.extend(["-map", "0:a:0?", "-c:a", "aac", "-ac", "2", "-b:a", "256k"])
            else:
                cmd.extend(["-map", "0:a?", "-c:a", "copy"])

            cmd.extend(["-map", "0:v:0"])

            if include_subs:
                if is_mp4:
                    cmd.extend(["-map", "0:s?", "-c:s", "mov_text"])
                else:
                    cmd.extend(["-map", "0:s?"])

            if is_mp4:
                cmd.extend(["-movflags", "+faststart"])

        cmd.extend(["-progress", "pipe:1", self.output_path])
        return cmd

    def run(self):
        if not os.path.exists(self.video_path):
            self.finished.emit(False, f"Source video not found: {self.video_path}", "", 0)
            return

        startupinfo = None
        if os.name == "nt":
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startupinfo.wShowWindow = 0

        # Run with subtitle preservation first, then fallback to v+a if container lacks subtitle tag
        for attempt, with_subs in enumerate([True, False]):
            if self._is_cancelled:
                break

            cmd = self._build_cmd(include_subs=with_subs)

            try:
                self._proc = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    universal_newlines=True,
                    startupinfo=startupinfo,
                    bufsize=1
                )
            except Exception as e:
                self.finished.emit(False, f"Failed to start FFmpeg: {e}", "", 0)
                return

            out_time_sec = 0.0
            speed_str = "1.0x"
            recent_logs = []

            try:
                for line in self._proc.stdout:
                    if self._is_cancelled:
                        break
                    line = line.strip()
                    if not line:
                        continue
                    recent_logs.append(line)
                    if len(recent_logs) > 6:
                        recent_logs.pop(0)

                    if line.startswith("out_time_ms="):
                        try:
                            ms = float(line.split("=")[1])
                            out_time_sec = ms / 1_000_000.0
                            pct = min(99.0, max(0.0, (out_time_sec / self.duration_sec) * 100.0))
                            time_str = f"{out_time_sec:.1f}s / {self.duration_sec:.1f}s"
                            self.progress.emit(pct, time_str, speed_str)
                        except Exception:
                            pass
                    elif line.startswith("speed="):
                        speed_str = line.split("=")[1].strip()
            except Exception:
                pass

            self._proc.wait()

            if self._is_cancelled:
                if os.path.exists(self.output_path):
                    try:
                        os.remove(self.output_path)
                    except Exception:
                        pass
                self.finished.emit(False, "Export cancelled by user.", "", 0)
                return

            if self._proc.returncode == 0 and os.path.exists(self.output_path):
                file_size = os.path.getsize(self.output_path)
                self.progress.emit(100.0, f"{self.duration_sec:.1f}s / {self.duration_sec:.1f}s", speed_str)
                self.finished.emit(True, "✓ Video trimmed successfully at 100% original resolution!", self.output_path, file_size)
                return
            else:
                # If failed on attempt 0 (with subs), retry once without subtitle stream
                if attempt == 0:
                    continue
                err_text = "\n".join(recent_logs[-3:]) if recent_logs else "Unknown conversion error"
                self.finished.emit(False, f"FFmpeg error (code {self._proc.returncode}):\n{err_text}", "", 0)
                return


class TrimRangeTimeline(QWidget):
    """
    Visual Timeline Bar with draggable playhead and highlighted In/Out trim zone.
    """
    seek_requested = Signal(int)
    in_point_changed = Signal(int)
    out_point_changed = Signal(int)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedHeight(34)
        self.setMouseTracking(True)
        self.setCursor(Qt.PointingHandCursor)

        self.total_frames = 1
        self.current_frame = 0
        self.in_point: Optional[int] = None
        self.out_point: Optional[int] = None
        self.fps = 30.0

        self._dragging_playhead = False

    def set_context(self, total_frames: int, fps: float, current_frame: int, in_pt: Optional[int], out_pt: Optional[int]):
        self.total_frames = max(1, total_frames)
        self.fps = max(1.0, fps)
        self.current_frame = max(0, min(current_frame, self.total_frames - 1))
        self.in_point = in_pt
        self.out_point = out_pt
        self.update()

    def set_current_frame(self, frame_idx: int):
        self.current_frame = max(0, min(frame_idx, self.total_frames - 1))
        self.update()

    def set_range(self, in_pt: Optional[int], out_pt: Optional[int]):
        self.in_point = in_pt
        self.out_point = out_pt
        self.update()

    def _frame_to_x(self, frame: int) -> float:
        w = float(self.width() - 16)
        return 8.0 + (frame / float(self.total_frames - 1 if self.total_frames > 1 else 1)) * w

    def _x_to_frame(self, x: float) -> int:
        w = float(self.width() - 16)
        if w <= 0:
            return 0
        ratio = max(0.0, min(1.0, (x - 8.0) / w))
        return int(round(ratio * (self.total_frames - 1)))

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)

        h = self.height()
        track_y = 10
        track_h = 14

        # Background track
        painter.setPen(Qt.NoPen)
        painter.setBrush(QColor("#131824"))
        painter.drawRoundedRect(8, track_y, self.width() - 16, track_h, 4, 4)

        # Draw In/Out Highlight Zone
        in_f = self.in_point if self.in_point is not None else 0
        out_f = self.out_point if self.out_point is not None else (self.total_frames - 1)
        if out_f > in_f:
            x_in = self._frame_to_x(in_f)
            x_out = self._frame_to_x(out_f)
            rw = max(2.0, x_out - x_in)

            # Gradient cyan fill
            grad = QLinearGradient(x_in, track_y, x_out, track_y)
            grad.setColorAt(0.0, QColor(6, 182, 212, 160))
            grad.setColorAt(1.0, QColor(59, 130, 246, 160))
            painter.setBrush(QBrush(grad))
            painter.drawRoundedRect(QRectF(x_in, track_y, rw, track_h), 3, 3)

            # Draw In-Point vertical flag
            painter.setPen(QPen(QColor("#f59e0b"), 2))
            painter.drawLine(int(x_in), track_y - 4, int(x_in), track_y + track_h + 4)
            painter.setBrush(QColor("#f59e0b"))
            painter.drawPolygon([QPoint(int(x_in), track_y - 4), QPoint(int(x_in) + 6, track_y - 8), QPoint(int(x_in), track_y - 8)])

            # Draw Out-Point vertical flag
            painter.setPen(QPen(QColor("#f59e0b"), 2))
            painter.drawLine(int(x_out), track_y - 4, int(x_out), track_y + track_h + 4)
            painter.setBrush(QColor("#f59e0b"))
            painter.drawPolygon([QPoint(int(x_out), track_y - 4), QPoint(int(x_out) - 6, track_y - 8), QPoint(int(x_out), track_y - 8)])

        # Draw Playhead Cursor
        px = self._frame_to_x(self.current_frame)
        painter.setPen(QPen(QColor("#ffffff"), 2))
        painter.drawLine(int(px), 2, int(px), h - 2)
        # Playhead Diamond Head
        painter.setBrush(QColor("#38bdf8"))
        painter.setPen(QPen(QColor("#ffffff"), 1))
        painter.drawPolygon([
            QPoint(int(px), 0),
            QPoint(int(px) + 5, 5),
            QPoint(int(px), 10),
            QPoint(int(px) - 5, 5)
        ])

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self._dragging_playhead = True
            f = self._x_to_frame(event.position().x() if hasattr(event, "position") else event.pos().x())
            self.current_frame = f
            self.update()
            self.seek_requested.emit(f)

    def mouseMoveEvent(self, event):
        x = event.position().x() if hasattr(event, "position") else event.pos().x()
        f = self._x_to_frame(x)
        if self._dragging_playhead:
            self.current_frame = f
            self.update()
            self.seek_requested.emit(f)
        else:
            tc = frames_to_timecode(f, self.fps)
            QToolTip.showText(event.globalPosition().toPoint() if hasattr(event, "globalPosition") else event.globalPos(), f"Frame {f:,} • {tc}", self)

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.LeftButton:
            self._dragging_playhead = False


class VideoTrimDialog(DarkModalDialog):
    """
    Studio Lossless Video Trimmer & Precision Cutter.
    - Full video preview with frame-by-frame scrubbing
    - Precision Timeframe Entry for In-Point and Out-Point (Timecode & Frame)
    - 100% Original Resolution Lossless Stream Copy (0s Re-encode) or Frame-Accurate Cut
    - Live Range Duration and Estimated Size computation
    """
    trim_completed = Signal(str)

    def __init__(self, video_engine: VideoEngine, parent=None):
        super().__init__(title="Video Trimmer & Lossless Exporter", parent=parent)
        self.video_engine = video_engine
        self.config = ConfigManager()
        self.resize(1080, 780)
        self.setMinimumSize(920, 640)

        # State
        self.in_point: int = 0
        self.out_point: int = max(0, self.video_engine.total_frames - 1)
        self.current_preview_frame: int = self.video_engine.current_frame_idx
        self.is_playing = False
        self.loop_range = True

        # Pre-fill In/Out from engine if available
        if self.video_engine.in_point is not None:
            self.in_point = self.video_engine.in_point
        if self.video_engine.out_point is not None:
            self.out_point = self.video_engine.out_point

        self.play_timer = QTimer(self)
        self.play_timer.setTimerType(Qt.PreciseTimer)
        self.play_timer.timeout.connect(self._on_play_tick)

        self.worker: Optional[VideoTrimWorker] = None

        self._setup_ui()
        self._sync_video_info()
        self._update_timeframe_inputs()
        self._seek_to(self.in_point)

    def _setup_ui(self):
        layout = self.content_layout
        layout.setSpacing(10)

        # ========================================================
        # 1. TOP SOURCE BANNER: File Name, Change Video & Specs
        # ========================================================
        source_card = QFrame()
        source_card.setStyleSheet("""
            QFrame {
                background: #10141f;
                border: 1px solid #1e2638;
                border-radius: 6px;
                padding: 6px;
            }
        """)
        src_layout = QHBoxLayout(source_card)
        src_layout.setContentsMargins(10, 4, 10, 4)
        src_layout.setSpacing(10)

        lbl_icon = QLabel("🎬")
        lbl_icon.setStyleSheet("font-size: 16px;")
        src_layout.addWidget(lbl_icon)

        self.lbl_video_title = QLabel("Video: None")
        self.lbl_video_title.setStyleSheet("color: #ffffff; font-weight: bold; font-size: 13px;")
        src_layout.addWidget(self.lbl_video_title, 1)

        # Change Video Button
        self.btn_open_video = QPushButton("📂 Open / Change Video...")
        self.btn_open_video.setFixedHeight(26)
        self.btn_open_video.setStyleSheet("""
            QPushButton {
                background: #1e293b;
                border: 1px solid rgba(56, 189, 248, 0.28);
                color: #38bdf8;
                font-size: 11px;
                font-weight: 600;
                border-radius: 4px;
                padding: 2px 10px;
            }
            QPushButton:hover {
                background: #27354f;
                color: #ffffff;
                border: 1px solid rgba(56, 189, 248, 0.48);
            }
        """)
        self.btn_open_video.clicked.connect(self._on_change_video)
        src_layout.addWidget(self.btn_open_video)

        # Video Specs Badges
        self.badge_res = QLabel("📐 0 × 0")
        self.badge_res.setStyleSheet("color: #818cf8; font-family: monospace; font-size: 11px; font-weight: bold;")
        src_layout.addWidget(self.badge_res)

        self.badge_fps = QLabel("⚡ 0 FPS")
        self.badge_fps.setStyleSheet("color: #38bdf8; font-family: monospace; font-size: 11px;")
        src_layout.addWidget(self.badge_fps)

        self.badge_dur = QLabel("⏱ 00:00:00")
        self.badge_dur.setStyleSheet("color: #cbd5e1; font-family: monospace; font-size: 11px;")
        src_layout.addWidget(self.badge_dur)

        layout.addWidget(source_card)

        # ========================================================
        # 2. MAIN SPLIT: Live Canvas Preview & Visual Timeline
        # ========================================================
        preview_container = QFrame()
        preview_container.setStyleSheet("""
            QFrame {
                background: #090c13;
                border: 1px solid #1a2233;
                border-radius: 6px;
            }
        """)
        prev_layout = QVBoxLayout(preview_container)
        prev_layout.setContentsMargins(6, 6, 6, 6)
        prev_layout.setSpacing(6)

        # Video Preview Canvas
        self.canvas_label = QLabel()
        self.canvas_label.setAlignment(Qt.AlignCenter)
        self.canvas_label.setMinimumHeight(240)
        self.canvas_label.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.canvas_label.setStyleSheet("background: #06080d; border-radius: 4px;")
        prev_layout.addWidget(self.canvas_label, 1)

        # Range Timeline
        self.timeline = TrimRangeTimeline(self)
        self.timeline.seek_requested.connect(self._seek_to)
        prev_layout.addWidget(self.timeline)

        # Transport Bar
        trans_box = QHBoxLayout()
        trans_box.setContentsMargins(4, 0, 4, 0)
        trans_box.setSpacing(4)

        self.btn_jump_in = QPushButton("⏮ Jump In")
        self.btn_jump_in.setFixedHeight(26)
        self.btn_jump_in.clicked.connect(lambda: self._seek_to(self.in_point))
        trans_box.addWidget(self.btn_jump_in)

        self.btn_step_prev10 = QPushButton("« 10f")
        self.btn_step_prev10.setFixedHeight(26)
        self.btn_step_prev10.clicked.connect(lambda: self._seek_to(self.current_preview_frame - 10))
        trans_box.addWidget(self.btn_step_prev10)

        self.btn_step_prev1 = QPushButton("◀ 1f")
        self.btn_step_prev1.setFixedHeight(26)
        self.btn_step_prev1.clicked.connect(lambda: self._seek_to(self.current_preview_frame - 1))
        trans_box.addWidget(self.btn_step_prev1)

        self.btn_play = QPushButton("▶ Play Range")
        self.btn_play.setFixedHeight(26)
        self.btn_play.setStyleSheet("""
            QPushButton {
                background: #4f46e5;
                color: #ffffff;
                font-weight: bold;
                border-radius: 4px;
                padding: 2px 14px;
            }
            QPushButton:hover { background: #6366f1; }
        """)
        self.btn_play.clicked.connect(self._toggle_playback)
        trans_box.addWidget(self.btn_play)

        self.btn_step_next1 = QPushButton("1f ▶")
        self.btn_step_next1.setFixedHeight(26)
        self.btn_step_next1.clicked.connect(lambda: self._seek_to(self.current_preview_frame + 1))
        trans_box.addWidget(self.btn_step_next1)

        self.btn_step_next10 = QPushButton("10f »")
        self.btn_step_next10.setFixedHeight(26)
        self.btn_step_next10.clicked.connect(lambda: self._seek_to(self.current_preview_frame + 10))
        trans_box.addWidget(self.btn_step_next10)

        self.btn_jump_out = QPushButton("⏭ Jump Out")
        self.btn_jump_out.setFixedHeight(26)
        self.btn_jump_out.clicked.connect(lambda: self._seek_to(self.out_point))
        trans_box.addWidget(self.btn_jump_out)

        trans_box.addStretch()

        self.chk_loop = QCheckBox("🔁 Loop Range")
        self.chk_loop.setChecked(True)
        self.chk_loop.setStyleSheet("color: #cbd5e1; font-size: 11px;")
        trans_box.addWidget(self.chk_loop)

        self.lbl_cur_timecode = QLabel("00:00:00.000 (Frame 0)")
        self.lbl_cur_timecode.setStyleSheet("color: #38bdf8; font-family: monospace; font-size: 11px; font-weight: bold; margin-left: 8px;")
        trans_box.addWidget(self.lbl_cur_timecode)

        prev_layout.addLayout(trans_box)
        layout.addWidget(preview_container, 1)

        # ========================================================
        # 3. TIMEFRAME ENTRY & PRECISION CONTROLS (USER REQUEST)
        # ========================================================
        timeframe_box = QHBoxLayout()
        timeframe_box.setSpacing(10)

        # --- A. IN-POINT ENTRY CARD ---
        in_group = QGroupBox("📍 1. In-Point (Cut Start Time)")
        in_group.setStyleSheet("""
            QGroupBox {
                color: #f59e0b;
                font-weight: bold;
                font-size: 11px;
                border: 1px solid rgba(245, 158, 11, 0.25);
                border-radius: 6px;
                margin-top: 6px;
                padding-top: 10px;
                background: #0e121b;
            }
            QGroupBox::title { subcontrol-origin: margin; left: 8px; padding: 0 4px; }
        """)
        in_layout = QVBoxLayout(in_group)
        in_layout.setSpacing(6)

        # Timecode Entry Row
        row_in_tc = QHBoxLayout()
        lbl_itc = QLabel("Timecode:")
        lbl_itc.setStyleSheet("color: #94a3b8; font-size: 11px; min-width: 60px;")
        row_in_tc.addWidget(lbl_itc)
        self.txt_in_timecode = QLineEdit("00:00:00.000")
        self.txt_in_timecode.setFixedHeight(28)
        self.txt_in_timecode.setStyleSheet("""
            QLineEdit {
                background: #141a27;
                border: 1px solid #27354f;
                color: #ffffff;
                font-family: 'Consolas', monospace;
                font-size: 12px;
                font-weight: bold;
                padding: 2px 6px;
                border-radius: 4px;
            }
            QLineEdit:focus { border: 1px solid #f59e0b; }
        """)
        self.txt_in_timecode.returnPressed.connect(self._on_in_timecode_edited)
        self.txt_in_timecode.editingFinished.connect(self._on_in_timecode_edited)
        row_in_tc.addWidget(self.txt_in_timecode)
        in_layout.addLayout(row_in_tc)

        # Frame Number Row
        row_in_f = QHBoxLayout()
        lbl_if = QLabel("Frame #:")
        lbl_if.setStyleSheet("color: #94a3b8; font-size: 11px; min-width: 60px;")
        row_in_f.addWidget(lbl_if)
        self.spin_in_frame = QSpinBox()
        self.spin_in_frame.setFixedHeight(28)
        self.spin_in_frame.setRange(0, 9999999)
        self.spin_in_frame.setValue(0)
        self.spin_in_frame.setStyleSheet("""
            QSpinBox {
                background: #141a27;
                border: 1px solid #27354f;
                color: #f59e0b;
                font-family: 'Consolas', monospace;
                font-size: 12px;
                font-weight: bold;
                padding: 2px 6px;
                border-radius: 4px;
            }
        """)
        self.spin_in_frame.valueChanged.connect(self._on_in_spin_changed)
        row_in_f.addWidget(self.spin_in_frame)
        in_layout.addLayout(row_in_f)

        # In-Point Quick Action Buttons
        btn_row_in = QHBoxLayout()
        self.btn_set_in_current = QPushButton("📍 Current (I)")
        self.btn_set_in_current.setFixedHeight(24)
        self.btn_set_in_current.setToolTip("Set In-Point to current playhead frame")
        self.btn_set_in_current.clicked.connect(self._set_in_to_current)
        btn_row_in.addWidget(self.btn_set_in_current)

        self.btn_in_start = QPushButton("⏮ Start (0s)")
        self.btn_in_start.setFixedHeight(24)
        self.btn_in_start.clicked.connect(lambda: self._set_in_point(0))
        btn_row_in.addWidget(self.btn_in_start)

        self.btn_view_in = QPushButton("👁 View")
        self.btn_view_in.setFixedHeight(24)
        self.btn_view_in.clicked.connect(lambda: self._seek_to(self.in_point))
        btn_row_in.addWidget(self.btn_view_in)
        in_layout.addLayout(btn_row_in)

        timeframe_box.addWidget(in_group)

        # --- B. OUT-POINT ENTRY CARD ---
        out_group = QGroupBox("📍 2. Out-Point (Cut End Time)")
        out_group.setStyleSheet("""
            QGroupBox {
                color: #f59e0b;
                font-weight: bold;
                font-size: 11px;
                border: 1px solid rgba(245, 158, 11, 0.25);
                border-radius: 6px;
                margin-top: 6px;
                padding-top: 10px;
                background: #0e121b;
            }
            QGroupBox::title { subcontrol-origin: margin; left: 8px; padding: 0 4px; }
        """)
        out_layout = QVBoxLayout(out_group)
        out_layout.setSpacing(6)

        # Timecode Entry Row
        row_out_tc = QHBoxLayout()
        lbl_otc = QLabel("Timecode:")
        lbl_otc.setStyleSheet("color: #94a3b8; font-size: 11px; min-width: 60px;")
        row_out_tc.addWidget(lbl_otc)
        self.txt_out_timecode = QLineEdit("00:00:00.000")
        self.txt_out_timecode.setFixedHeight(28)
        self.txt_out_timecode.setStyleSheet("""
            QLineEdit {
                background: #141a27;
                border: 1px solid #27354f;
                color: #ffffff;
                font-family: 'Consolas', monospace;
                font-size: 12px;
                font-weight: bold;
                padding: 2px 6px;
                border-radius: 4px;
            }
            QLineEdit:focus { border: 1px solid #f59e0b; }
        """)
        self.txt_out_timecode.returnPressed.connect(self._on_out_timecode_edited)
        self.txt_out_timecode.editingFinished.connect(self._on_out_timecode_edited)
        row_out_tc.addWidget(self.txt_out_timecode)
        out_layout.addLayout(row_out_tc)

        # Frame Number Row
        row_out_f = QHBoxLayout()
        lbl_of = QLabel("Frame #:")
        lbl_of.setStyleSheet("color: #94a3b8; font-size: 11px; min-width: 60px;")
        row_out_f.addWidget(lbl_of)
        self.spin_out_frame = QSpinBox()
        self.spin_out_frame.setFixedHeight(28)
        self.spin_out_frame.setRange(0, 9999999)
        self.spin_out_frame.setValue(0)
        self.spin_out_frame.setStyleSheet("""
            QSpinBox {
                background: #141a27;
                border: 1px solid #27354f;
                color: #f59e0b;
                font-family: 'Consolas', monospace;
                font-size: 12px;
                font-weight: bold;
                padding: 2px 6px;
                border-radius: 4px;
            }
        """)
        self.spin_out_frame.valueChanged.connect(self._on_out_spin_changed)
        row_out_f.addWidget(self.spin_out_frame)
        out_layout.addLayout(row_out_f)

        # Out-Point Quick Action Buttons
        btn_row_out = QHBoxLayout()
        self.btn_set_out_current = QPushButton("📍 Current (O)")
        self.btn_set_out_current.setFixedHeight(24)
        self.btn_set_out_current.setToolTip("Set Out-Point to current playhead frame")
        self.btn_set_out_current.clicked.connect(self._set_out_to_current)
        btn_row_out.addWidget(self.btn_set_out_current)

        self.btn_out_end = QPushButton("⏭ End (Full)")
        self.btn_out_end.setFixedHeight(24)
        self.btn_out_end.clicked.connect(lambda: self._set_out_point(self.video_engine.total_frames - 1))
        btn_row_out.addWidget(self.btn_out_end)

        self.btn_view_out = QPushButton("👁 View")
        self.btn_view_out.setFixedHeight(24)
        self.btn_view_out.clicked.connect(lambda: self._seek_to(self.out_point))
        btn_row_out.addWidget(self.btn_view_out)
        out_layout.addLayout(btn_row_out)

        timeframe_box.addWidget(out_group)
        layout.addLayout(timeframe_box)

        # ========================================================
        # 4. TRIM STATS & RESOLUTION BANNER
        # ========================================================
        stats_banner = QFrame()
        stats_banner.setStyleSheet("""
            QFrame {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #0f1c2e, stop:1 #112638);
                border: 1px solid rgba(6, 182, 212, 0.35);
                border-radius: 6px;
                padding: 6px;
            }
        """)
        stat_layout = QHBoxLayout(stats_banner)
        stat_layout.setContentsMargins(12, 4, 12, 4)
        stat_layout.setSpacing(16)

        self.lbl_trimmed_duration = QLabel("✂️ Trimmed: 00:00:00.000 (0 frames)")
        self.lbl_trimmed_duration.setStyleSheet("color: #38bdf8; font-weight: bold; font-size: 12px; font-family: monospace;")
        stat_layout.addWidget(self.lbl_trimmed_duration)

        self.lbl_quality_guarantee = QLabel("💎 100% Original Resolution")
        self.lbl_quality_guarantee.setStyleSheet("color: #34d399; font-weight: bold; font-size: 11px;")
        stat_layout.addWidget(self.lbl_quality_guarantee)

        stat_layout.addStretch()

        self.lbl_est_size = QLabel("📦 Est. Size: ~0 MB")
        self.lbl_est_size.setStyleSheet("color: #a5b4fc; font-weight: 500; font-size: 11px;")
        stat_layout.addWidget(self.lbl_est_size)

        layout.addWidget(stats_banner)

        # ========================================================
        # 5. EXPORT OPTIONS & DESTINATION
        # ========================================================
        opt_card = QFrame()
        opt_card.setStyleSheet("""
            QFrame {
                background: #0c0f16;
                border: 1px solid #1a2233;
                border-radius: 6px;
                padding: 6px;
            }
        """)
        opt_layout = QVBoxLayout(opt_card)
        opt_layout.setContentsMargins(10, 8, 10, 8)
        opt_layout.setSpacing(6)

        # Mode Selection
        mode_row = QHBoxLayout()
        lbl_m = QLabel("Export Format:")
        lbl_m.setStyleSheet("color: #94a3b8; font-size: 11px; min-width: 75px;")
        mode_row.addWidget(lbl_m)

        self.btn_group_format = QButtonGroup(self)

        pill_style = """
            QRadioButton {
                background: #1A1A22;
                border: 1px solid rgba(255, 255, 255, 0.12);
                color: #CBD5E1;
                border-radius: 6px;
                padding: 4px 10px;
                font-weight: 600;
                font-size: 11px;
            }
            QRadioButton:hover {
                background: #242430;
                color: #FFFFFF;
                border-color: rgba(255, 255, 255, 0.25);
            }
            QRadioButton:checked {
                background: #0284C7;
                border: 1px solid #38BDF8;
                color: #FFFFFF;
                font-weight: bold;
            }
            QRadioButton::indicator {
                width: 0px;
                height: 0px;
            }
        """

        self.radio_copy = QRadioButton("⚡ Lossless (Fast)")
        self.radio_copy.setChecked(True)
        self.radio_copy.setCursor(Qt.PointingHandCursor)
        self.radio_copy.setToolTip("Cuts instantly without re-encoding. 100% original stream quality and resolution at disk write speed!")
        self.radio_copy.setStyleSheet(pill_style)
        self.btn_group_format.addButton(self.radio_copy)
        mode_row.addWidget(self.radio_copy)

        self.radio_h264 = QRadioButton("🎬 MP4 (H.264 Universal)")
        self.radio_h264.setCursor(Qt.PointingHandCursor)
        self.radio_h264.setToolTip("Universally compatible H.264/AAC MP4 - plays flawlessly on iPhone, iPad, Windows, Mac, web & editors.")
        self.radio_h264.setStyleSheet(pill_style)
        self.btn_group_format.addButton(self.radio_h264)
        mode_row.addWidget(self.radio_h264)

        self.radio_h265 = QRadioButton("🚀 MP4 (H.265 HEVC)")
        self.radio_h265.setCursor(Qt.PointingHandCursor)
        self.radio_h265.setToolTip("High-efficiency HEVC export tagged with hvc1 for Apple devices and stereo AAC audio.")
        self.radio_h265.setStyleSheet(pill_style)
        self.btn_group_format.addButton(self.radio_h265)
        mode_row.addWidget(self.radio_h265)
        mode_row.addStretch()
        opt_layout.addLayout(mode_row)

        # Destination Folder & Filename
        dest_row = QHBoxLayout()
        lbl_d = QLabel("Save To:")
        lbl_d.setStyleSheet("color: #94a3b8; font-size: 11px; min-width: 75px;")
        dest_row.addWidget(lbl_d)

        self.txt_output_path = QLineEdit()
        self.txt_output_path.setFixedHeight(28)
        dest_row.addWidget(self.txt_output_path, 1)

        btn_browse = QPushButton("Browse...")
        btn_browse.setFixedHeight(28)
        btn_browse.clicked.connect(self._on_browse_output)
        dest_row.addWidget(btn_browse)
        opt_layout.addLayout(dest_row)

        layout.addWidget(opt_card)

        # ========================================================
        # 6. ACTION & PROGRESS BAR
        # ========================================================
        bottom_box = QVBoxLayout()
        bottom_box.setSpacing(6)

        # Progress bar
        self.prog_bar = QProgressBar()
        self.prog_bar.setFixedHeight(18)
        self.prog_bar.setRange(0, 100)
        self.prog_bar.setValue(0)
        self.prog_bar.setTextVisible(True)
        self.prog_bar.setStyleSheet("""
            QProgressBar {
                background: #0f131d;
                border: 1px solid #1e293b;
                border-radius: 4px;
                text-align: center;
                color: #ffffff;
                font-size: 10px;
                font-weight: bold;
            }
            QProgressBar::chunk {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #059669, stop:1 #10b981);
                border-radius: 3px;
            }
        """)
        self.prog_bar.hide()
        bottom_box.addWidget(self.prog_bar)

        self.lbl_status = QLabel("Ready to trim video segment.")
        self.lbl_status.setStyleSheet("color: #94a3b8; font-size: 11px;")
        bottom_box.addWidget(self.lbl_status)

        # Buttons
        act_row = QHBoxLayout()
        self.chk_open_folder = QCheckBox("Open output folder when done")
        self.chk_open_folder.setChecked(True)
        self.chk_open_folder.setStyleSheet("color: #cbd5e1; font-size: 11px;")
        act_row.addWidget(self.chk_open_folder)

        act_row.addStretch()

        self.btn_cancel = QPushButton("Cancel")
        self.btn_cancel.setFixedHeight(32)
        self.btn_cancel.clicked.connect(self._on_cancel_clicked)
        act_row.addWidget(self.btn_cancel)

        self.btn_export = QPushButton("✂️ Export Trimmed Video")
        self.btn_export.setFixedHeight(32)
        self.btn_export.setObjectName("primaryBtn")
        self.btn_export.setStyleSheet("""
            QPushButton#primaryBtn {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #4f46e5, stop:1 #6366f1);
                color: #ffffff;
                font-weight: bold;
                font-size: 12px;
                border: none;
                border-radius: 5px;
                padding: 0 20px;
            }
            QPushButton#primaryBtn:hover {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #6366f1, stop:1 #818cf8);
            }
        """)
        self.btn_export.clicked.connect(self._start_trim_export)
        act_row.addWidget(self.btn_export)

        bottom_box.addLayout(act_row)
        layout.addLayout(bottom_box)

    # --- Video Context Syncing ---
    def _sync_video_info(self):
        if not self.video_engine.is_loaded:
            return

        info = self.video_engine.get_info()
        w, h, fps, total = info["width"], info["height"], info["fps"], info["total_frames"]

        self.lbl_video_title.setText(f"🎬 {info.get('filename', 'Video')}")
        self.badge_res.setText(f"📐 {w} × {h}")
        self.badge_fps.setText(f"⚡ {fps:.2f} FPS")
        self.badge_dur.setText(f"⏱ {frames_to_timecode(total - 1, fps)}")
        self.lbl_quality_guarantee.setText(f"💎 100% Original Resolution ({w} × {h})")

        self.spin_in_frame.setRange(0, total - 1)
        self.spin_out_frame.setRange(0, total - 1)

        self.timeline.set_context(total, fps, self.current_preview_frame, self.in_point, self.out_point)

        # Default destination file
        default_dir = self.config.get("default_output_dir", "")
        if not default_dir or not os.path.exists(default_dir):
            default_dir = str(Path.home() / "Videos")
            if not os.path.exists(default_dir):
                default_dir = str(Path.home())

        stem = Path(info.get("filename", "clip")).stem
        default_filename = f"{stem}_trimmed.mp4"
        self.txt_output_path.setText(str(Path(default_dir) / default_filename))

    def _update_timeframe_inputs(self):
        fps = self.video_engine.fps if self.video_engine.fps > 0 else 30.0

        # Update In-point
        self.txt_in_timecode.blockSignals(True)
        self.spin_in_frame.blockSignals(True)
        self.txt_in_timecode.setText(frames_to_timecode(self.in_point, fps))
        self.spin_in_frame.setValue(self.in_point)
        self.txt_in_timecode.blockSignals(False)
        self.spin_in_frame.blockSignals(False)

        # Update Out-point
        self.txt_out_timecode.blockSignals(True)
        self.spin_out_frame.blockSignals(True)
        self.txt_out_timecode.setText(frames_to_timecode(self.out_point, fps))
        self.spin_out_frame.setValue(self.out_point)
        self.txt_out_timecode.blockSignals(False)
        self.spin_out_frame.blockSignals(False)

        # Update Timeline Range
        self.timeline.set_range(self.in_point, self.out_point)

        # Update Duration & Output estimates
        trimmed_frames = max(0, self.out_point - self.in_point + 1)
        dur_sec = trimmed_frames / fps
        dur_tc = frames_to_timecode(trimmed_frames, fps)
        self.lbl_trimmed_duration.setText(f"✂️ Trimmed: {dur_tc} ({trimmed_frames:,} frames)")

        # Estimate output size based on source file size
        if self.video_engine.video_path and os.path.exists(self.video_engine.video_path):
            try:
                src_size = os.path.getsize(self.video_engine.video_path)
                total_f = max(1, self.video_engine.total_frames)
                est_bytes = int((trimmed_frames / float(total_f)) * src_size)
                self.lbl_est_size.setText(f"📦 Est. Size: ~{format_file_size(est_bytes)}")
            except Exception:
                self.lbl_est_size.setText("")

    # --- Precision In/Out Timeframe Edits ---
    def _on_in_timecode_edited(self):
        fps = self.video_engine.fps if self.video_engine.fps > 0 else 30.0
        text = self.txt_in_timecode.text().strip()
        f_idx = timecode_to_frames(text, fps)
        self._set_in_point(f_idx)

    def _on_in_spin_changed(self, val: int):
        self._set_in_point(val)

    def _on_out_timecode_edited(self):
        fps = self.video_engine.fps if self.video_engine.fps > 0 else 30.0
        text = self.txt_out_timecode.text().strip()
        f_idx = timecode_to_frames(text, fps)
        self._set_out_point(f_idx)

    def _on_out_spin_changed(self, val: int):
        self._set_out_point(val)

    def _set_in_to_current(self):
        self._set_in_point(self.current_preview_frame)

    def _set_out_to_current(self):
        self._set_out_point(self.current_preview_frame)

    def _set_in_point(self, f_idx: int):
        f_idx = max(0, min(f_idx, self.video_engine.total_frames - 1))
        if f_idx >= self.out_point:
            self.out_point = min(self.video_engine.total_frames - 1, f_idx + 1)
        self.in_point = f_idx
        self._update_timeframe_inputs()
        self._seek_to(self.in_point)

    def _set_out_point(self, f_idx: int):
        f_idx = max(0, min(f_idx, self.video_engine.total_frames - 1))
        if f_idx <= self.in_point:
            self.in_point = max(0, f_idx - 1)
        self.out_point = f_idx
        self._update_timeframe_inputs()
        self._seek_to(self.out_point)

    # --- Video Preview & Playback Navigation ---
    def _seek_to(self, frame_idx: int):
        if not self.video_engine.is_loaded:
            return
        frame_idx = max(0, min(frame_idx, self.video_engine.total_frames - 1))
        self.current_preview_frame = frame_idx

        # Render frame
        frame = self.video_engine.get_frame(frame_idx)
        if frame is not None:
            self._display_frame(frame)

        # Update playhead and timecode
        fps = self.video_engine.fps if self.video_engine.fps > 0 else 30.0
        tc = frames_to_timecode(frame_idx, fps)
        self.lbl_cur_timecode.setText(f"{tc} (Frame {frame_idx:,})")
        self.timeline.set_current_frame(frame_idx)

    def _display_frame(self, bgr_frame: np.ndarray):
        h, w = bgr_frame.shape[:2]
        canvas_size = self.canvas_label.size()
        cw, ch = canvas_size.width(), canvas_size.height()

        if cw <= 10 or ch <= 10:
            return

        scale = min(cw / float(w), ch / float(h))
        tw, th = max(1, int(w * scale)), max(1, int(h * scale))

        resized = cv2.resize(bgr_frame, (tw, th), interpolation=cv2.INTER_AREA if scale < 1.0 else cv2.INTER_LINEAR)
        rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
        qimg = QImage(rgb.data, tw, th, tw * 3, QImage.Format.Format_RGB888)
        pix = QPixmap.fromImage(qimg)
        self.canvas_label.setPixmap(pix)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        if self.video_engine.is_loaded:
            f = self.video_engine.get_frame(self.current_preview_frame)
            if f is not None:
                self._display_frame(f)

    def _toggle_playback(self):
        if self.is_playing:
            self.is_playing = False
            self.play_timer.stop()
            self.btn_play.setText("▶ Play Range")
        else:
            self.is_playing = True
            self.btn_play.setText("⏸ Pause")
            if self.current_preview_frame >= self.out_point or self.current_preview_frame < self.in_point:
                self._seek_to(self.in_point)
            interval = int(round(1000.0 / (self.video_engine.fps if self.video_engine.fps > 0 else 30.0)))
            self.play_timer.start(interval)

    def _on_play_tick(self):
        if not self.video_engine.is_loaded:
            self._toggle_playback()
            return

        nxt = self.current_preview_frame + 1
        if nxt > self.out_point:
            if self.chk_loop.isChecked():
                nxt = self.in_point
            else:
                self._toggle_playback()
                return

        self._seek_to(nxt)

    def _on_change_video(self):
        filter_str = "Video Files (*.mp4 *.mkv *.mov *.avi *.webm *.m4v *.flv *.wmv *.ts);;All Files (*.*)"
        chosen, _ = QFileDialog.getOpenFileName(self, "Open Video for Trimming", "", filter_str)
        if chosen and os.path.exists(chosen):
            ok = self.video_engine.open(chosen)
            if ok:
                self.in_point = 0
                self.out_point = max(0, self.video_engine.total_frames - 1)
                self.current_preview_frame = 0
                self._sync_video_info()
                self._update_timeframe_inputs()
                self._seek_to(0)

    def _on_browse_output(self):
        current_dest = self.txt_output_path.text()
        chosen, _ = QFileDialog.getSaveFileName(
            self,
            "Save Trimmed Video",
            current_dest,
            "MP4 Video (*.mp4);;MKV Video (*.mkv);;MOV Video (*.mov);;All Files (*.*)"
        )
        if chosen:
            self.txt_output_path.setText(chosen)

    # --- Export Execution ---
    def _start_trim_export(self):
        if not self.video_engine.is_loaded:
            QMessageBox.warning(self, "No Video", "Please open a video before trimming.")
            return

        out_path = self.txt_output_path.text().strip()
        if not out_path:
            QMessageBox.warning(self, "Missing Output", "Please choose an output file location.")
            return

        Path(out_path).parent.mkdir(parents=True, exist_ok=True)

        fps = self.video_engine.fps if self.video_engine.fps > 0 else 30.0
        start_sec = self.in_point / fps
        end_sec = (self.out_point + 1) / fps

        if end_sec <= start_sec:
            QMessageBox.warning(self, "Invalid Range", "Out-point must be after in-point.")
            return

        ff_bin = find_ffmpeg_path()
        if self.radio_copy.isChecked():
            mode = "copy"
        elif self.radio_h264.isChecked():
            mode = "h264"
        else:
            mode = "h265"

        self.btn_export.setEnabled(False)
        self.btn_cancel.setText("Stop Export")
        self.prog_bar.setValue(0)
        self.prog_bar.show()
        self.lbl_status.setText(f"Trimming segment from {frames_to_timecode(self.in_point, fps)} to {frames_to_timecode(self.out_point, fps)}...")

        self.worker = VideoTrimWorker(
            ffmpeg_path=ff_bin,
            video_path=self.video_engine.video_path,
            output_path=out_path,
            start_sec=start_sec,
            end_sec=end_sec,
            mode=mode
        )
        self.worker.progress.connect(self._on_worker_progress)
        self.worker.finished.connect(self._on_worker_finished)
        self.worker.start()

    def _on_worker_progress(self, percent: float, time_str: str, speed_str: str):
        self.prog_bar.setValue(int(percent))
        self.lbl_status.setText(f"Exporting: {percent:.1f}% • {time_str} ({speed_str})")

    def _on_worker_finished(self, success: bool, message: str, out_file: str, file_size: int):
        self.btn_export.setEnabled(True)
        self.btn_cancel.setText("Close")

        if success:
            self.lbl_status.setText(f"{message} ({format_file_size(file_size)})")
            self.lbl_status.setStyleSheet("color: #10b981; font-weight: bold; font-size: 11px;")
            self.trim_completed.emit(out_file)

            if self.chk_open_folder.isChecked():
                open_in_explorer(out_file)
        else:
            self.lbl_status.setText(message)
            self.lbl_status.setStyleSheet("color: #ef4444; font-size: 11px;")
            if "cancelled" not in message.lower():
                QMessageBox.critical(self, "Trim Error", message)

    def _on_cancel_clicked(self):
        if self.worker is not None and self.worker.isRunning():
            self.worker.cancel()
            self.worker.wait(500)
            self.lbl_status.setText("Export cancelled.")
            self.btn_export.setEnabled(True)
            self.btn_cancel.setText("Close")
            return
        self.close()

    def closeEvent(self, event):
        if self.is_playing:
            self.play_timer.stop()
        if self.worker is not None and self.worker.isRunning():
            self.worker.cancel()
            self.worker.wait(500)
        super().closeEvent(event)
