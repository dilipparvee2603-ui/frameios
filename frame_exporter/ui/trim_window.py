import os
import sys
import time
import threading
import subprocess
from pathlib import Path
from typing import Optional, Tuple

import cv2
import numpy as np

from PySide6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QPushButton,
    QLabel, QLineEdit, QSpinBox, QProgressBar, QFileDialog,
    QMessageBox, QFrame, QSizePolicy, QGroupBox, QRadioButton,
    QButtonGroup, QCheckBox, QToolTip, QApplication, QComboBox
)
from PySide6.QtGui import (
    QPixmap, QImage, QColor, QFont, QPainter, QCursor,
    QPen, QBrush, QLinearGradient, QKeySequence, QAction,
    QDragEnterEvent, QDropEvent
)
from PySide6.QtCore import Qt, Signal, QSize, QTimer, QThread, QPoint, QRect, QRectF, QEvent

from .frameless import CustomTitleBar, FramelessWindowMixin, DarkModalDialog
from .pre_render_dialog import find_ffmpeg_path, PreRenderDialog
from .video_canvas import EmptyStateWidget
from .scrub_worker import ScrubDecodeWorker
from ..video_engine import VideoEngine
from ..config import ConfigManager
from ..utils import (
    frames_to_timecode, frames_to_smpte, timecode_to_frames,
    format_file_size, open_in_explorer, sanitize_filename
)


def is_hevc_video(video_path: str) -> bool:
    """Fast binary probe to detect if video contains HEVC / H.265 (hev1/hvc1)."""
    try:
        with open(video_path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(0)
            head = f.read(1024 * 1024)
            f.seek(max(0, size - 4 * 1024 * 1024))
            tail = f.read()
            combined = head + tail
            return b"hev1" in combined or b"hvc1" in combined
    except Exception:
        return False


def needs_audio_downmix(video_path: str) -> bool:
    """Fast binary probe to detect multi-channel Dolby Atmos / AC-3 / DTS tracks."""
    try:
        with open(video_path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(0)
            head = f.read(1024 * 1024)
            f.seek(max(0, size - 4 * 1024 * 1024))
            tail = f.read()
            combined = head + tail
            return b"ec-3" in combined or b"ac-3" in combined or b"dts" in combined
    except Exception:
        return False


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

    def run(self):
        if not os.path.exists(self.video_path):
            self.finished.emit(False, f"Source video not found: {self.video_path}", "", 0)
            return

        ext = Path(self.output_path).suffix.lower()
        is_mp4 = ext in (".mp4", ".m4v", ".mov")

        def _build_cmd(include_subs: bool = True):
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
                    cmd.extend(["-tag:v", "hvc1"])

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
            else:
                # Frame-Accurate Cut at 100% Original Resolution:
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

        startupinfo = None
        if os.name == "nt":
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startupinfo.wShowWindow = 0

        # Run with subtitle preservation first, then fallback to v+a if container lacks subtitle tag
        for attempt, with_subs in enumerate([True, False]):
            if self._is_cancelled:
                break

            cmd = _build_cmd(include_subs=with_subs)

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


class TrimPlayerCanvas(QWidget):
    """
    Proper Studio Video Canvas with:
    - Centered aspect-ratio preserving display
    - Clean letterbox/pillarbox background
    - On-screen Timecode and Resolution HUD
    - EmptyStateWidget with prominent Import Video action when no video loaded
    - Direct canvas click to toggle Play/Pause
    """
    canvas_clicked = Signal()
    file_dropped = Signal(str)
    import_requested = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setAcceptDrops(True)
        self.setFocusPolicy(Qt.ClickFocus)
        self.setMouseTracking(True)
        self.setMinimumHeight(280)

        self.current_qimage: Optional[QImage] = None
        self.raw_bgr_frame: Optional[np.ndarray] = None
        self._is_fast_mode: bool = False
        self.video_w = 0
        self.video_h = 0
        self.fps = 30.0
        self.current_frame = 0
        self.total_frames = 0

        # Empty State Widget centered via layout
        canvas_layout = QVBoxLayout(self)
        canvas_layout.setContentsMargins(0, 0, 0, 0)
        canvas_layout.setAlignment(Qt.AlignCenter)

        self.empty_state = EmptyStateWidget(self)
        self.empty_state.open_requested.connect(self.import_requested.emit)
        self.empty_state.file_dropped.connect(self.file_dropped.emit)
        canvas_layout.addWidget(self.empty_state, 0, Qt.AlignCenter)
        self.empty_state.show()

    def set_frame(self, bgr_array: Optional[np.ndarray], frame_idx: int, total_frames: int, fps: float):
        self.current_frame = frame_idx
        self.total_frames = total_frames
        self.fps = max(1.0, fps)

        if bgr_array is None:
            self.current_qimage = None
            self.raw_bgr_frame = None
            self.empty_state.show()
            self.update()
            return

        self.empty_state.hide()
        self.raw_bgr_frame = bgr_array
        h, w = bgr_array.shape[:2]
        self.video_w = w
        self.video_h = h
        ch = bgr_array.shape[2] if len(bgr_array.shape) > 2 else 1

        # Direct zero-copy wrapper onto self.raw_bgr_frame memory buffer (0.002ms latency)
        # Keeps full native 4K/8K pixel matrix without 50MB copy per frame
        self.current_qimage = QImage(self.raw_bgr_frame.data, w, h, ch * w, QImage.Format.Format_BGR888)
        self.update()

    def clear(self):
        self.current_qimage = None
        self.raw_bgr_frame = None
        self.video_w = 0
        self.video_h = 0
        self.empty_state.show()
        self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)
        if not self._is_fast_mode:
            painter.setRenderHint(QPainter.SmoothPixmapTransform)

        # Background
        painter.fillRect(self.rect(), QColor("#080a10"))

        if self.current_qimage is None:
            return

        cw, ch = self.width(), self.height()
        vw, vh = self.video_w, self.video_h
        if vw <= 0 or vh <= 0 or cw <= 10 or ch <= 10:
            return

        # Aspect Ratio Fit
        scale = min(cw / float(vw), ch / float(vh))
        target_w = int(round(vw * scale))
        target_h = int(round(vh * scale))
        target_x = (cw - target_w) // 2
        target_y = (ch - target_h) // 2

        target_rect = QRect(target_x, target_y, target_w, target_h)
        painter.drawImage(target_rect, self.current_qimage)

        # On-Screen HUD Overlay: Timecode & Frame (Bottom-Left)
        tc_str = frames_to_timecode(self.current_frame, self.fps)
        total_tc = frames_to_timecode(max(0, self.total_frames - 1), self.fps)
        hud_text = f"⏱ {tc_str} / {total_tc}   •   Frame {self.current_frame:,} / {self.total_frames:,}"

        painter.setFont(QFont("Consolas", 10, QFont.Bold))
        fm = painter.fontMetrics()
        text_w = fm.horizontalAdvance(hud_text) + 20
        text_h = fm.height() + 10

        hud_x = target_x + 12
        hud_y = target_y + target_h - text_h - 12
        if hud_y < target_y:
            hud_y = target_y + 12

        # Draw semi-transparent HUD pill
        painter.setPen(Qt.NoPen)
        painter.setBrush(QColor(10, 14, 22, 210))
        painter.drawRoundedRect(hud_x, hud_y, text_w, text_h, 5, 5)

        painter.setPen(QColor("#38bdf8"))
        painter.drawText(hud_x + 10, hud_y + fm.ascent() + 5, hud_text)

        # Top-left HUD pill is drawn above.
        # Top-right resolution badge removed per design requirements.

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.canvas_clicked.emit()
        super().mousePressEvent(event)

    def dragEnterEvent(self, event: QDragEnterEvent):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()

    def dropEvent(self, event: QDropEvent):
        urls = event.mimeData().urls()
        if urls:
            path = urls[0].toLocalFile()
            if path:
                self.file_dropped.emit(path)


class TrimRangeTimeline(QWidget):
    """
    Studio Visual Timeline Bar with:
    - Draggable Playhead Cursor (0ms zero-lag scrubbing)
    - Draggable In-Point Handle (amber bracket '[' on left)
    - Draggable Out-Point Handle (amber bracket ']' on right)
    - Draggable Trim Range (Shift+drag to slip/slide range without changing duration)
    - Direct click anywhere on the track to jump playhead
    - Dynamic hover cues, cursor switching, and rich timecode tooltips
    """
    seek_requested = Signal(int)
    scrub_started = Signal()
    scrub_finished = Signal()
    in_point_changed = Signal(int)
    out_point_changed = Signal(int)
    range_shifted = Signal(int, int)

    DRAG_NONE = 0
    DRAG_PLAYHEAD = 1
    DRAG_IN_POINT = 2
    DRAG_OUT_POINT = 3
    DRAG_RANGE = 4

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedHeight(38)
        self.setMouseTracking(True)
        self.setCursor(Qt.PointingHandCursor)

        self.total_frames = 1
        self.current_frame = 0
        self.in_point: Optional[int] = None
        self.out_point: Optional[int] = None
        self.fps = 30.0

        self._drag_mode = self.DRAG_NONE
        self._hover_element = self.DRAG_NONE
        self._drag_start_frame = 0
        self._initial_in = 0
        self._initial_out = 0
        self._drag_x: float = 0.0
        self._cached_ranges = []

    def set_cached_ranges(self, ranges):
        """Update cached RAM preview / stream segments."""
        self._cached_ranges = ranges or []
        self.update()

    @property
    def _dragging_playhead(self) -> bool:
        return self._drag_mode != self.DRAG_NONE

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
        margin = 14.0
        w = float(self.width() - (margin * 2))
        if self.total_frames <= 1 or w <= 0:
            return margin
        return margin + (frame / float(self.total_frames - 1)) * w

    def _x_to_frame(self, x: float) -> int:
        margin = 14.0
        w = float(self.width() - (margin * 2))
        if w <= 0 or self.total_frames <= 1:
            return 0
        ratio = max(0.0, min(1.0, (x - margin) / w))
        return int(round(ratio * (self.total_frames - 1)))

    def _hit_test(self, x: float, y: float = 20.0) -> int:
        if self.total_frames <= 1:
            return self.DRAG_NONE

        in_f = self.in_point if self.in_point is not None else 0
        out_f = self.out_point if self.out_point is not None else (self.total_frames - 1)
        x_in = self._frame_to_x(in_f)
        x_out = self._frame_to_x(out_f)
        px = self._frame_to_x(self.current_frame)

        dist_in = abs(x - x_in)
        dist_out = abs(x - x_out)
        dist_p = abs(x - px)

        # 1. TOP ZONE (y <= 13): Dedicated to Playhead Diamond!
        # Clicking or grabbing the diamond at top ALWAYS grabs the playhead
        if y <= 13 and dist_p <= 10:
            return self.DRAG_PLAYHEAD

        # 2. In-Point Handle Bracket (track zone y > 8)
        if dist_in <= 11 and dist_in <= dist_out:
            return self.DRAG_IN_POINT

        # 3. Out-Point Handle Bracket (track zone y > 8)
        if dist_out <= 11:
            return self.DRAG_OUT_POINT

        # 4. Playhead Needle (vertical needle)
        if dist_p <= 7:
            return self.DRAG_PLAYHEAD

        # 5. Highlighted range between In and Out
        if x_in < x < x_out:
            return self.DRAG_RANGE

        return self.DRAG_NONE

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)

        h = self.height()
        margin = 14
        track_y = 11
        track_h = 16
        track_w = self.width() - (margin * 2)

        # 1. Dark background track (CFX Void Surface)
        painter.setPen(QPen(QColor(255, 255, 255, 16), 1))
        painter.setBrush(QColor("#15151A"))
        painter.drawRoundedRect(margin, track_y, track_w, track_h, 4, 4)

        if self.total_frames <= 1:
            return

        in_f = self.in_point if self.in_point is not None else 0
        out_f = self.out_point if self.out_point is not None else (self.total_frames - 1)
        x_in = self._frame_to_x(in_f)
        x_out = self._frame_to_x(out_f)
        
        # When user is actively dragging the playhead, use continuous float x for 144Hz fluid motion
        if self._drag_mode == self.DRAG_PLAYHEAD:
            px = max(float(margin), min(float(self.width() - margin), float(self._drag_x)))
        else:
            px = self._frame_to_x(self.current_frame)

        # 2. Highlighted Trim Range (CFX Coral to Scarlet Gradient)
        if x_out > x_in:
            rw = max(3.0, x_out - x_in)
            grad = QLinearGradient(x_in, track_y, x_out, track_y)

            # Brighten range if hovered or dragging range
            if self._hover_element == self.DRAG_RANGE or self._drag_mode == self.DRAG_RANGE:
                grad.setColorAt(0.0, QColor(255, 98, 87, 220))
                grad.setColorAt(1.0, QColor(232, 51, 40, 220))
            else:
                grad.setColorAt(0.0, QColor(255, 74, 61, 190))
                grad.setColorAt(1.0, QColor(217, 42, 32, 190))

            painter.setPen(Qt.NoPen)
            painter.setBrush(QBrush(grad))
            painter.drawRoundedRect(QRectF(x_in, track_y, rw, track_h), 3, 3)

            # Subtle top border highlight on active range
            painter.setPen(QPen(QColor(255, 120, 110, 200), 1))
            painter.drawLine(int(x_in), track_y, int(x_out), track_y)

        # 2b. Glowing Emerald Green RAM Preview / GPU Stream Cache Bar
        if self._cached_ranges:
            painter.setPen(Qt.NoPen)
            painter.setBrush(QColor(16, 185, 129, 235))  # Glowing Emerald Green
            cache_y = track_y + track_h - 3
            for start_f, end_f in self._cached_ranges:
                x1 = self._frame_to_x(start_f)
                x2 = self._frame_to_x(end_f)
                cw = max(3.0, x2 - x1)
                painter.drawRoundedRect(QRectF(x1, cache_y, cw, 3), 1, 1)

        # 3. Draw In-Point Handle Bracket '['
        in_active = (self._hover_element == self.DRAG_IN_POINT or self._drag_mode == self.DRAG_IN_POINT)
        in_col = QColor("#fbbf24") if in_active else QColor("#f59e0b")
        handle_top = track_y - 4
        handle_bottom = track_y + track_h + 4

        # Glow / drop shadow if active
        if in_active:
            painter.setPen(QPen(QColor(245, 158, 11, 90), 6))
            painter.drawLine(int(x_in), handle_top, int(x_in), handle_bottom)

        # Solid vertical handle bar
        painter.setPen(QPen(in_col, 3))
        painter.drawLine(int(x_in), handle_top, int(x_in), handle_bottom)

        # Top bracket notch pointing right
        painter.setPen(Qt.NoPen)
        painter.setBrush(in_col)
        painter.drawPolygon([
            QPoint(int(x_in), handle_top),
            QPoint(int(x_in) + 8, handle_top),
            QPoint(int(x_in), handle_top + 8)
        ])
        # Bottom bracket notch pointing right
        painter.drawPolygon([
            QPoint(int(x_in), handle_bottom),
            QPoint(int(x_in) + 8, handle_bottom),
            QPoint(int(x_in), handle_bottom - 8)
        ])

        # 4. Draw Out-Point Handle Bracket ']'
        out_active = (self._hover_element == self.DRAG_OUT_POINT or self._drag_mode == self.DRAG_OUT_POINT)
        out_col = QColor("#fbbf24") if out_active else QColor("#f59e0b")

        if out_active:
            painter.setPen(QPen(QColor(245, 158, 11, 90), 6))
            painter.drawLine(int(x_out), handle_top, int(x_out), handle_bottom)

        # Solid vertical handle bar
        painter.setPen(QPen(out_col, 3))
        painter.drawLine(int(x_out), handle_top, int(x_out), handle_bottom)

        # Top bracket notch pointing left
        painter.setPen(Qt.NoPen)
        painter.setBrush(out_col)
        painter.drawPolygon([
            QPoint(int(x_out), handle_top),
            QPoint(int(x_out) - 8, handle_top),
            QPoint(int(x_out), handle_top + 8)
        ])
        # Bottom bracket notch pointing left
        painter.drawPolygon([
            QPoint(int(x_out), handle_bottom),
            QPoint(int(x_out) - 8, handle_bottom),
            QPoint(int(x_out), handle_bottom - 8)
        ])

        # 5. Draw Playhead Cursor (Video Player Style: Glowing Needle + Sculpted Head)
        p_active = (self._hover_element == self.DRAG_PLAYHEAD or self._drag_mode == self.DRAG_PLAYHEAD)

        # Outer soft cyan glow
        if p_active:
            painter.setPen(QPen(QColor(56, 189, 248, 100), 5))
            painter.drawLine(int(px), 0, int(px), h)
            painter.setPen(QPen(QColor(56, 189, 248, 160), 3))
            painter.drawLine(int(px), 0, int(px), h)

        # Crisp White Vertical Needle
        painter.setPen(QPen(QColor("#ffffff"), 2))
        painter.drawLine(int(px), 1, int(px), h - 1)

        # Sculpted Playhead Head / Diamond
        d_w = 7 if not p_active else 8
        d_top = 0
        d_mid = 7
        d_bot = 14
        cap_grad = QLinearGradient(px, d_top, px, d_bot)
        if p_active:
            cap_grad.setColorAt(0.0, QColor("#7dd3fc"))
            cap_grad.setColorAt(1.0, QColor("#0284c7"))
        else:
            cap_grad.setColorAt(0.0, QColor("#38bdf8"))
            cap_grad.setColorAt(1.0, QColor("#0369a1"))

        painter.setPen(QPen(QColor("#ffffff"), 1.5))
        painter.setBrush(QBrush(cap_grad))
        painter.drawPolygon([
            QPoint(int(px), d_top),
            QPoint(int(px) + d_w, d_mid),
            QPoint(int(px), d_bot),
            QPoint(int(px) - d_w, d_mid)
        ])

        # Center bright micro-dot inside cap
        painter.setPen(Qt.NoPen)
        painter.setBrush(QColor("#ffffff"))
        painter.drawEllipse(QPoint(int(px), d_mid), 2, 2)

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            pos = event.position() if hasattr(event, "position") else event.pos()
            x = pos.x()
            y = pos.y()
            f = self._x_to_frame(x)
            hit = self._hit_test(x, y)
            modifiers = event.modifiers()

            # Shift+Click on range -> Slip Range
            if (modifiers & Qt.ShiftModifier) and hit == self.DRAG_RANGE:
                self._drag_mode = self.DRAG_RANGE
                self._drag_start_frame = f
                self._initial_in = self.in_point if self.in_point is not None else 0
                self._initial_out = self.out_point if self.out_point is not None else (self.total_frames - 1)
                self.setCursor(Qt.ClosedHandCursor)
                self.scrub_started.emit()

            elif hit == self.DRAG_IN_POINT:
                self._drag_mode = self.DRAG_IN_POINT
                self.setCursor(Qt.SizeHorCursor)
                self.scrub_started.emit()
                max_in = (self.out_point - 1) if self.out_point is not None else (self.total_frames - 2)
                f = max(0, min(f, max(0, max_in)))
                self.in_point = f
                self.update()
                self.in_point_changed.emit(f)

            elif hit == self.DRAG_OUT_POINT:
                self._drag_mode = self.DRAG_OUT_POINT
                self.setCursor(Qt.SizeHorCursor)
                self.scrub_started.emit()
                min_out = (self.in_point + 1) if self.in_point is not None else 1
                f = max(min_out, min(f, self.total_frames - 1))
                self.out_point = f
                self.update()
                self.out_point_changed.emit(f)

            else:
                # Playhead scrub / jump
                self._drag_mode = self.DRAG_PLAYHEAD
                margin = 14.0
                self._drag_x = max(margin, min(float(self.width() - margin), float(x)))
                self.setCursor(Qt.PointingHandCursor)
                self.scrub_started.emit()
                self.current_frame = f
                self.update()
                self.seek_requested.emit(f)

    def mouseMoveEvent(self, event):
        pos = event.position() if hasattr(event, "position") else event.pos()
        x = pos.x()
        y = pos.y()
        f = self._x_to_frame(x)

        if self._drag_mode == self.DRAG_IN_POINT:
            max_in = (self.out_point - 1) if self.out_point is not None else (self.total_frames - 2)
            f = max(0, min(f, max(0, max_in)))
            if f != self.in_point:
                self.in_point = f
                self.update()
                self.in_point_changed.emit(f)

        elif self._drag_mode == self.DRAG_OUT_POINT:
            min_out = (self.in_point + 1) if self.in_point is not None else 1
            f = max(min_out, min(f, self.total_frames - 1))
            if f != self.out_point:
                self.out_point = f
                self.update()
                self.out_point_changed.emit(f)

        elif self._drag_mode == self.DRAG_RANGE:
            delta = f - self._drag_start_frame
            span = self._initial_out - self._initial_in
            new_in = self._initial_in + delta
            new_out = self._initial_out + delta

            if new_in < 0:
                new_in = 0
                new_out = min(self.total_frames - 1, new_in + span)
            elif new_out >= self.total_frames:
                new_out = self.total_frames - 1
                new_in = max(0, new_out - span)

            if new_in != self.in_point or new_out != self.out_point:
                self.in_point = new_in
                self.out_point = new_out
                self.update()
                self.range_shifted.emit(new_in, new_out)

        elif self._drag_mode == self.DRAG_PLAYHEAD:
            margin = 14.0
            self._drag_x = max(margin, min(float(self.width() - margin), float(x)))
            f = self._x_to_frame(x)
            f = max(0, min(f, self.total_frames - 1))
            # Smooth 144Hz continuous needle movement
            self.update()
            if f != self.current_frame:
                self.current_frame = f
                self.seek_requested.emit(f)

        else:
            # Hover detection
            hit = self._hit_test(x, y)
            if hit != self._hover_element:
                self._hover_element = hit
                self.update()

            in_f = self.in_point if self.in_point is not None else 0
            out_f = self.out_point if self.out_point is not None else (self.total_frames - 1)

            if hit in (self.DRAG_IN_POINT, self.DRAG_OUT_POINT):
                self.setCursor(Qt.SizeHorCursor)
            elif hit == self.DRAG_PLAYHEAD:
                self.setCursor(Qt.PointingHandCursor)
            elif hit == self.DRAG_RANGE:
                self.setCursor(Qt.PointingHandCursor)
            else:
                self.setCursor(Qt.PointingHandCursor)

            # Tooltip
            if hit == self.DRAG_IN_POINT:
                tc = frames_to_timecode(in_f, self.fps)
                msg = f"📍 In-Point: {tc} (Click & drag to adjust)"
            elif hit == self.DRAG_OUT_POINT:
                tc = frames_to_timecode(out_f, self.fps)
                msg = f"📍 Out-Point: {tc} (Click & drag to adjust)"
            elif hit == self.DRAG_PLAYHEAD:
                tc = frames_to_timecode(self.current_frame, self.fps)
                msg = f"⏱ Playhead: {tc} (Click & drag to scrub)"
            elif hit == self.DRAG_RANGE:
                dur = frames_to_timecode(max(0, out_f - in_f + 1), self.fps)
                msg = f"✂️ Trim Range: {dur} (Shift+Drag to slide range)"
            else:
                tc = frames_to_timecode(f, self.fps)
                msg = f"Frame {f:,} • {tc} (Click to jump)"

            QToolTip.showText(
                event.globalPosition().toPoint() if hasattr(event, "globalPosition") else event.globalPos(),
                msg,
                self
            )

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.LeftButton:
            if self._drag_mode == self.DRAG_PLAYHEAD:
                self.current_frame = self._x_to_frame(self._drag_x)
            self._drag_mode = self.DRAG_NONE
            self.setCursor(Qt.PointingHandCursor)
            self.scrub_finished.emit()
            self.update()

    def leaveEvent(self, event):
        super().leaveEvent(event)
        self._hover_element = self.DRAG_NONE
        self.update()


class VideoTrimmerWindow(FramelessWindowMixin, QMainWindow):
    """
    Studio Video Trimmer Window.
    - Full-featured standalone window with native studio dark chrome
    - Import option directly inside the window (no file popup before opening!)
    - Proper hardware-accelerated video player canvas with letterbox & on-screen HUD
    - High-precision wall-clock playback engine with loop trim range
    - Precision Timeframe inputs for In-Point and Out-Point (Timecode & Frame)
    - 100% Original Resolution Lossless Stream Copy (0s Re-encode) or Frame-Accurate Cut
    - One-click Back to Launcher or Back to Extractor
    """
    window_closed = Signal()
    return_to_launcher_requested = Signal(object)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.config = ConfigManager()
        self.video_engine = VideoEngine(cache_size=120)

        self.resize(1180, 780)
        self.setMinimumSize(880, 580)

        # Trimmer state
        self.in_point: int = 0
        self.out_point: int = 0
        self.current_frame_idx: int = 0
        self.is_playing = False
        self.loop_range = True

        # High-performance lag-free seek & scrub state (100% thread-safe)
        self._cached_src_file_size: int = 0
        self._last_seek_time = 0.0
        self._pending_seek_frame: Optional[int] = None

        # Dedicated Background Video Scrub Engine for 144Hz Butter-Smooth Playhead
        self.scrub_worker = ScrubDecodeWorker(self)
        self.scrub_worker.frame_ready.connect(self._on_scrub_frame_ready)
        self.scrub_worker.start()

        self._last_key_step_time = 0.0
        self._was_playing_before_scrub = False

        # High-precision playback clock
        self.play_timer = QTimer(self)
        self.play_timer.setTimerType(Qt.PreciseTimer)
        self.play_timer.timeout.connect(self._on_play_tick)
        self.playback_wall_start = 0.0
        self.playback_frame_start = 0

        self.worker: Optional[VideoTrimWorker] = None
        self.return_to_launcher_on_close = False

        self._setup_ui()
        self._setup_shortcuts()
        self.setup_frameless(self.custom_title_bar)

    def closeEvent(self, event):
        from PySide6.QtCore import QCoreApplication
        app = QCoreApplication.instance()
        if app is not None:
            try:
                app.removeEventFilter(self)
            except Exception:
                pass
        self.pause()
        if hasattr(self, 'scrub_worker') and self.scrub_worker:
            self.scrub_worker.stop()
        super().closeEvent(event)

    def _setup_ui(self):
        root_frame = QFrame(self)
        root_frame.setObjectName("windowRootFrame")
        self.setCentralWidget(root_frame)

        root_layout = QVBoxLayout(root_frame)
        root_layout.setContentsMargins(0, 0, 0, 0)
        root_layout.setSpacing(0)

        # 1. Sleek Frameless Title Bar
        self.custom_title_bar = CustomTitleBar(
            title="VIDEO TRIMMER STUDIO",
            icon_text="✂️",
            show_menus=False,
            parent=self
        )
        self.custom_title_bar.set_status_pill("100% Original Resolution Lossless Cutter", is_active=False)
        root_layout.addWidget(self.custom_title_bar)

        # 2. Workspace
        workspace = QWidget(self)
        main_layout = QVBoxLayout(workspace)
        main_layout.setContentsMargins(12, 8, 12, 10)
        main_layout.setSpacing(8)

        # ========================================================
        # A. TOP TOOLBAR: Back Button, Import Button, Video Specs
        # ========================================================
        top_bar = QHBoxLayout()
        top_bar.setContentsMargins(0, 0, 0, 0)
        top_bar.setSpacing(8)

        # Back Button
        self.btn_back = QPushButton("← Back to Launcher")
        self.btn_back.setFixedHeight(28)
        self.btn_back.setStyleSheet("""
            QPushButton {
                background: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #CBD5E1;
                font-weight: 600;
                font-size: 11px;
                border-radius: 6px;
                padding: 3px 12px;
            }
            QPushButton:hover {
                background: #1E1E26;
                color: #FFFFFF;
                border: 1px solid rgba(255, 255, 255, 0.16);
            }
        """)
        self.btn_back.clicked.connect(self._on_back_clicked)
        top_bar.addWidget(self.btn_back)

        # Import Video Button (Always available inside window)
        self.btn_import = QPushButton("📂 Import Video...")
        self.btn_import.setToolTip("Import or change video file (Shortcut: Ctrl+O)")
        self.btn_import.setFixedHeight(28)
        self.btn_import.setStyleSheet("""
            QPushButton {
                background: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.1);
                color: #F4F5F7;
                font-weight: 700;
                font-size: 11px;
                border-radius: 6px;
                padding: 3px 14px;
            }
            QPushButton:hover {
                background: #1E1E26;
                border: 1px solid rgba(255, 255, 255, 0.2);
                color: #FFFFFF;
            }
        """)
        self.btn_import.clicked.connect(self._on_browse_input_video)
        top_bar.addWidget(self.btn_import)

        self.lbl_file_name = QLabel("No video loaded")
        self.lbl_file_name.setStyleSheet("color: #94A3B8; font-weight: 500; font-size: 11px;")
        top_bar.addWidget(self.lbl_file_name, 1)

        # Video Specs Badges
        self.badge_res = QLabel("📐 0 × 0")
        self.badge_res.setStyleSheet("color: #F4F5F7; font-family: 'Consolas', monospace; font-size: 11px; font-weight: bold;")
        top_bar.addWidget(self.badge_res)

        self.badge_fps = QLabel("⚡ 0 FPS")
        self.badge_fps.setStyleSheet("color: #38BDF8; font-family: 'Consolas', monospace; font-size: 11px;")
        top_bar.addWidget(self.badge_fps)

        self.badge_dur = QLabel("⏱ 00:00:00")
        self.badge_dur.setStyleSheet("color: #CBD5E1; font-family: 'Consolas', monospace; font-size: 11px;")
        top_bar.addWidget(self.badge_dur)

        main_layout.addLayout(top_bar)

        # ========================================================
        # B. PROPER VIDEO PLAYER CANVAS
        # ========================================================
        self.player_canvas = TrimPlayerCanvas(self)
        self.player_canvas.canvas_clicked.connect(self.toggle_playback)
        self.player_canvas.file_dropped.connect(self.load_video)
        self.player_canvas.import_requested.connect(self._on_browse_input_video)
        main_layout.addWidget(self.player_canvas, 1)

        # ========================================================
        # C. TRANSPORT CONTROLS & RANGE TIMELINE
        # ========================================================
        # 1. Timeline
        self.timeline = TrimRangeTimeline(self)
        self.timeline.seek_requested.connect(self.seek_to_frame)
        self.timeline.in_point_changed.connect(self._on_timeline_in_changed)
        self.timeline.out_point_changed.connect(self._on_timeline_out_changed)
        self.timeline.range_shifted.connect(self._on_timeline_range_shifted)
        self.timeline.scrub_started.connect(self._on_scrub_started)
        self.timeline.scrub_finished.connect(self._on_scrub_finished)
        main_layout.addWidget(self.timeline)

        # 2. Symmetrical Transport Bar
        transport_box = QHBoxLayout()
        transport_box.setContentsMargins(4, 0, 4, 0)
        transport_box.setSpacing(4)
        transport_box.setAlignment(Qt.AlignCenter)

        # Home / Jump to In
        self.btn_jump_in = QPushButton("⏮ Jump In")
        self.btn_jump_in.setFixedHeight(28)
        self.btn_jump_in.setToolTip("Jump to In-Point (Home)")
        self.btn_jump_in.clicked.connect(lambda: self.seek_to_frame(self.in_point, immediate=True))
        transport_box.addWidget(self.btn_jump_in)

        # Step -10 frames
        self.btn_prev10 = QPushButton("« 10f")
        self.btn_prev10.setFixedHeight(28)
        self.btn_prev10.setToolTip("Step Back 10 Frames (Shift+Left)")
        self.btn_prev10.clicked.connect(lambda: self.seek_to_frame(self.current_frame_idx - 10, immediate=True))
        transport_box.addWidget(self.btn_prev10)

        # Step -1 frame
        self.btn_prev1 = QPushButton("◀ 1f")
        self.btn_prev1.setFixedHeight(28)
        self.btn_prev1.setToolTip("Step Back 1 Frame (Left Arrow)")
        self.btn_prev1.clicked.connect(lambda: self.seek_to_frame(self.current_frame_idx - 1, immediate=True))
        transport_box.addWidget(self.btn_prev1)

        # Play / Pause Button
        self.btn_play = QPushButton("▶ Play")
        self.btn_play.setFixedHeight(28)
        self.btn_play.setFixedWidth(80)
        self.btn_play.setToolTip("Play / Pause (Spacebar)")
        self.btn_play.setStyleSheet("""
            QPushButton {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #FF4A3D, stop:1 #D92A20);
                color: #FFFFFF;
                font-weight: bold;
                font-size: 12px;
                border: 1px solid rgba(255, 74, 61, 0.4);
                border-radius: 6px;
            }
            QPushButton:hover {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #FF6257, stop:1 #E83328);
                border: 1px solid rgba(255, 74, 61, 0.6);
            }
            QPushButton:pressed {
                background: #C0000A;
            }
        """)
        self.btn_play.clicked.connect(self.toggle_playback)
        transport_box.addWidget(self.btn_play)

        # Step +1 frame
        self.btn_next1 = QPushButton("1f ▶")
        self.btn_next1.setFixedHeight(28)
        self.btn_next1.setToolTip("Step Forward 1 Frame (Right Arrow)")
        self.btn_next1.clicked.connect(lambda: self.seek_to_frame(self.current_frame_idx + 1, immediate=True))
        transport_box.addWidget(self.btn_next1)

        # Step +10 frames
        self.btn_next10 = QPushButton("10f »")
        self.btn_next10.setFixedHeight(28)
        self.btn_next10.setToolTip("Step Forward 10 Frames (Shift+Right)")
        self.btn_next10.clicked.connect(lambda: self.seek_to_frame(self.current_frame_idx + 10, immediate=True))
        transport_box.addWidget(self.btn_next10)

        # End / Jump to Out
        self.btn_jump_out = QPushButton("⏭ Jump Out")
        self.btn_jump_out.setFixedHeight(28)
        self.btn_jump_out.setToolTip("Jump to Out-Point (End)")
        self.btn_jump_out.clicked.connect(lambda: self.seek_to_frame(self.out_point, immediate=True))
        transport_box.addWidget(self.btn_jump_out)

        transport_box.addSpacing(16)

        self.chk_loop = QCheckBox("🔁 Loop Range")
        self.chk_loop.setChecked(True)
        self.chk_loop.setStyleSheet("color: #CBD5E1; font-size: 11px;")
        transport_box.addWidget(self.chk_loop)

        transport_box.addSpacing(10)

        # Pre-render RAM Preview / GPU Stream Button
        self.btn_prerender = QPushButton("⚡ Pre-render")
        self.btn_prerender.setObjectName("amberBtn")
        self.btn_prerender.setToolTip("Pre-render frames into high-speed RAM or fast GPU stream for 0ms lag-free playback (Shortcut: P)")
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
        self.btn_prerender.clicked.connect(self.open_prerender_dialog)
        transport_box.addWidget(self.btn_prerender)

        main_layout.addLayout(transport_box)

        # ========================================================
        # D. STREAMLINED STUDIO TRIM & EXPORT CONTROLS
        # ========================================================
        ctrl_card = QFrame()
        ctrl_card.setObjectName("trimCtrlCard")
        ctrl_card.setStyleSheet("""
            QFrame#trimCtrlCard {
                background-color: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.06);
                border-radius: 10px;
            }
        """)
        ctrl_layout = QVBoxLayout(ctrl_card)
        ctrl_layout.setContentsMargins(12, 8, 12, 8)
        ctrl_layout.setSpacing(8)

        # ROW 1: IN / OUT TIMECODES, DURATION, MODE
        row_trim = QHBoxLayout()
        row_trim.setSpacing(8)

        # In-Point Entry
        lbl_in = QLabel("In:")
        lbl_in.setStyleSheet("color: #F59E0B; font-weight: bold; font-size: 11px;")
        row_trim.addWidget(lbl_in)

        self.txt_in_timecode = QLineEdit("00:00:00.000")
        self.txt_in_timecode.setFixedWidth(102)
        self.txt_in_timecode.setFixedHeight(27)
        self.txt_in_timecode.setToolTip("In-point start time (Enter timecode e.g. 00:01:20 or frame #)")
        self.txt_in_timecode.setStyleSheet("""
            QLineEdit {
                background: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #F4F5F7;
                font-family: 'Consolas', monospace;
                font-size: 12px;
                font-weight: bold;
                padding: 2px 6px;
                border-radius: 6px;
            }
            QLineEdit:focus { border: 1px solid #C0000A; }
        """)
        self.txt_in_timecode.editingFinished.connect(self._on_in_timecode_edited)
        row_trim.addWidget(self.txt_in_timecode)

        self.btn_mark_in = QPushButton("📍 Set (I)")
        self.btn_mark_in.setFixedHeight(27)
        self.btn_mark_in.setToolTip("Set In-point to current frame (Shortcut: I)")
        self.btn_mark_in.setStyleSheet("""
            QPushButton {
                background: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #CBD5E1;
                font-size: 11px;
                font-weight: 600;
                border-radius: 6px;
                padding: 2px 8px;
            }
            QPushButton:hover { background: #1E1E26; color: #FFFFFF; border: 1px solid rgba(255, 255, 255, 0.16); }
        """)
        self.btn_mark_in.clicked.connect(self.set_in_to_current)
        row_trim.addWidget(self.btn_mark_in)

        row_trim.addSpacing(6)

        # Out-Point Entry
        lbl_out = QLabel("Out:")
        lbl_out.setStyleSheet("color: #F59E0B; font-weight: bold; font-size: 11px;")
        row_trim.addWidget(lbl_out)

        self.txt_out_timecode = QLineEdit("00:00:00.000")
        self.txt_out_timecode.setFixedWidth(102)
        self.txt_out_timecode.setFixedHeight(27)
        self.txt_out_timecode.setToolTip("Out-point end time (Enter timecode e.g. 00:03:45 or frame #)")
        self.txt_out_timecode.setStyleSheet("""
            QLineEdit {
                background: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #F4F5F7;
                font-family: 'Consolas', monospace;
                font-size: 12px;
                font-weight: bold;
                padding: 2px 6px;
                border-radius: 6px;
            }
            QLineEdit:focus { border: 1px solid #C0000A; }
        """)
        self.txt_out_timecode.editingFinished.connect(self._on_out_timecode_edited)
        row_trim.addWidget(self.txt_out_timecode)

        self.btn_mark_out = QPushButton("📍 Set (O)")
        self.btn_mark_out.setFixedHeight(27)
        self.btn_mark_out.setToolTip("Set Out-point to current frame (Shortcut: O)")
        self.btn_mark_out.setStyleSheet("""
            QPushButton {
                background: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #CBD5E1;
                font-size: 11px;
                font-weight: 600;
                border-radius: 6px;
                padding: 2px 8px;
            }
            QPushButton:hover { background: #1E1E26; color: #FFFFFF; border: 1px solid rgba(255, 255, 255, 0.16); }
        """)
        self.btn_mark_out.clicked.connect(self.set_out_to_current)
        row_trim.addWidget(self.btn_mark_out)

        row_trim.addSpacing(8)

        # Trimmed Duration Badge
        self.lbl_trimmed_duration = QLabel("⏱ Trimmed: 00:00:00.000")
        self.lbl_trimmed_duration.setStyleSheet("""
            QLabel {
                background: #1A1A22;
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-radius: 6px;
                color: #38BDF8;
                font-family: 'Consolas', monospace;
                font-size: 11px;
                font-weight: bold;
                padding: 3px 10px;
            }
        """)
        row_trim.addWidget(self.lbl_trimmed_duration)

        row_trim.addStretch(1)

        # Trim Mode Radios
        lbl_mode = QLabel("Mode:")
        lbl_mode.setStyleSheet("color: #94A3B8; font-size: 11px; font-weight: 500;")
        row_trim.addWidget(lbl_mode)

        self.radio_copy = QRadioButton("⚡ Lossless (Fast)")
        self.radio_copy.setChecked(True)
        self.radio_copy.setToolTip("Instant copy with 0s re-encode and bit-exact original quality")
        self.radio_copy.setStyleSheet("color: #CBD5E1; font-size: 11px;")
        row_trim.addWidget(self.radio_copy)

        self.radio_accurate = QRadioButton("🎯 Frame-Accurate")
        self.radio_accurate.setToolTip("Frame-accurate cut with high quality re-encoding")
        self.radio_accurate.setStyleSheet("color: #CBD5E1; font-size: 11px;")
        row_trim.addWidget(self.radio_accurate)

        ctrl_layout.addLayout(row_trim)

        # ROW 2: DESTINATION FOLDER, FILENAME, AND EXPORT ACTION
        row_dest = QHBoxLayout()
        row_dest.setSpacing(6)

        # 1. Output Folder Section
        lbl_folder = QLabel("📁 Folder:")
        lbl_folder.setStyleSheet("color: #94A3B8; font-size: 11px; font-weight: 600;")
        row_dest.addWidget(lbl_folder)

        self.txt_output_dir = QLineEdit()
        self.txt_output_dir.setFixedHeight(28)
        self.txt_output_dir.setPlaceholderText("Select destination folder...")
        self.txt_output_dir.setStyleSheet("""
            QLineEdit {
                background: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #F4F5F7;
                font-family: 'Consolas', monospace;
                font-size: 11px;
                padding: 2px 8px;
                border-radius: 6px;
            }
            QLineEdit:focus { border: 1px solid #C0000A; }
        """)
        self.txt_output_dir.textChanged.connect(self._update_file_status)
        row_dest.addWidget(self.txt_output_dir, 3)

        btn_browse_folder = QPushButton("📂 Browse...")
        btn_browse_folder.setFixedHeight(28)
        btn_browse_folder.setToolTip("Select destination folder on your computer")
        btn_browse_folder.setStyleSheet("""
            QPushButton {
                background: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #CBD5E1;
                font-size: 11px;
                font-weight: 600;
                border-radius: 6px;
                padding: 3px 10px;
            }
            QPushButton:hover { background: #1E1E26; color: #FFFFFF; border: 1px solid rgba(255, 255, 255, 0.16); }
        """)
        btn_browse_folder.clicked.connect(self._on_browse_output_dir)
        row_dest.addWidget(btn_browse_folder)

        row_dest.addSpacing(6)

        # 2. File Name Section
        lbl_filename = QLabel("📄 Name:")
        lbl_filename.setStyleSheet("color: #94A3B8; font-size: 11px; font-weight: 600;")
        row_dest.addWidget(lbl_filename)

        self.txt_filename = QLineEdit()
        self.txt_filename.setFixedHeight(28)
        self.txt_filename.setPlaceholderText("Type file name...")
        self.txt_filename.setStyleSheet("""
            QLineEdit {
                background: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #F4F5F7;
                font-family: 'Consolas', monospace;
                font-size: 11px;
                font-weight: bold;
                padding: 2px 8px;
                border-radius: 6px;
            }
            QLineEdit:focus { border: 1px solid #C0000A; }
        """)
        self.txt_filename.textChanged.connect(self._update_file_status)
        row_dest.addWidget(self.txt_filename, 2)

        # Format Extension Selector
        self.combo_ext = QComboBox()
        self.combo_ext.setFixedHeight(28)
        self.combo_ext.addItems([".mp4", ".mov", ".mkv", ".webm"])
        self.combo_ext.setStyleSheet("""
            QComboBox {
                background: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #38BDF8;
                font-family: 'Consolas', monospace;
                font-size: 11px;
                font-weight: bold;
                padding: 2px 6px;
                border-radius: 6px;
            }
            QComboBox::drop-down { border: none; width: 14px; }
            QComboBox QAbstractItemView {
                background: #1A1A22;
                color: #FFFFFF;
                selection-background-color: #C0000A;
            }
        """)
        self.combo_ext.currentIndexChanged.connect(self._update_file_status)
        row_dest.addWidget(self.combo_ext)

        # File Availability / Overwrite Warning Badge
        self.lbl_file_status = QLabel("")
        self.lbl_file_status.setFixedHeight(22)
        row_dest.addWidget(self.lbl_file_status)

        # 3. Open Folder Checkbox
        self.chk_open_folder = QCheckBox("Open folder")
        self.chk_open_folder.setChecked(True)
        self.chk_open_folder.setStyleSheet("color: #94A3B8; font-size: 11px; margin-left: 2px;")
        row_dest.addWidget(self.chk_open_folder)

        # 4. Primary Export Action Button
        self.btn_export = QPushButton("✂️ Export Video")
        self.btn_export.setFixedHeight(30)
        self.btn_export.setObjectName("primaryBtn")
        self.btn_export.setStyleSheet("""
            QPushButton#primaryBtn {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #FF4A3D, stop:1 #D92A20);
                color: #FFFFFF;
                font-weight: bold;
                font-size: 12px;
                border: 1px solid rgba(255, 74, 61, 0.4);
                border-radius: 6px;
                padding: 0 16px;
            }
            QPushButton#primaryBtn:hover {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #FF6257, stop:1 #E83328);
                border: 1px solid rgba(255, 74, 61, 0.6);
            }
            QPushButton#primaryBtn:pressed {
                background: #C0000A;
            }
        """)
        self.btn_export.clicked.connect(self.start_trim_export)
        row_dest.addWidget(self.btn_export)

        ctrl_layout.addLayout(row_dest)

        # ROW 3: STATUS & INLINE PROGRESS BAR (hidden by default, shown during export)
        self.status_container = QWidget()
        row_status = QHBoxLayout(self.status_container)
        row_status.setContentsMargins(0, 4, 0, 0)
        row_status.setSpacing(8)

        self.lbl_status = QLabel("")
        self.lbl_status.setStyleSheet("color: #64748b; font-size: 11px;")
        row_status.addWidget(self.lbl_status, 1)

        self.prog_bar = QProgressBar()
        self.prog_bar.setFixedHeight(12)
        self.prog_bar.setFixedWidth(160)
        self.prog_bar.setRange(0, 100)
        self.prog_bar.setValue(0)
        self.prog_bar.setTextVisible(True)
        self.prog_bar.setStyleSheet("""
            QProgressBar {
                background: #0f131d;
                border: 1px solid #1e293b;
                border-radius: 3px;
                text-align: center;
                color: #ffffff;
                font-size: 9px;
                font-weight: bold;
            }
            QProgressBar::chunk {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #059669, stop:1 #10b981);
                border-radius: 2px;
            }
        """)
        self.prog_bar.hide()
        row_status.addWidget(self.prog_bar)

        self.status_container.hide()
        ctrl_layout.addWidget(self.status_container)

        main_layout.addWidget(ctrl_card)

        # Backward compatibility placeholders
        self.lbl_quality_guarantee = QLabel()
        self.lbl_est_size = QLabel()

        root_layout.addWidget(workspace, 1)

    def _setup_shortcuts(self):
        act_space = QAction(self)
        act_space.setShortcut(Qt.Key_Space)
        act_space.triggered.connect(self.toggle_playback)
        self.addAction(act_space)

        act_open = QAction(self)
        act_open.setShortcut(QKeySequence.Open) # Ctrl+O
        act_open.triggered.connect(self._on_browse_input_video)
        self.addAction(act_open)

        act_left = QAction(self)
        act_left.setShortcut(Qt.Key_Left)
        act_left.triggered.connect(lambda: self.seek_to_frame(self.current_frame_idx - 1))
        self.addAction(act_left)

        act_right = QAction(self)
        act_right.setShortcut(Qt.Key_Right)
        act_right.triggered.connect(lambda: self.seek_to_frame(self.current_frame_idx + 1))
        self.addAction(act_right)

        act_in = QAction(self)
        act_in.setShortcut("I")
        act_in.triggered.connect(self.set_in_to_current)
        self.addAction(act_in)

        act_out = QAction(self)
        act_out.setShortcut("O")
        act_out.triggered.connect(self.set_out_to_current)
        self.addAction(act_out)

        act_home = QAction(self)
        act_home.setShortcut(Qt.Key_Home)
        act_home.triggered.connect(lambda: self.seek_to_frame(self.in_point))
        self.addAction(act_home)

        act_end = QAction(self)
        act_end.setShortcut(Qt.Key_End)
        act_end.triggered.connect(lambda: self.seek_to_frame(self.out_point))
        self.addAction(act_end)

        act_esc = QAction(self)
        act_esc.setShortcut("Esc")
        act_esc.triggered.connect(self.close)
        self.addAction(act_esc)

        act_prerender = QAction(self)
        act_prerender.setShortcut("P")
        act_prerender.triggered.connect(self.open_prerender_dialog)
        self.addAction(act_prerender)

        from PySide6.QtCore import QCoreApplication
        app = QCoreApplication.instance()
        if app:
            app.installEventFilter(self)

    def eventFilter(self, watched, event):
        if event.type() == QEvent.KeyPress:
            if not self.isVisible() or not (self.isActiveWindow() or QApplication.activeWindow() == self or self.isAncestorOf(QApplication.focusWidget())):
                return super().eventFilter(watched, event)

            focused = QApplication.focusWidget()
            if isinstance(focused, (QLineEdit, QSpinBox)):
                return super().eventFilter(watched, event)

            key = event.key()
            modifiers = event.modifiers()

            if key == Qt.Key_Left:
                now = time.perf_counter()
                if event.isAutoRepeat() and (now - self._last_key_step_time) < 0.035:
                    return True
                self._last_key_step_time = now

                delta = -10 if (modifiers & Qt.ShiftModifier) else -1
                self.seek_to_frame(self.current_frame_idx + delta)
                return True
            elif key == Qt.Key_Right:
                now = time.perf_counter()
                if event.isAutoRepeat() and (now - self._last_key_step_time) < 0.035:
                    return True
                self._last_key_step_time = now

                delta = 10 if (modifiers & Qt.ShiftModifier) else 1
                self.seek_to_frame(self.current_frame_idx + delta)
                return True
            elif key == Qt.Key_Space:
                self.toggle_playback()
                return True
            elif key == Qt.Key_I and not (modifiers & (Qt.ControlModifier | Qt.AltModifier)):
                self.set_in_to_current()
                return True
            elif key == Qt.Key_O and not (modifiers & (Qt.ControlModifier | Qt.AltModifier)):
                self.set_out_to_current()
                return True
            elif key == Qt.Key_Home:
                self.seek_to_frame(self.in_point)
                return True
            elif key == Qt.Key_End:
                self.seek_to_frame(self.out_point)
                return True
            elif key == Qt.Key_P and not (modifiers & (Qt.ControlModifier | Qt.AltModifier)):
                self.open_prerender_dialog()
                return True

        return super().eventFilter(watched, event)

    # --- Loading Video ---
    def load_video(self, file_path: str):
        if not file_path or not os.path.exists(file_path):
            return

        self.pause()
        ok = self.video_engine.open(file_path)
        if not ok:
            QMessageBox.critical(self, "Error", f"Could not open video file:\n{file_path}")
            return

        info = self.video_engine.get_info()
        w, h, fps, total = info["width"], info["height"], info["fps"], info["total_frames"]

        self.lbl_file_name.setText(info.get("filename", "Video"))
        self.badge_res.setText(f"📐 {w} × {h}")
        self.badge_fps.setText(f"⚡ {fps:.2f} FPS")
        self.badge_dur.setText(f"⏱ {frames_to_timecode(max(0, total - 1), fps)}")
        self.lbl_quality_guarantee.setText(f"💎 100% Original Resolution ({w} × {h})")
        self.custom_title_bar.set_status_pill(f"🎬 {info.get('filename')} • {w}×{h}", is_active=True)
        self.scrub_worker.set_source(file_path)

        self.in_point = 0
        self.out_point = max(0, total - 1)
        self.video_engine.in_point = self.in_point
        self.video_engine.out_point = self.out_point
        self.current_frame_idx = 0

        self.timeline.set_context(total, fps, 0, self.in_point, self.out_point)

        # Output path default
        default_dir = self.config.get("default_output_dir", "")
        if not default_dir or not os.path.exists(default_dir):
            src_dir = str(Path(file_path).parent)
            default_dir = src_dir if os.path.exists(src_dir) else str(Path.home() / "Videos")
            if not os.path.exists(default_dir):
                default_dir = str(Path.home())

        self.txt_output_dir.setText(default_dir)

        # Match extension to source container
        src_ext = Path(file_path).suffix.lower()
        if src_ext in [".mp4", ".mov", ".mkv", ".webm"]:
            idx = self.combo_ext.findText(src_ext)
            if idx >= 0:
                self.combo_ext.setCurrentIndex(idx)
            else:
                self.combo_ext.setCurrentIndex(0)
        else:
            self.combo_ext.setCurrentIndex(0)

        # Propose unique initial filename to prevent overwriting
        stem = Path(file_path).stem
        ext = self.combo_ext.currentText().strip()
        unique_full = self._generate_unique_filename(default_dir, f"{stem}_trim", ext)
        self.txt_filename.setText(Path(unique_full).stem)
        self._update_file_status()

        try:
            self._cached_src_file_size = os.path.getsize(file_path)
        except Exception:
            self._cached_src_file_size = 0

        self._update_timeframe_inputs()
        self.seek_to_frame(0)
        self._update_timeline_cache_bar()
        self.lbl_status.setText("")
        self.status_container.hide()

    def _on_browse_input_video(self):
        filter_str = "Video Files (*.mp4 *.mkv *.mov *.avi *.webm *.m4v *.flv *.wmv *.ts);;All Files (*.*)"
        chosen, _ = QFileDialog.getOpenFileName(self, "Open Video for Trimming", "", filter_str)
        if chosen:
            self.load_video(chosen)

    def _on_browse_output_dir(self):
        cur = self.txt_output_dir.text().strip()
        if not cur or not os.path.exists(cur):
            cur = str(Path.home() / "Videos")
            if not os.path.exists(cur):
                cur = str(Path.home())

        chosen = QFileDialog.getExistingDirectory(self, "Select Destination Folder for Trimmed Video", cur)
        if chosen:
            self.txt_output_dir.setText(chosen)
            self.config.set("default_output_dir", chosen)
            self._update_file_status()

    def _generate_unique_filename(self, folder: str, base_name: str, ext: str) -> str:
        """Auto-increments file name (e.g. clip_trim_01.mp4) to prevent overwriting existing files."""
        if not folder:
            return f"{base_name}{ext}"

        if not ext.startswith("."):
            ext = "." + ext

        candidate = Path(folder) / f"{base_name}{ext}"
        if not candidate.exists():
            return str(candidate)

        import re
        m = re.search(r"^(.*?)(?:_(\d+))?$", base_name)
        if m:
            prefix = m.group(1)
            num_str = m.group(2)
            num = int(num_str) if num_str else 0
        else:
            prefix = base_name
            num = 0

        while True:
            num += 1
            candidate = Path(folder) / f"{prefix}_{num:02d}{ext}"
            if not candidate.exists():
                return str(candidate)

    def _update_file_status(self):
        """Show real-time badge indicating whether the file name is fresh or already exists."""
        if not hasattr(self, 'txt_output_dir') or not hasattr(self, 'txt_filename'):
            return

        folder = self.txt_output_dir.text().strip()
        name = self.txt_filename.text().strip()
        ext = self.combo_ext.currentText().strip() if hasattr(self, 'combo_ext') else ".mp4"

        if not folder or not name:
            self.lbl_file_status.setText("")
            return

        target = Path(folder) / f"{name}{ext}"
        if target.exists():
            self.lbl_file_status.setText("Exists")
            self.lbl_file_status.setStyleSheet("""
                color: #fbbf24;
                font-size: 10px;
                font-weight: bold;
                padding: 1px 6px;
                background: rgba(245, 158, 11, 0.15);
                border: 1px solid rgba(245, 158, 11, 0.35);
                border-radius: 3px;
            """)
            self.lbl_file_status.setToolTip(f"'{target.name}' already exists in this folder.\nExporting will prompt to auto-rename or overwrite.")
        else:
            self.lbl_file_status.setText("Unique")
            self.lbl_file_status.setStyleSheet("""
                color: #34d399;
                font-size: 10px;
                font-weight: bold;
                padding: 1px 6px;
                background: rgba(16, 185, 129, 0.12);
                border: 1px solid rgba(16, 185, 129, 0.3);
                border-radius: 3px;
            """)
            self.lbl_file_status.setToolTip("Filename is available and will not overwrite any file.")

    # --- Timeframe Synchronization & Validation ---
    def _update_timeframe_inputs(self):
        if not self.video_engine.is_loaded:
            return

        self.video_engine.in_point = self.in_point
        self.video_engine.out_point = self.out_point

        fps = self.video_engine.fps if self.video_engine.fps > 0 else 30.0

        # Update In-point
        self.txt_in_timecode.blockSignals(True)
        self.txt_in_timecode.setText(frames_to_timecode(self.in_point, fps))
        self.txt_in_timecode.blockSignals(False)

        # Update Out-point
        self.txt_out_timecode.blockSignals(True)
        self.txt_out_timecode.setText(frames_to_timecode(self.out_point, fps))
        self.txt_out_timecode.blockSignals(False)

        # Update Timeline Range
        self.timeline.set_range(self.in_point, self.out_point)
        self._update_timeframe_stats_only()

    def _on_in_timecode_edited(self):
        fps = self.video_engine.fps if self.video_engine.fps > 0 else 30.0
        text = self.txt_in_timecode.text().strip()
        f_idx = timecode_to_frames(text, fps)
        self.set_in_point(f_idx)

    def _on_in_spin_changed(self, val: int):
        self.set_in_point(val)

    def _on_out_timecode_edited(self):
        fps = self.video_engine.fps if self.video_engine.fps > 0 else 30.0
        text = self.txt_out_timecode.text().strip()
        f_idx = timecode_to_frames(text, fps)
        self.set_out_point(f_idx)

    def _on_out_spin_changed(self, val: int):
        self.set_out_point(val)

    def _on_timeline_in_changed(self, f_idx: int):
        self.in_point = f_idx
        self.video_engine.in_point = self.in_point
        fps = self.video_engine.fps if self.video_engine.fps > 0 else 30.0
        self.txt_in_timecode.blockSignals(True)
        self.txt_in_timecode.setText(frames_to_timecode(self.in_point, fps))
        self.txt_in_timecode.blockSignals(False)
        self._update_timeframe_stats_only()
        self.seek_to_frame(f_idx)

    def _on_timeline_out_changed(self, f_idx: int):
        self.out_point = f_idx
        self.video_engine.out_point = self.out_point
        fps = self.video_engine.fps if self.video_engine.fps > 0 else 30.0
        self.txt_out_timecode.blockSignals(True)
        self.txt_out_timecode.setText(frames_to_timecode(self.out_point, fps))
        self.txt_out_timecode.blockSignals(False)
        self._update_timeframe_stats_only()
        self.seek_to_frame(f_idx)

    def _on_timeline_range_shifted(self, in_pt: int, out_pt: int):
        self.in_point = in_pt
        self.out_point = out_pt
        self.video_engine.in_point = self.in_point
        self.video_engine.out_point = self.out_point
        fps = self.video_engine.fps if self.video_engine.fps > 0 else 30.0
        self.txt_in_timecode.blockSignals(True)
        self.txt_in_timecode.setText(frames_to_timecode(self.in_point, fps))
        self.txt_in_timecode.blockSignals(False)
        self.txt_out_timecode.blockSignals(True)
        self.txt_out_timecode.setText(frames_to_timecode(self.out_point, fps))
        self.txt_out_timecode.blockSignals(False)
        self._update_timeframe_stats_only()
        self.seek_to_frame(in_pt)

    def _update_timeframe_stats_only(self):
        if not self.video_engine.is_loaded:
            return
        fps = self.video_engine.fps if self.video_engine.fps > 0 else 30.0
        trimmed_frames = max(0, self.out_point - self.in_point + 1)
        dur_tc = frames_to_timecode(trimmed_frames, fps)
        size_str = ""
        if getattr(self, "_cached_src_file_size", 0) > 0:
            total_f = max(1, self.video_engine.total_frames)
            est_bytes = int((trimmed_frames / float(total_f)) * self._cached_src_file_size)
            size_str = f" • ~{format_file_size(est_bytes)}"
        self.lbl_trimmed_duration.setText(f"⏱ Trimmed: {dur_tc}{size_str}")

    def set_in_to_current(self):
        self.set_in_point(self.current_frame_idx)

    def set_out_to_current(self):
        self.set_out_point(self.current_frame_idx)

    def set_in_point(self, f_idx: int):
        if not self.video_engine.is_loaded:
            return
        f_idx = max(0, min(f_idx, self.video_engine.total_frames - 1))
        if f_idx >= self.out_point:
            self.out_point = min(self.video_engine.total_frames - 1, f_idx + 1)
        self.in_point = f_idx
        self._update_timeframe_inputs()
        self.seek_to_frame(self.in_point, immediate=True)

    def set_out_point(self, f_idx: int):
        if not self.video_engine.is_loaded:
            return
        f_idx = max(0, min(f_idx, self.video_engine.total_frames - 1))
        if f_idx <= self.in_point:
            self.in_point = max(0, f_idx - 1)
        self.out_point = f_idx
        self._update_timeframe_inputs()
        self.seek_to_frame(self.out_point, immediate=True)

    # --- Pre-Render RAM Preview & GPU Stream ---
    def open_prerender_dialog(self):
        """Open high-speed RAM Preview / GPU Stream Pre-render dialog."""
        if not self.video_engine.is_loaded:
            QMessageBox.information(self, "No Video", "Please open a video before pre-rendering.")
            return

        # Ensure video_engine In and Out points precisely reflect trimmer boundaries
        self.video_engine.in_point = self.in_point
        self.video_engine.out_point = self.out_point

        dlg = PreRenderDialog(self.video_engine, self)
        dlg.cache_updated.connect(self._update_timeline_cache_bar)
        dlg.exec()
        self._update_timeline_cache_bar()

    def _update_timeline_cache_bar(self):
        """Update trimmer timeline glowing green RAM preview cache bar."""
        if self.video_engine.is_loaded:
            ranges = self.video_engine.get_cached_ranges()
            self.timeline.set_cached_ranges(ranges)
            if getattr(self.video_engine, 'has_preview_stream', False) and getattr(self.video_engine, 'preview_path', None):
                self.scrub_worker.set_source(self.video_engine.preview_path)
            elif self.video_engine.video_path:
                self.scrub_worker.set_source(self.video_engine.video_path)

    # --- Seeking & Playback ---
    def _on_scrub_started(self):
        self._was_playing_before_scrub = self.is_playing
        if self.is_playing:
            self.pause()
        self.player_canvas._is_fast_mode = True

    def _on_scrub_finished(self):
        self.player_canvas._is_fast_mode = False
        if self.video_engine.is_loaded:
            self.seek_to_frame(self.current_frame_idx, immediate=True)

        if getattr(self, '_was_playing_before_scrub', False):
            self.play()

    def _on_scrub_frame_ready(self, frame: np.ndarray, frame_idx: int):
        """Asynchronously stream decoded preview frame into player canvas."""
        if not self.video_engine.is_loaded:
            return
        self.video_engine.put_frame_in_cache(frame_idx, frame)
        self.player_canvas.set_frame(
            frame,
            frame_idx,
            self.video_engine.total_frames,
            self.video_engine.fps
        )

    def seek_to_frame(self, frame_idx: int, immediate: bool = False):
        """Instant zero-lag seek handler. GUI needle updates instantly (0ms)."""
        if not self.video_engine.is_loaded:
            return

        frame_idx = max(0, min(frame_idx, self.video_engine.total_frames - 1))
        self.current_frame_idx = frame_idx

        # 1. Update timeline needle & HUD text instantly with 0ms zero-lag response
        self.timeline.set_current_frame(frame_idx)
        self.player_canvas.current_frame = frame_idx
        self.player_canvas.update()

        # 2. Check RAM cache first: if already cached in RAM, show in 0ms!
        cached = self.video_engine.frame_cache.get(frame_idx)
        if cached is not None:
            self.player_canvas.set_frame(
                cached,
                frame_idx,
                self.video_engine.total_frames,
                self.video_engine.fps
            )
            return

        # 3. Synchronous immediate decode for single-step button clicks or playback
        if immediate:
            self._do_decode(frame_idx)
            return

        # 4. Asynchronous background decode for mouse dragging:
        # Offloads heavy OpenCV FFmpeg decompression so the GUI playhead NEVER lags behind the cursor!
        self.scrub_worker.request_frame(frame_idx)

    def _do_decode(self, frame_idx: int):
        try:
            frame = self.video_engine.get_frame(frame_idx)
            if frame is not None:
                self.player_canvas.set_frame(
                    frame,
                    frame_idx,
                    self.video_engine.total_frames,
                    self.video_engine.fps
                )
        except Exception:
            pass

    def toggle_playback(self):
        if self.is_playing:
            self.pause()
        else:
            self.play()

    def play(self):
        if not self.video_engine.is_loaded:
            return

        self.is_playing = True
        self.btn_play.setText("⏸ Pause")
        self.btn_play.setStyleSheet("""
            QPushButton {
                background: #ea580c;
                color: #ffffff;
                font-weight: bold;
                font-size: 12px;
                border-radius: 4px;
            }
            QPushButton:hover { background: #f97316; }
        """)

        if self.current_frame_idx >= self.out_point or self.current_frame_idx < self.in_point:
            self.seek_to_frame(self.in_point)

        self.playback_wall_start = time.perf_counter()
        self.playback_frame_start = self.current_frame_idx
        self.play_timer.setInterval(8)
        self.play_timer.start()

    def pause(self):
        self.is_playing = False
        self.play_timer.stop()
        self.btn_play.setText("▶ Play")
        self.btn_play.setStyleSheet("""
            QPushButton {
                background: #4f46e5;
                color: #ffffff;
                font-weight: bold;
                font-size: 12px;
                border-radius: 4px;
            }
            QPushButton:hover { background: #6366f1; }
        """)

    def _on_play_tick(self):
        if not self.video_engine.is_loaded:
            self.pause()
            return

        elapsed = time.perf_counter() - self.playback_wall_start
        fps = self.video_engine.fps if self.video_engine.fps > 0 else 30.0
        target = self.playback_frame_start + int(round(elapsed * fps))

        if target > self.out_point:
            if self.chk_loop.isChecked():
                self.playback_wall_start = time.perf_counter()
                self.playback_frame_start = self.in_point
                target = self.in_point
            else:
                self.pause()
                return

        if target != self.current_frame_idx:
            self.seek_to_frame(target, immediate=True)

    # --- Trimming Export Execution ---
    def start_trim_export(self):
        if not self.video_engine.is_loaded:
            QMessageBox.warning(self, "No Video", "Please import a video first.")
            return

        folder = self.txt_output_dir.text().strip()
        if not folder:
            QMessageBox.warning(self, "Missing Folder", "Please select a destination folder.")
            return

        filename = self.txt_filename.text().strip()
        if not filename:
            QMessageBox.warning(self, "Missing Name", "Please type a file name for the trimmed video.")
            return

        # Sanitize filename (clean out illegal characters: \ / : * ? " < > |)
        clean_filename = sanitize_filename(filename)
        if clean_filename != filename:
            self.txt_filename.setText(clean_filename)
            filename = clean_filename

        ext = self.combo_ext.currentText().strip()
        if not ext.startswith("."):
            ext = "." + ext

        target_path = Path(folder) / f"{filename}{ext}"

        # -------------------------------------------------------------
        # OVERWRITE PREVENTION SAFEGUARD
        # -------------------------------------------------------------
        if target_path.exists():
            next_free = self._generate_unique_filename(folder, filename, ext)
            next_name = Path(next_free).name

            box = QMessageBox(self)
            box.setWindowTitle("File Already Exists")
            box.setIcon(QMessageBox.Question)
            box.setText(
                f"<b>'{target_path.name}'</b> already exists in this folder.<br><br>"
                "To prevent overwriting your existing video, what would you like to do?"
            )
            btn_auto = box.addButton(f"Auto-Rename to '{next_name}'", QMessageBox.AcceptRole)
            btn_overwrite = box.addButton("Overwrite Existing", QMessageBox.DestructiveRole)
            btn_cancel = box.addButton("Cancel", QMessageBox.RejectRole)
            box.setDefaultButton(btn_auto)

            box.exec()

            if box.clickedButton() == btn_cancel:
                return
            elif box.clickedButton() == btn_auto:
                out_path = next_free
                self.txt_filename.setText(Path(next_free).stem)
                self._update_file_status()
            else:
                out_path = str(target_path)
        else:
            out_path = str(target_path)

        Path(folder).mkdir(parents=True, exist_ok=True)

        fps = self.video_engine.fps if self.video_engine.fps > 0 else 30.0
        start_sec = self.in_point / fps
        end_sec = (self.out_point + 1) / fps

        if end_sec <= start_sec:
            QMessageBox.warning(self, "Invalid Range", "Out-point must be after in-point.")
            return

        ff_bin = find_ffmpeg_path()
        mode = "copy" if self.radio_copy.isChecked() else "accurate"

        self.btn_export.setEnabled(False)
        self.status_container.show()
        self.prog_bar.setValue(0)
        self.prog_bar.show()
        self.lbl_status.setText(f"Trimming segment from {frames_to_timecode(self.in_point, fps)} to {frames_to_timecode(self.out_point, fps)}...")
        self.lbl_status.setStyleSheet("color: #38bdf8; font-size: 11px;")

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

        if success:
            self.lbl_status.setText(f"{message} ({format_file_size(file_size)})")
            self.lbl_status.setStyleSheet("color: #10b981; font-weight: bold; font-size: 11px;")

            # Automatically advance filename to next increment for the next trim
            try:
                folder = self.txt_output_dir.text().strip()
                cur_name = self.txt_filename.text().strip()
                ext = self.combo_ext.currentText().strip()
                next_free = self._generate_unique_filename(folder, cur_name, ext)
                self.txt_filename.setText(Path(next_free).stem)
                self._update_file_status()
            except Exception:
                pass

            if self.chk_open_folder.isChecked():
                open_in_explorer(out_file)
        else:
            self.lbl_status.setText(message)
            self.lbl_status.setStyleSheet("color: #ef4444; font-size: 11px;")
            if "cancelled" not in message.lower():
                QMessageBox.critical(self, "Trim Error", message)

    def _on_back_clicked(self):
        self.close()

    def closeEvent(self, event):
        from PySide6.QtCore import QCoreApplication
        app = QCoreApplication.instance()
        if app is not None:
            try:
                app.removeEventFilter(self)
            except Exception:
                pass
        self.pause()
        if self.worker is not None and self.worker.isRunning():
            self.worker.cancel()
            self.worker.wait(500)

        self.window_closed.emit()
        if self.return_to_launcher_on_close:
            self.return_to_launcher_requested.emit(self)
            event.ignore()
            return
        super().closeEvent(event)
