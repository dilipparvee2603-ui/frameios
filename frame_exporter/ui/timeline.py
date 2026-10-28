from PySide6.QtWidgets import QSlider, QToolTip
from PySide6.QtGui import QPainter, QColor, QPen, QBrush, QMouseEvent, QWheelEvent
from PySide6.QtCore import Qt, Signal, QPoint
from ..utils import frames_to_timecode

class TimelineSlider(QSlider):
    """
    Custom Timeline Scrubber for frame-accurate navigation.
    - Click-to-jump directly anywhere along the timeline
    - Hover tooltip showing target frame and timecode
    - In-point and Out-point visual range indicators
    """
    frame_jumped = Signal(int)
    scrub_started = Signal()
    scrub_finished = Signal()

    def __init__(self, orientation=Qt.Horizontal, parent=None):
        super().__init__(orientation, parent)
        self.setFocusPolicy(Qt.NoFocus)
        self.setMouseTracking(True)
        self.fps = 30.0
        self.in_point = None
        self.out_point = None
        self._is_scrubbing = False
        self._cached_ranges = []  # List of (start_frame, end_frame) cached in RAM
        self._scene_cuts = []     # List of detected scene cut frame indices

    def set_scene_cuts(self, cuts):
        """Update detected shot cuts to render amber pins across the timeline."""
        self._scene_cuts = sorted(cuts or [])
        self.update()

    def set_cached_ranges(self, ranges):
        """Update cached frame segments to render green RAM preview bar."""
        self._cached_ranges = ranges or []
        self.update()

    def set_fps(self, fps: float):
        self.fps = max(0.1, fps)

    def set_range_markers(self, in_frame, out_frame):
        self.in_point = in_frame
        self.out_point = out_frame
        self.update()

    def _pos_to_frame(self, x_pos: int) -> int:
        """Convert pixel x coordinate to frame index."""
        w = self.width() - 20
        if w <= 0 or self.maximum() <= 0:
            return 0
        x = max(0, min(x_pos - 10, w))
        ratio = x / float(w)
        return int(round(ratio * (self.maximum() - self.minimum()) + self.minimum()))

    def mousePressEvent(self, event: QMouseEvent):
        if event.button() == Qt.LeftButton:
            self._is_scrubbing = True
            self.scrub_started.emit()
            target_frame = self._pos_to_frame(event.pos().x())
            self.setValue(target_frame)
            self.frame_jumped.emit(target_frame)
            event.accept()
        else:
            super().mousePressEvent(event)

    def mouseMoveEvent(self, event: QMouseEvent):
        target_frame = self._pos_to_frame(event.pos().x())
        
        # If scrubbing, update value
        if self._is_scrubbing:
            self.setValue(target_frame)
            self.frame_jumped.emit(target_frame)
            event.accept()
        else:
            # Check if hovering near a detected scene cut pin
            if self._scene_cuts and self.maximum() > 0:
                w = self.width() - 20
                total_range = float(self.maximum() - self.minimum())
                mouse_x = event.pos().x()
                matched_cut = None
                matched_idx = 0
                matched_cx = 0
                for i, cut_f in enumerate(self._scene_cuts):
                    r = (cut_f - self.minimum()) / total_range
                    cx = 10 + r * w
                    if abs(mouse_x - cx) <= 6:
                        matched_cut = cut_f
                        matched_idx = i + 1
                        matched_cx = cx
                        break
                if matched_cut is not None:
                    tc = frames_to_timecode(matched_cut, self.fps)
                    tooltip_text = f"🎬 Shot Cut #{matched_idx}\nFrame {matched_cut:,} • {tc}"
                    global_pos = self.mapToGlobal(QPoint(int(matched_cx), -34))
                    QToolTip.showText(global_pos, tooltip_text, self)
                    event.accept()
                    return

            # Show standard hover timecode tooltip
            tc = frames_to_timecode(target_frame, self.fps)
            tooltip_text = f"Frame {target_frame}\n{tc}"
            global_pos = self.mapToGlobal(QPoint(event.pos().x(), -28))
            QToolTip.showText(global_pos, tooltip_text, self)
            super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event: QMouseEvent):
        if event.button() == Qt.LeftButton and self._is_scrubbing:
            self._is_scrubbing = False
            self.scrub_finished.emit()
            event.accept()
        else:
            super().mouseReleaseEvent(event)

    def wheelEvent(self, event: QWheelEvent):
        # Stepping via mouse wheel over timeline
        delta = 1 if event.angleDelta().y() > 0 else -1
        new_val = max(self.minimum(), min(self.maximum(), self.value() + delta))
        if new_val != self.value():
            self.setValue(new_val)
            self.frame_jumped.emit(new_val)
        event.accept()

    def paintEvent(self, event):
        # Let base QSlider render groove & thumb
        super().paintEvent(event)

        # Draw RAM preview cache segments (emerald green line like Premiere Pro / DaVinci Resolve)
        if self._cached_ranges and self.maximum() > 0:
            painter = QPainter(self)
            painter.setRenderHint(QPainter.Antialiasing, True)
            w = self.width() - 20
            total_range = float(self.maximum() - self.minimum())
            track_y = self.height() // 2 - 8
            painter.setPen(Qt.NoPen)
            painter.setBrush(QColor(16, 185, 129, 230))  # Glowing Emerald Green
            for start_f, end_f in self._cached_ranges:
                r1 = max(0.0, min(1.0, (start_f - self.minimum()) / total_range))
                r2 = max(0.0, min(1.0, (end_f - self.minimum()) / total_range))
                x1 = int(10 + r1 * w)
                x2 = int(10 + r2 * w)
                width = max(3, x2 - x1)
                painter.drawRoundedRect(x1, track_y, width, 3, 1, 1)

        # Draw In / Out markers overlay if set
        if (self.in_point is not None or self.out_point is not None) and self.maximum() > 0:
            painter = QPainter(self)
            painter.setRenderHint(QPainter.Antialiasing, True)
            
            w = self.width() - 20
            total_range = float(self.maximum() - self.minimum())
            
            in_x = 10
            if self.in_point is not None:
                in_ratio = max(0.0, min(1.0, (self.in_point - self.minimum()) / total_range))
                in_x = 10 + in_ratio * w
                
            out_x = 10 + w
            if self.out_point is not None:
                out_ratio = max(0.0, min(1.0, (self.out_point - self.minimum()) / total_range))
                out_x = 10 + out_ratio * w

            # Draw highlighted range bar
            if self.in_point is not None or self.out_point is not None:
                painter.fillRect(int(in_x), self.height() // 2 - 2, int(max(2, out_x - in_x)), 4, QColor(255, 74, 61, 180))
                
            # Draw In Marker triangle
            if self.in_point is not None:
                painter.setPen(Qt.NoPen)
                painter.setBrush(QColor("#10b981"))
                painter.drawRect(int(in_x) - 1, self.height() // 2 - 8, 3, 16)
                
            # Draw Out Marker triangle
            if self.out_point is not None:
                painter.setPen(Qt.NoPen)
                painter.setBrush(QColor("#f43f5e"))
                painter.drawRect(int(out_x) - 1, self.height() // 2 - 8, 3, 16)

        # Draw Amber Scene Cut Marker Pins (#f59e0b)
        if self._scene_cuts and self.maximum() > 0:
            painter = QPainter(self)
            painter.setRenderHint(QPainter.Antialiasing, True)
            w = self.width() - 20
            total_range = float(self.maximum() - self.minimum())
            track_y = self.height() // 2

            painter.setPen(Qt.NoPen)
            painter.setBrush(QColor(245, 158, 11, 235))  # Glowing Amber Gold

            for cut_f in self._scene_cuts:
                r = max(0.0, min(1.0, (cut_f - self.minimum()) / total_range))
                cx = int(10 + r * w)

                # Vertical tick pin line
                painter.drawRect(cx - 1, track_y - 8, 2, 16)

                # Diamond top pin head
                poly = [
                    QPoint(cx, track_y - 12),
                    QPoint(cx + 3, track_y - 9),
                    QPoint(cx, track_y - 6),
                    QPoint(cx - 3, track_y - 9)
                ]
                painter.drawPolygon(poly)
