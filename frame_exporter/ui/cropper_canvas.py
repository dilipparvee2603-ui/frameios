import cv2
import numpy as np
from typing import Optional, Tuple
from PySide6.QtWidgets import QWidget
from PySide6.QtGui import (
    QPainter, QImage, QColor, QPen, QBrush, QFont,
    QMouseEvent, QWheelEvent, QKeyEvent, QCursor
)
from PySide6.QtCore import Qt, QRectF, QPointF, Signal

# Handle constants
HANDLE_NONE = 0
HANDLE_TL = 1
HANDLE_TR = 2
HANDLE_BL = 3
HANDLE_BR = 4
HANDLE_TOP = 5
HANDLE_BOTTOM = 6
HANDLE_LEFT = 7
HANDLE_RIGHT = 8
HANDLE_INSIDE = 9

class CropperCanvas(QWidget):
    """
    Interactive canvas for precision aspect-ratio image cropping at 100% original pixel quality.
    Features:
    - 1-pixel keyboard nudging
    - Auto-detection of black letterbox/pillarbox bars
    - Real-time 4x pixel inspection loupe at crop edges
    - Native unscaled integer pixel slicing with zero quality degradation
    """
    crop_changed = Signal(int, int, int, int) # (x, y, w, h) in native pixels
    zoom_changed = Signal(float)
    files_dropped = Signal(list)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.StrongFocus)
        self.setAcceptDrops(True)

        # Source image state
        self.raw_bgr_frame: Optional[np.ndarray] = None
        self.orig_w: int = 0
        self.orig_h: int = 0
        
        # Display preview cache (for fast UI rendering)
        self.preview_qimage: Optional[QImage] = None
        
        # Viewport zoom & pan
        self.zoom_factor: float = 1.0
        self.pan_offset: QPointF = QPointF(0.0, 0.0)
        self.min_zoom: float = 0.2
        self.max_zoom: float = 12.0

        # Aspect ratio: width / height (None = Free)
        self.aspect_ratio: Optional[float] = 4.0 / 5.0 # default to 4:5
        
        # Crop rectangle in NATIVE image pixel coordinates
        self.crop_native: QRectF = QRectF(0, 0, 100, 100)

        # Active video content bounding box (cached when snapping past black bars)
        self.active_content_rect: Optional[QRectF] = None

        # Mouse interaction state
        self.active_mode = HANDLE_NONE
        self.hover_handle = HANDLE_NONE
        self.last_mouse_pos = QPointF()
        self.current_mouse_pos = QPointF()
        self.handle_size = 10 # in screen pixels

    def set_image(self, bgr_array: np.ndarray):
        """Load image array at full native resolution and initialize crop."""
        if bgr_array is None:
            self.raw_bgr_frame = None
            self.orig_w = 0
            self.orig_h = 0
            self.preview_qimage = None
            self.active_content_rect = None
            self.update()
            return

        self.raw_bgr_frame = bgr_array
        self.orig_h, self.orig_w, _ = bgr_array.shape
        self.active_content_rect = None

        # Reset zoom & pan
        self.zoom_factor = 1.0
        self.pan_offset = QPointF(0.0, 0.0)

        # Build preview QImage (native BGR888)
        self._update_preview_image()

        # Initialize crop to maximum centered box matching current aspect ratio
        self._reset_crop_to_aspect()
        self.update()

    def _update_preview_image(self):
        """Prepare display QImage."""
        if self.raw_bgr_frame is None:
            self.preview_qimage = None
            return

        h, w, ch = self.raw_bgr_frame.shape
        self.preview_qimage = QImage(
            self.raw_bgr_frame.data, w, h, ch * w, QImage.Format.Format_BGR888
        ).copy()

    def set_aspect_ratio(self, ratio: Optional[float]):
        """Set aspect ratio preset (e.g. 4/5, 16/9, 9/16, 1/1, or None for Free)."""
        self.aspect_ratio = ratio
        if self.orig_w > 0 and self.orig_h > 0:
            self._reset_crop_to_aspect()
            self.update()

    def _reset_crop_to_aspect(self):
        """Calculate the largest centered crop rectangle fitting the image/content for the current ratio."""
        if self.orig_w <= 0 or self.orig_h <= 0:
            return

        # If black bars were previously detected, constrain strictly within active content
        if self.active_content_rect is not None:
            base_x = self.active_content_rect.x()
            base_y = self.active_content_rect.y()
            base_w = self.active_content_rect.width()
            base_h = self.active_content_rect.height()
        else:
            base_x = 0.0
            base_y = 0.0
            base_w = float(self.orig_w)
            base_h = float(self.orig_h)

        if self.aspect_ratio is None:
            # Free: snap 100% to active content (or 95% of full frame if no bars detected yet)
            if self.active_content_rect is not None:
                w = base_w
                h = base_h
                x = base_x
                y = base_y
            else:
                w = base_w * 0.95
                h = base_h * 0.95
                x = (base_w - w) / 2.0
                y = (base_h - h) / 2.0
        else:
            r = self.aspect_ratio
            if (base_w / float(base_h)) >= r:
                # Content is wider than ratio: height fills 100% of content, centered horizontally
                h = base_h
                w = h * r
                y = base_y
                x = base_x + (base_w - w) / 2.0
            else:
                # Content is taller than ratio: width fills 100% of content, centered vertically
                w = base_w
                h = w / r
                x = base_x
                y = base_y + (base_h - h) / 2.0

        self.crop_native = QRectF(x, y, w, h)
        self._emit_crop_changed()

    def _emit_crop_changed(self):
        x = max(0, int(round(self.crop_native.x())))
        y = max(0, int(round(self.crop_native.y())))
        w = max(1, int(round(self.crop_native.width())))
        h = max(1, int(round(self.crop_native.height())))
        self.crop_changed.emit(x, y, w, h)

    # --- Black Bars Auto-Detection ---
    def auto_detect_black_bars(self) -> Tuple[bool, bool]:
        """
        Analyze image borders to detect active content bounds excluding letterbox/pillarbox bars.
        Ignores compression artifacts, codec noise, and any watermarks or logos located inside the black bars.
        Snaps crop inside active video content with 100% precision.
        Returns: (success: bool, has_black_bars: bool)
        """
        if self.raw_bgr_frame is None or self.orig_w <= 0 or self.orig_h <= 0:
            return False, False

        gray = cv2.cvtColor(self.raw_bgr_frame, cv2.COLOR_BGR2GRAY)
        h, w = gray.shape

        # Metrics for rows and columns:
        # A row/column is black bar if:
        # 1. Mean luminance < 16.0 AND
        # 2. Ratio of pixels with luminance > 22 is < 0.10 (watermarks/logos occupy < 8% of row/col)
        row_means = np.mean(gray, axis=1)
        row_ratios = np.mean(gray > 22, axis=1)

        def is_black_row(y_idx: int) -> bool:
            if y_idx < 0 or y_idx >= h:
                return True
            return row_means[y_idx] < 16.0 and row_ratios[y_idx] < 0.10

        col_means = np.mean(gray, axis=0)
        col_ratios = np.mean(gray > 22, axis=0)

        def is_black_col(x_idx: int) -> bool:
            if x_idx < 0 or x_idx >= w:
                return True
            return col_means[x_idx] < 16.0 and col_ratios[x_idx] < 0.10

        # Choose starting seed in the active middle portion (to avoid single dark rows in night scenes)
        mid_y_start, mid_y_end = int(h * 0.30), int(h * 0.70)
        if mid_y_end > mid_y_start:
            cy = mid_y_start + int(np.argmax(row_means[mid_y_start:mid_y_end]))
        else:
            cy = h // 2

        mid_x_start, mid_x_end = int(w * 0.30), int(w * 0.70)
        if mid_x_end > mid_x_start:
            cx = mid_x_start + int(np.argmax(col_means[mid_x_start:mid_x_end]))
        else:
            cx = w // 2

        # Check if the entire frame is nearly black (e.g. fade to black)
        if row_means[cy] < 12.0 and row_ratios[cy] < 0.05:
            if np.max(row_means) < 12.0:
                return False, False

        # Scan from center seed upward to find top black bar (requiring 2 consecutive black rows)
        top = 0
        for y in range(cy, 1, -1):
            if is_black_row(y) and is_black_row(y - 1):
                top = y + 1
                break

        # Scan from center seed downward to find bottom black bar (requiring 2 consecutive black rows)
        bottom = h - 1
        for y in range(cy, h - 2):
            if is_black_row(y) and is_black_row(y + 1):
                bottom = y - 1
                break

        # Scan from center seed leftward to find left black bar (requiring 2 consecutive black cols)
        left = 0
        for x in range(cx, 1, -1):
            if is_black_col(x) and is_black_col(x - 1):
                left = x + 1
                break

        # Scan from center seed rightward to find right black bar (requiring 2 consecutive black cols)
        right = w - 1
        for x in range(cx, w - 2):
            if is_black_col(x) and is_black_col(x + 1):
                right = x - 1
                break

        # Bounds sanity
        top = max(0, min(h - 1, top))
        bottom = max(top + 10, min(h - 1, bottom))
        left = max(0, min(w - 1, left))
        right = max(left + 10, min(w - 1, right))

        content_w = right - left + 1
        content_h = bottom - top + 1

        if content_w <= 40 or content_h <= 40:
            return False, False

        # Check if significant black bars exist (> 1% on any edge)
        has_bars = (top > 4) or (bottom < h - 5) or (left > 4) or (right < w - 5)

        self.active_content_rect = QRectF(left, top, content_w, content_h)

        if self.aspect_ratio is None:
            # Free: snap exact to active content!
            self.crop_native = QRectF(left, top, content_w, content_h)
        else:
            r = self.aspect_ratio
            if (content_w / float(content_h)) >= r:
                # Active content is wider than target ratio (e.g. 2.35:1 letterbox with 4:5, 1:1, 9:16, 16:9)
                # Height fills 100% of content, centered horizontally inside content
                target_h = float(content_h)
                target_w = target_h * r
                target_y = float(top)
                target_x = left + (content_w - target_w) / 2.0
            else:
                # Active content is taller than target ratio (e.g. 4:3 pillarbox with 16:9)
                # Width fills 100% of content, centered vertically inside content
                target_w = float(content_w)
                target_h = target_w / r
                target_x = float(left)
                target_y = top + (content_h - target_h) / 2.0

            self.crop_native = QRectF(target_x, target_y, target_w, target_h)

        self._emit_crop_changed()
        self.update()
        return True, has_bars

    # --- 1-Pixel Precision Nudging ---
    def nudge_crop(self, dx: int, dy: int):
        """Move crop box by exact pixel delta."""
        if self.raw_bgr_frame is None:
            return
        new_x = max(0.0, min(self.orig_w - self.crop_native.width(), self.crop_native.x() + dx))
        new_y = max(0.0, min(self.orig_h - self.crop_native.height(), self.crop_native.y() + dy))
        self.crop_native.moveTo(new_x, new_y)
        self._emit_crop_changed()
        self.update()

    def resize_crop_delta(self, dw: int):
        """Grow or shrink crop size by dw pixels maintaining aspect ratio."""
        if self.raw_bgr_frame is None:
            return
        rect = QRectF(self.crop_native)
        if self.aspect_ratio is None:
            new_w = max(40.0, min(self.orig_w - rect.x(), rect.width() + dw))
            rect.setWidth(new_w)
        else:
            r = self.aspect_ratio
            new_w = rect.width() + dw
            new_h = new_w / r
            if rect.x() + new_w <= self.orig_w and rect.y() + new_h <= self.orig_h and new_w >= 40.0 and new_h >= 40.0:
                rect.setWidth(new_w)
                rect.setHeight(new_h)
        self.crop_native = rect
        self._emit_crop_changed()
        self.update()

    def set_native_rect(self, x: int, y: int, w: int, h: int):
        """Set exact native pixel coordinates directly from numeric inputs."""
        if self.raw_bgr_frame is None:
            return
        w = max(20, min(self.orig_w, w))
        h = max(20, min(self.orig_h, h))
        x = max(0, min(self.orig_w - w, x))
        y = max(0, min(self.orig_h - h, y))
        self.crop_native = QRectF(x, y, w, h)
        self._emit_crop_changed()
        self.update()

    # --- Coordinate Transformations ---
    def _get_image_screen_rect(self) -> QRectF:
        if self.orig_w <= 0 or self.orig_h <= 0:
            return QRectF()

        vw = self.width()
        vh = self.height()
        fit_scale = min(vw / float(self.orig_w), vh / float(self.orig_h)) * 0.92
        draw_w = self.orig_w * fit_scale * self.zoom_factor
        draw_h = self.orig_h * fit_scale * self.zoom_factor
        
        draw_x = (vw - draw_w) / 2.0 + self.pan_offset.x()
        draw_y = (vh - draw_h) / 2.0 + self.pan_offset.y()
        return QRectF(draw_x, draw_y, draw_w, draw_h)

    def _native_to_screen(self, native_rect: QRectF) -> QRectF:
        img_rect = self._get_image_screen_rect()
        if img_rect.width() <= 0 or self.orig_w <= 0:
            return QRectF()
            
        sx = img_rect.x() + (native_rect.x() / self.orig_w) * img_rect.width()
        sy = img_rect.y() + (native_rect.y() / self.orig_h) * img_rect.height()
        sw = (native_rect.width() / self.orig_w) * img_rect.width()
        sh = (native_rect.height() / self.orig_h) * img_rect.height()
        return QRectF(sx, sy, sw, sh)

    def _screen_delta_to_native(self, dx_screen: float, dy_screen: float) -> Tuple[float, float]:
        img_rect = self._get_image_screen_rect()
        if img_rect.width() <= 0 or self.orig_w <= 0:
            return 0.0, 0.0
        dx_native = dx_screen * (self.orig_w / img_rect.width())
        dy_native = dy_screen * (self.orig_h / img_rect.height())
        return dx_native, dy_native

    def _screen_pos_to_native(self, pos: QPointF) -> QPointF:
        img_rect = self._get_image_screen_rect()
        if img_rect.width() <= 0 or self.orig_w <= 0:
            return QPointF(0, 0)
        nx = (pos.x() - img_rect.x()) * (self.orig_w / img_rect.width())
        ny = (pos.y() - img_rect.y()) * (self.orig_h / img_rect.height())
        return QPointF(nx, ny)

    # --- Painting ---
    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing, True)
        painter.setRenderHint(QPainter.SmoothPixmapTransform, True)

        # Background
        painter.fillRect(self.rect(), QColor("#090b10"))

        if self.preview_qimage is None or self.preview_qimage.isNull():
            painter.setPen(QColor("#64748b"))
            painter.setFont(QFont("Segoe UI", 12))
            painter.drawText(self.rect(), Qt.AlignCenter, "📂 No Image Selected\n\nDrag & drop images here or select an item from Media Bin")
            return

        img_rect = self._get_image_screen_rect()
        
        # 1. Draw image
        painter.drawImage(img_rect, self.preview_qimage)

        # 2. Draw darkened overlay outside crop area
        screen_crop = self._native_to_screen(self.crop_native)
        overlay_color = QColor(0, 0, 0, 165)
        
        # Top
        painter.fillRect(QRectF(img_rect.left(), img_rect.top(), img_rect.width(), max(0, screen_crop.top() - img_rect.top())), overlay_color)
        # Bottom
        painter.fillRect(QRectF(img_rect.left(), screen_crop.bottom(), img_rect.width(), max(0, img_rect.bottom() - screen_crop.bottom())), overlay_color)
        # Left
        painter.fillRect(QRectF(img_rect.left(), screen_crop.top(), max(0, screen_crop.left() - img_rect.left()), screen_crop.height()), overlay_color)
        # Right
        painter.fillRect(QRectF(screen_crop.right(), screen_crop.top(), max(0, img_rect.right() - screen_crop.right()), screen_crop.height()), overlay_color)

        # 3. Rule-of-Thirds Grid Lines
        grid_pen = QPen(QColor(255, 255, 255, 60), 1, Qt.DashLine)
        painter.setPen(grid_pen)
        x1 = screen_crop.left() + screen_crop.width() / 3.0
        x2 = screen_crop.left() + 2.0 * screen_crop.width() / 3.0
        painter.drawLine(QPointF(x1, screen_crop.top()), QPointF(x1, screen_crop.bottom()))
        painter.drawLine(QPointF(x2, screen_crop.top()), QPointF(x2, screen_crop.bottom()))
        y1 = screen_crop.top() + screen_crop.height() / 3.0
        y2 = screen_crop.top() + 2.0 * screen_crop.height() / 3.0
        painter.drawLine(QPointF(screen_crop.left(), y1), QPointF(screen_crop.right(), y1))
        painter.drawLine(QPointF(screen_crop.left(), y2), QPointF(screen_crop.right(), y2))

        # 4. Crop Rectangle Border (CFX Brand Accent)
        border_pen = QPen(QColor("#FF4A3D"), 2)
        painter.setPen(border_pen)
        painter.setBrush(Qt.NoBrush)
        painter.drawRect(screen_crop)

        # 5. Draw Handles
        self._draw_handles(painter, screen_crop)

        # 6. Zoom indicator if not 1.0
        if abs(self.zoom_factor - 1.0) > 0.02:
            badge_text = f"Zoom: {int(self.zoom_factor * 100)}%"
            painter.setPen(Qt.NoPen)
            painter.setBrush(QColor(13, 13, 17, 200))
            painter.drawRoundedRect(12, 12, 85, 24, 6, 6)
            painter.setPen(QColor("#F4F5F7"))
            painter.setFont(QFont("Consolas", 9, QFont.Bold))
            painter.drawText(12, 12, 85, 24, Qt.AlignCenter, badge_text)

        # 7. Draw Precision Pixel Magnifier Loupe if dragging/hovering near crop edge!
        if self.active_mode in (HANDLE_TL, HANDLE_TR, HANDLE_BL, HANDLE_BR, HANDLE_TOP, HANDLE_BOTTOM, HANDLE_LEFT, HANDLE_RIGHT, HANDLE_INSIDE):
            self._draw_magnifier_loupe(painter)

    def _draw_handles(self, painter: QPainter, sc: QRectF):
        hs = self.handle_size
        painter.setPen(QPen(QColor("#0f172a"), 1.5))
        painter.setBrush(QColor("#ffffff"))

        # Corners
        corners = [
            QRectF(sc.left() - hs / 2, sc.top() - hs / 2, hs, hs),
            QRectF(sc.right() - hs / 2, sc.top() - hs / 2, hs, hs),
            QRectF(sc.left() - hs / 2, sc.bottom() - hs / 2, hs, hs),
            QRectF(sc.right() - hs / 2, sc.bottom() - hs / 2, hs, hs),
        ]
        for c in corners:
            painter.drawRoundedRect(c, 2, 2)

        # Edges
        pw, ph = 14, 6
        edges = [
            QRectF(sc.center().x() - pw / 2, sc.top() - ph / 2, pw, ph),
            QRectF(sc.center().x() - pw / 2, sc.bottom() - ph / 2, pw, ph),
            QRectF(sc.left() - ph / 2, sc.center().y() - pw / 2, ph, pw),
            QRectF(sc.right() - ph / 2, sc.center().y() - pw / 2, ph, pw),
        ]
        for e in edges:
            painter.drawRoundedRect(e, 2, 2)

    def _draw_magnifier_loupe(self, painter: QPainter):
        """Draw a 4x pixel-level magnification loupe to inspect black bar edges with 100% precision."""
        if self.raw_bgr_frame is None:
            return

        # Determine native focus point under inspection
        native_pos = self._screen_pos_to_native(self.current_mouse_pos)
        nx = int(round(native_pos.x()))
        ny = int(round(native_pos.y()))
        nx = max(0, min(self.orig_w - 1, nx))
        ny = max(0, min(self.orig_h - 1, ny))

        patch_radius = 16
        x1 = max(0, nx - patch_radius)
        y1 = max(0, ny - patch_radius)
        x2 = min(self.orig_w, nx + patch_radius)
        y2 = min(self.orig_h, ny + patch_radius)

        patch = self.raw_bgr_frame[y1:y2, x1:x2]
        if patch.size == 0:
            return

        # Position loupe in the top-right corner of the canvas
        loupe_w, loupe_h = 130, 130
        loupe_x = self.width() - loupe_w - 16
        loupe_y = 16
        loupe_rect = QRectF(loupe_x, loupe_y, loupe_w, loupe_h)

        # Scale patch to loupe
        patch_resized = cv2.resize(patch, (loupe_w, loupe_h), interpolation=cv2.INTER_NEAREST)
        patch_qimg = QImage(patch_resized.data, loupe_w, loupe_h, loupe_w * 3, QImage.Format.Format_BGR888)

        # Draw loupe card with border
        painter.save()
        painter.setRenderHint(QPainter.Antialiasing, True)
        
        # Border glow
        painter.setPen(QPen(QColor("#FF4A3D"), 2))
        painter.setBrush(QColor("#15151A"))
        painter.drawRoundedRect(loupe_rect.adjusted(-2, -2, 2, 26), 6, 6)

        # Clip inside loupe
        painter.drawImage(loupe_rect, patch_qimg)

        # Crosshair at center
        cx = loupe_rect.center().x()
        cy = loupe_rect.center().y()
        painter.setPen(QPen(QColor("#E31B23"), 1.5))
        painter.drawLine(QPointF(cx - 8, cy), QPointF(cx + 8, cy))
        painter.drawLine(QPointF(cx, cy - 8), QPointF(cx, cy + 8))

        # Pixel coordinate info label under loupe
        pixel_bgr = self.raw_bgr_frame[ny, nx]
        b, g, r = int(pixel_bgr[0]), int(pixel_bgr[1]), int(pixel_bgr[2])
        label_text = f"X:{nx} Y:{ny} RGB({r},{g},{b})"
        painter.setPen(QColor("#f8fafc"))
        painter.setFont(QFont("Consolas", 8, QFont.Bold))
        painter.drawText(QRectF(loupe_x, loupe_y + loupe_h + 3, loupe_w, 20), Qt.AlignCenter, label_text)

        painter.restore()

    # --- Mouse & Handle Hit Testing ---
    def _hit_test(self, pos: QPointF) -> int:
        screen_crop = self._native_to_screen(self.crop_native)
        margin = self.handle_size + 4

        # Corners
        if (pos - screen_crop.topLeft()).manhattanLength() < margin:
            return HANDLE_TL
        if (pos - screen_crop.topRight()).manhattanLength() < margin:
            return HANDLE_TR
        if (pos - screen_crop.bottomLeft()).manhattanLength() < margin:
            return HANDLE_BL
        if (pos - screen_crop.bottomRight()).manhattanLength() < margin:
            return HANDLE_BR

        # Edges
        top_center = QPointF(screen_crop.center().x(), screen_crop.top())
        if (pos - top_center).manhattanLength() < margin:
            return HANDLE_TOP

        bottom_center = QPointF(screen_crop.center().x(), screen_crop.bottom())
        if (pos - bottom_center).manhattanLength() < margin:
            return HANDLE_BOTTOM

        left_center = QPointF(screen_crop.left(), screen_crop.center().y())
        if (pos - left_center).manhattanLength() < margin:
            return HANDLE_LEFT

        right_center = QPointF(screen_crop.right(), screen_crop.center().y())
        if (pos - right_center).manhattanLength() < margin:
            return HANDLE_RIGHT

        # Inside crop box
        if screen_crop.contains(pos):
            return HANDLE_INSIDE

        return HANDLE_NONE

    def mousePressEvent(self, event: QMouseEvent):
        if self.raw_bgr_frame is None:
            return

        self.setFocus()
        if event.button() == Qt.LeftButton:
            hit = self._hit_test(event.position())
            self.active_mode = hit
            self.last_mouse_pos = event.position()
            self.current_mouse_pos = event.position()
            self.update()
        elif event.button() == Qt.MiddleButton:
            self.active_mode = HANDLE_NONE
            self.last_mouse_pos = event.position()
            self.setCursor(Qt.ClosedHandCursor)

    def mouseMoveEvent(self, event: QMouseEvent):
        if self.raw_bgr_frame is None:
            return

        pos = event.position()
        self.current_mouse_pos = pos

        # Update cursor on hover when no button pressed
        if event.buttons() == Qt.NoButton:
            hit = self._hit_test(pos)
            self.hover_handle = hit
            if hit in (HANDLE_TL, HANDLE_BR):
                self.setCursor(Qt.SizeFDiagCursor)
            elif hit in (HANDLE_TR, HANDLE_BL):
                self.setCursor(Qt.SizeBDiagCursor)
            elif hit in (HANDLE_TOP, HANDLE_BOTTOM):
                self.setCursor(Qt.SizeVerCursor)
            elif hit in (HANDLE_LEFT, HANDLE_RIGHT):
                self.setCursor(Qt.SizeHorCursor)
            elif hit == HANDLE_INSIDE:
                self.setCursor(Qt.SizeAllCursor)
            else:
                self.setCursor(Qt.ArrowCursor)
            return

        delta_x = pos.x() - self.last_mouse_pos.x()
        delta_y = pos.y() - self.last_mouse_pos.y()
        self.last_mouse_pos = pos

        # Panning image (Middle click or dragging outside)
        if event.buttons() & Qt.MiddleButton or (event.buttons() & Qt.LeftButton and self.active_mode == HANDLE_NONE):
            self.pan_offset += QPointF(delta_x, delta_y)
            self.setCursor(Qt.ClosedHandCursor)
            self.update()
            return

        # Moving crop box
        if self.active_mode == HANDLE_INSIDE:
            dx_native, dy_native = self._screen_delta_to_native(delta_x, delta_y)
            new_x = max(0.0, min(self.orig_w - self.crop_native.width(), self.crop_native.x() + dx_native))
            new_y = max(0.0, min(self.orig_h - self.crop_native.height(), self.crop_native.y() + dy_native))
            self.crop_native.moveTo(new_x, new_y)
            self._emit_crop_changed()
            self.update()
            return

        # Resizing crop box
        if self.active_mode in (HANDLE_TL, HANDLE_TR, HANDLE_BL, HANDLE_BR, HANDLE_TOP, HANDLE_BOTTOM, HANDLE_LEFT, HANDLE_RIGHT):
            self._handle_resize(self.active_mode, delta_x, delta_y)
            self.update()

    def mouseReleaseEvent(self, event: QMouseEvent):
        self.active_mode = HANDLE_NONE
        self.setCursor(Qt.ArrowCursor)
        self.update()

    def _handle_resize(self, handle: int, delta_x: float, delta_y: float):
        dx_native, dy_native = self._screen_delta_to_native(delta_x, delta_y)
        rect = QRectF(self.crop_native)
        min_size = 20.0
        ratio = self.aspect_ratio

        if ratio is None:
            # Freeform resizing
            if handle in (HANDLE_BR, HANDLE_RIGHT, HANDLE_BOTTOM):
                if handle in (HANDLE_BR, HANDLE_RIGHT):
                    rect.setRight(max(rect.left() + min_size, min(self.orig_w, rect.right() + dx_native)))
                if handle in (HANDLE_BR, HANDLE_BOTTOM):
                    rect.setBottom(max(rect.top() + min_size, min(self.orig_h, rect.bottom() + dy_native)))
            elif handle in (HANDLE_TL, HANDLE_LEFT, HANDLE_TOP):
                if handle in (HANDLE_TL, HANDLE_LEFT):
                    rect.setLeft(min(rect.right() - min_size, max(0.0, rect.left() + dx_native)))
                if handle in (HANDLE_TL, HANDLE_TOP):
                    rect.setTop(min(rect.bottom() - min_size, max(0.0, rect.top() + dy_native)))
            elif handle == HANDLE_TR:
                rect.setRight(max(rect.left() + min_size, min(self.orig_w, rect.right() + dx_native)))
                rect.setTop(min(rect.bottom() - min_size, max(0.0, rect.top() + dy_native)))
            elif handle == HANDLE_BL:
                rect.setLeft(min(rect.right() - min_size, max(0.0, rect.left() + dx_native)))
                rect.setBottom(max(rect.top() + min_size, min(self.orig_h, rect.bottom() + dy_native)))
        else:
            # Ratio locked resizing
            if handle in (HANDLE_BR, HANDLE_RIGHT, HANDLE_BOTTOM):
                new_w = rect.width() + dx_native
                new_h = new_w / ratio
                if rect.left() + new_w > self.orig_w:
                    new_w = self.orig_w - rect.left()
                    new_h = new_w / ratio
                if rect.top() + new_h > self.orig_h:
                    new_h = self.orig_h - rect.top()
                    new_w = new_h * ratio
                if new_w >= min_size and new_h >= min_size:
                    rect.setWidth(new_w)
                    rect.setHeight(new_h)

            elif handle in (HANDLE_TL, HANDLE_LEFT, HANDLE_TOP):
                new_w = rect.width() - dx_native
                new_h = new_w / ratio
                new_left = rect.right() - new_w
                new_top = rect.bottom() - new_h
                if new_left < 0:
                    new_left = 0.0
                    new_w = rect.right()
                    new_h = new_w / ratio
                    new_top = rect.bottom() - new_h
                if new_top < 0:
                    new_top = 0.0
                    new_h = rect.bottom()
                    new_w = new_h * ratio
                    new_left = rect.right() - new_w
                if new_w >= min_size and new_h >= min_size and new_left >= 0 and new_top >= 0:
                    rect = QRectF(new_left, new_top, new_w, new_h)

            elif handle == HANDLE_TR:
                new_w = rect.width() + dx_native
                new_h = new_w / ratio
                new_top = rect.bottom() - new_h
                if rect.left() + new_w > self.orig_w:
                    new_w = self.orig_w - rect.left()
                    new_h = new_w / ratio
                    new_top = rect.bottom() - new_h
                if new_top < 0:
                    new_top = 0.0
                    new_h = rect.bottom()
                    new_w = new_h * ratio
                if new_w >= min_size and new_h >= min_size and new_top >= 0:
                    rect = QRectF(rect.left(), new_top, new_w, new_h)

            elif handle == HANDLE_BL:
                new_w = rect.width() - dx_native
                new_h = new_w / ratio
                new_left = rect.right() - new_w
                if new_left < 0:
                    new_left = 0.0
                    new_w = rect.right()
                    new_h = new_w / ratio
                if rect.top() + new_h > self.orig_h:
                    new_h = self.orig_h - rect.top()
                    new_w = new_h * ratio
                    new_left = rect.right() - new_w
                if new_w >= min_size and new_h >= min_size and new_left >= 0:
                    rect = QRectF(new_left, rect.top(), new_w, new_h)

        self.crop_native = rect.normalized()
        self._emit_crop_changed()

    def keyPressEvent(self, event: QKeyEvent):
        """Keyboard 1-pixel precision nudging."""
        key = event.key()
        modifiers = event.modifiers()
        step = 10 if (modifiers & Qt.ShiftModifier) else 1

        if modifiers & Qt.ControlModifier:
            # Resize by 1 pixel
            if key in (Qt.Key_Right, Qt.Key_Down):
                self.resize_crop_delta(step)
                return
            elif key in (Qt.Key_Left, Qt.Key_Up):
                self.resize_crop_delta(-step)
                return
        else:
            # Move by 1 pixel
            if key == Qt.Key_Left:
                self.nudge_crop(-step, 0)
                return
            elif key == Qt.Key_Right:
                self.nudge_crop(step, 0)
                return
            elif key == Qt.Key_Up:
                self.nudge_crop(0, -step)
                return
            elif key == Qt.Key_Down:
                self.nudge_crop(0, step)
                return

        super().keyPressEvent(event)

    def wheelEvent(self, event: QWheelEvent):
        """Mouse wheel zooms canvas without altering crop coordinates."""
        if self.raw_bgr_frame is None:
            return

        angle = event.angleDelta().y()
        zoom_mult = 1.15 if angle > 0 else 0.85
        old_zoom = self.zoom_factor
        new_zoom = max(self.min_zoom, min(self.max_zoom, old_zoom * zoom_mult))

        cursor_pos = event.position()
        view_center = QPointF(self.width() / 2.0, self.height() / 2.0)
        diff = cursor_pos - view_center - self.pan_offset
        self.pan_offset = self.pan_offset - (diff * (new_zoom / old_zoom - 1.0))
        self.zoom_factor = new_zoom
        self.zoom_changed.emit(self.zoom_factor)
        self.update()

    def reset_view(self):
        """Fit image to canvas."""
        self.zoom_factor = 1.0
        self.pan_offset = QPointF(0.0, 0.0)
        self.zoom_changed.emit(self.zoom_factor)
        self.update()

    # --- Extraction at Original Quality ---
    def get_cropped_bgr(self) -> Optional[np.ndarray]:
        """
        Extract the cropped region directly from the raw original resolution BGR buffer.
        Zero quality degradation, zero downsampling.
        """
        if self.raw_bgr_frame is None or self.orig_w <= 0 or self.orig_h <= 0:
            return None

        x = max(0, min(self.orig_w - 1, int(round(self.crop_native.x()))))
        y = max(0, min(self.orig_h - 1, int(round(self.crop_native.y()))))
        w = max(1, min(self.orig_w - x, int(round(self.crop_native.width()))))
        h = max(1, min(self.orig_h - y, int(round(self.crop_native.height()))))

        return self.raw_bgr_frame[y : y + h, x : x + w].copy()

    # --- Drag & Drop ---
    def dragEnterEvent(self, event):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()

    def dragMoveEvent(self, event):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()

    def dropEvent(self, event):
        paths = []
        for url in event.mimeData().urls():
            p = url.toLocalFile()
            if p:
                paths.append(p)
        if paths:
            self.files_dropped.emit(paths)
            event.acceptProposedAction()
