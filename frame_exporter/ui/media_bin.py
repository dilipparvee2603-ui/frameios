import os
import uuid
from pathlib import Path
from typing import Optional, List, Dict

import cv2
import numpy as np

from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QPushButton, QLabel,
    QListWidget, QListWidgetItem, QFileDialog, QMessageBox,
    QFrame, QSizePolicy, QProgressBar, QAbstractItemView, QMenu
)
from PySide6.QtGui import QPixmap, QImage, QColor, QFont, QPainter, QCursor, QDragEnterEvent, QDropEvent, QIcon
from PySide6.QtCore import Qt, Signal, QSize, QTimer, QRectF

from ..utils import format_file_size, sanitize_filename

IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tiff", ".tif"}


def make_thumbnail(bgr: np.ndarray, target_w: int = 108, target_h: int = 68) -> QPixmap:
    """
    Generate a crisp, high-quality thumbnail preserving aspect ratio with dark letterbox padding.
    Fast SIMD downsampling.
    """
    if bgr is None or bgr.size == 0:
        pix = QPixmap(target_w, target_h)
        pix.fill(QColor("#121622"))
        return pix

    h, w = bgr.shape[:2]
    if w <= 0 or h <= 0:
        pix = QPixmap(target_w, target_h)
        pix.fill(QColor("#121622"))
        return pix

    scale = min(target_w / float(w), target_h / float(h))
    new_w = max(1, min(target_w, int(round(w * scale))))
    new_h = max(1, min(target_h, int(round(h * scale))))

    # Use INTER_AREA for downsampling (crisp, anti-aliased)
    resized = cv2.resize(bgr, (new_w, new_h), interpolation=cv2.INTER_AREA)

    # Pad onto dark letterbox canvas
    canvas = np.zeros((target_h, target_w, 3), dtype=np.uint8)
    canvas[:] = (26, 21, 21)  # #15151A in BGR: (B=26, G=21, R=21)
    x_off = (target_w - new_w) // 2
    y_off = (target_h - new_h) // 2
    canvas[y_off : y_off + new_h, x_off : x_off + new_w] = resized

    qimg = QImage(canvas.data, target_w, target_h, target_w * 3, QImage.Format.Format_BGR888).copy()
    return QPixmap.fromImage(qimg)


class BinItem:
    """
    Represents an image asset inside the Media Bin.
    Supports lazy BGR decoding for disk files to keep RAM usage minimal even with 500+ 4K images.
    """
    def __init__(
        self,
        name: str,
        width: int,
        height: int,
        file_path: Optional[str] = None,
        bgr_array: Optional[np.ndarray] = None,
        thumb_pixmap: Optional[QPixmap] = None,
        file_size_str: str = "",
        frame_idx: int = 0
    ):
        self.item_id: str = str(uuid.uuid4())
        self.name: str = name
        self.width: int = width
        self.height: int = height
        self.file_path: Optional[str] = file_path
        self._bgr_array: Optional[np.ndarray] = bgr_array
        self.thumb_pixmap: QPixmap = thumb_pixmap or QPixmap()
        self.file_size_str: str = file_size_str
        self.frame_idx: int = frame_idx
        self.saved_crop_rect: Optional[tuple] = None  # (x, y, w, h)
        self.saved_aspect_ratio: Optional[float] = None

    def get_bgr(self) -> Optional[np.ndarray]:
        """Return native resolution BGR image array (cached or decoded on demand)."""
        if self._bgr_array is not None:
            return self._bgr_array
        if self.file_path and os.path.exists(self.file_path):
            try:
                with open(self.file_path, "rb") as f:
                    bytes_data = bytearray(f.read())
                numpy_arr = np.asarray(bytes_data, dtype=np.uint8)
                bgr = cv2.imdecode(numpy_arr, cv2.IMREAD_COLOR)
                return bgr
            except Exception:
                return None
        return None


class MediaBinWidget(QWidget):
    """
    Dedicated visual Media Bin for the Image Cropper.
    Clean pure-visual thumbnail gallery (no cluttering filenames), multi-image import,
    drag-and-drop, and batch export.
    """
    item_selected = Signal(object)  # BinItem
    items_changed = Signal(int)     # total count
    batch_export_requested = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.items: List[BinItem] = []
        self.items_by_id: Dict[str, BinItem] = {}
        self.current_selected_id: Optional[str] = None

        self.setAcceptDrops(True)
        self._setup_ui()

    def _setup_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 4)
        layout.setSpacing(6)

        # ========================================================
        # 1. HEADER: Title, Count Badge & Clear
        # ========================================================
        header = QHBoxLayout()
        header.setContentsMargins(4, 2, 4, 2)
        header.setSpacing(6)

        lbl_icon = QLabel("🗂️")
        lbl_icon.setStyleSheet("font-size: 13px;")
        header.addWidget(lbl_icon)

        lbl_title = QLabel("Media Bin")
        lbl_title.setStyleSheet("color: #F4F5F7; font-weight: 700; font-size: 12px;")
        header.addWidget(lbl_title)

        self.lbl_count = QLabel("(0)")
        self.lbl_count.setStyleSheet("""
            QLabel {
                color: #F4F5F7;
                background-color: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-radius: 8px;
                padding: 1px 6px;
                font-size: 10px;
                font-weight: bold;
            }
        """)
        header.addWidget(self.lbl_count)

        header.addStretch()

        self.btn_clear = QPushButton("Clear")
        self.btn_clear.setToolTip("Clear all images from Media Bin")
        self.btn_clear.setFixedHeight(22)
        self.btn_clear.setStyleSheet("""
            QPushButton {
                background: transparent;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #94A3B8;
                font-size: 10px;
                border-radius: 4px;
                padding: 1px 7px;
            }
            QPushButton:hover {
                background: #1E1E26;
                color: #FFFFFF;
                border: 1px solid rgba(255, 255, 255, 0.16);
            }
        """)
        self.btn_clear.clicked.connect(self._on_clear_clicked)
        header.addWidget(self.btn_clear)
        layout.addLayout(header)

        # ========================================================
        # 2. ACTION BUTTONS: + Add Images, + Folder
        # ========================================================
        btn_box = QHBoxLayout()
        btn_box.setContentsMargins(2, 0, 2, 0)
        btn_box.setSpacing(4)

        self.btn_import_files = QPushButton("＋ Add Images...")
        self.btn_import_files.setToolTip("Import one or multiple image files (PNG, JPG, WEBP, BMP, TIFF)")
        self.btn_import_files.setFixedHeight(26)
        self.btn_import_files.setStyleSheet("""
            QPushButton {
                background-color: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #F4F5F7;
                font-weight: 600;
                font-size: 11px;
                border-radius: 5px;
                padding: 2px 8px;
            }
            QPushButton:hover {
                background-color: #1E1E26;
                border: 1px solid rgba(255, 255, 255, 0.16);
                color: #FFFFFF;
            }
        """)
        self.btn_import_files.clicked.connect(self.import_files_dialog)
        btn_box.addWidget(self.btn_import_files, 2)

        self.btn_import_folder = QPushButton("📁 Folder...")
        self.btn_import_folder.setToolTip("Import all images from a folder")
        self.btn_import_folder.setFixedHeight(26)
        self.btn_import_folder.setStyleSheet("""
            QPushButton {
                background-color: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.06);
                color: #CBD5E1;
                font-weight: 600;
                font-size: 11px;
                border-radius: 5px;
                padding: 2px 8px;
            }
            QPushButton:hover {
                background-color: #1E1E26;
                border: 1px solid rgba(255, 255, 255, 0.14);
                color: #FFFFFF;
            }
        """)
        self.btn_import_folder.clicked.connect(self.import_folder_dialog)
        btn_box.addWidget(self.btn_import_folder, 1)
        layout.addLayout(btn_box)

        # ========================================================
        # 3. VISUAL THUMBNAIL GRID (Clean Icon Mode - No Text Clutter)
        # ========================================================
        self.list_widget = QListWidget(self)
        self.list_widget.setViewMode(QListWidget.IconMode)
        self.list_widget.setResizeMode(QListWidget.Adjust)
        self.list_widget.setMovement(QListWidget.Static)
        self.list_widget.setIconSize(QSize(108, 68))
        self.list_widget.setGridSize(QSize(116, 76))
        self.list_widget.setSpacing(4)
        self.list_widget.setVerticalScrollMode(QAbstractItemView.ScrollPerPixel)
        self.list_widget.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.list_widget.setStyleSheet("""
            QListWidget {
                background-color: #0D0D11;
                border: 1px solid rgba(255, 255, 255, 0.06);
                border-radius: 8px;
                padding: 4px;
                outline: none;
            }
            QListWidget::item {
                background-color: #15151A;
                border: 2px solid rgba(255, 255, 255, 0.06);
                border-radius: 6px;
            }
            QListWidget::item:hover {
                background-color: #1E1E26;
                border: 2px solid rgba(255, 255, 255, 0.2);
            }
            QListWidget::item:selected {
                background-color: #1A1A22;
                border: 2px solid #C0000A;
            }
        """)
        self.list_widget.currentItemChanged.connect(self._on_current_item_changed)
        layout.addWidget(self.list_widget, 1)

        # Empty State Placeholder (centered when 0 items)
        self.empty_label = QLabel(
            "📂 Media Bin Empty\n\nClick '+ Add Images' or\ndrag & drop images here",
            self.list_widget
        )
        self.empty_label.setAlignment(Qt.AlignCenter)
        self.empty_label.setStyleSheet("""
            QLabel {
                color: #64748B;
                font-size: 11px;
                font-weight: 500;
                line-height: 1.5;
            }
        """)
        self.empty_label.setAttribute(Qt.WA_TransparentForMouseEvents, True)

        # ========================================================
        # 4. BOTTOM FOOTER: Batch Export Button
        # ========================================================
        self.btn_batch_export = QPushButton("📦 Export All Cropped...")
        self.btn_batch_export.setToolTip("Batch export all images in the Media Bin with current crop ratio")
        self.btn_batch_export.setFixedHeight(28)
        self.btn_batch_export.setStyleSheet("""
            QPushButton {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #059669, stop:1 #10B981);
                border: 1px solid rgba(16, 185, 129, 0.4);
                color: #FFFFFF;
                font-weight: bold;
                font-size: 11px;
                border-radius: 6px;
            }
            QPushButton:hover {
                background: #10B981;
                border: 1px solid rgba(16, 185, 129, 0.6);
            }
            QPushButton:pressed {
                background: #047857;
            }
            QPushButton:disabled {
                background: rgba(255, 255, 255, 0.02);
                border: 1px solid rgba(255, 255, 255, 0.04);
                color: #555566;
            }
        """)
        self.btn_batch_export.clicked.connect(self.batch_export_requested.emit)
        self.btn_batch_export.setEnabled(False)
        layout.addWidget(self.btn_batch_export)

        self._update_ui_state()

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.empty_label.setGeometry(self.list_widget.rect())

    def _update_ui_state(self):
        count = len(self.items)
        self.lbl_count.setText(f"({count})")
        self.empty_label.setVisible(count == 0)
        self.btn_clear.setEnabled(count > 0)
        self.btn_batch_export.setEnabled(count > 0)
        self.btn_batch_export.setText(f"📦 Export All ({count})")
        self.items_changed.emit(count)

    # --- Item Management ---
    def add_item(self, item: BinItem, select: bool = True):
        """Add a BinItem and render its visual thumbnail in the gallery."""
        self.items.append(item)
        self.items_by_id[item.item_id] = item

        list_item = QListWidgetItem(self.list_widget)
        list_item.setIcon(QIcon(item.thumb_pixmap))
        list_item.setText("")  # No filename text clutter! Clean visual thumbnail!
        
        # Tooltip shows detailed filename & resolution info on hover
        tooltip_str = f"{item.name}\n{item.width} × {item.height}"
        if item.file_size_str:
            tooltip_str += f" • {item.file_size_str}"
        list_item.setToolTip(tooltip_str)
        list_item.setData(Qt.UserRole, item.item_id)

        self.list_widget.addItem(list_item)
        self._update_ui_state()

        if select:
            self.select_item(item.item_id)

    def add_bgr_frame(self, bgr_array: np.ndarray, source_name: str = "frame", frame_idx: int = 0, select: bool = True) -> BinItem:
        """Add an in-memory frame directly from video engine."""
        h, w = bgr_array.shape[:2]
        thumb = make_thumbnail(bgr_array, 108, 68)
        item_name = f"{source_name}_f{frame_idx:06d}"
        
        item = BinItem(
            name=item_name,
            width=w,
            height=h,
            file_path=None,
            bgr_array=bgr_array,
            thumb_pixmap=thumb,
            file_size_str=f"{w}×{h}",
            frame_idx=frame_idx
        )
        self.add_item(item, select=select)
        return item

    def remove_item(self, item_id: str):
        """Remove item from bin."""
        if item_id not in self.items_by_id:
            return

        item = self.items_by_id.pop(item_id)
        if item in self.items:
            self.items.remove(item)

        # Remove from list widget
        for row in range(self.list_widget.count()):
            l_item = self.list_widget.item(row)
            if l_item.data(Qt.UserRole) == item_id:
                self.list_widget.takeItem(row)
                break

        self._update_ui_state()

        # If we removed the currently active item, select another or clear
        if self.current_selected_id == item_id:
            if self.items:
                self.select_item(self.items[0].item_id)
            else:
                self.current_selected_id = None
                self.item_selected.emit(None)

    def select_item(self, item_id: str):
        """Programmatically select item by ID."""
        for row in range(self.list_widget.count()):
            l_item = self.list_widget.item(row)
            if l_item.data(Qt.UserRole) == item_id:
                self.list_widget.setCurrentItem(l_item)
                break

    def get_current_item(self) -> Optional[BinItem]:
        if not self.current_selected_id:
            return None
        return self.items_by_id.get(self.current_selected_id)

    def get_all_items(self) -> List[BinItem]:
        return list(self.items)

    def get_count(self) -> int:
        return len(self.items)

    def _on_current_item_changed(self, current: Optional[QListWidgetItem], previous: Optional[QListWidgetItem]):
        if current is None:
            return
        item_id = current.data(Qt.UserRole)
        if item_id and item_id != self.current_selected_id:
            self.current_selected_id = item_id
            item = self.items_by_id.get(item_id)
            if item:
                self.item_selected.emit(item)

    def _on_clear_clicked(self):
        if not self.items:
            return
        res = QMessageBox.question(
            self,
            "Clear Media Bin",
            f"Are you sure you want to remove all {len(self.items)} image(s) from the Media Bin?",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No
        )
        if res == QMessageBox.Yes:
            self.clear_all()

    def clear_all(self):
        self.items.clear()
        self.items_by_id.clear()
        self.list_widget.clear()
        self.current_selected_id = None
        self._update_ui_state()
        self.item_selected.emit(None)

    # --- File & Folder Import ---
    def import_files_dialog(self):
        """Open multi-select file dialog to import multiple images."""
        filters = "Image Files (*.png *.jpg *.jpeg *.webp *.bmp *.tiff *.tif);;All Files (*.*)"
        files, _ = QFileDialog.getOpenFileNames(self, "Import Images into Media Bin", "", filters)
        if files:
            self.import_files(files)

    def import_folder_dialog(self):
        """Select a folder and import all supported images within it."""
        chosen = QFileDialog.getExistingDirectory(self, "Select Folder to Import Images")
        if not chosen or not os.path.isdir(chosen):
            return

        image_files = []
        for root, _, files in os.walk(chosen):
            for f in sorted(files):
                ext = Path(f).suffix.lower()
                if ext in IMAGE_EXTENSIONS:
                    image_files.append(os.path.join(root, f))

        if not image_files:
            QMessageBox.information(self, "No Images Found", f"No supported image files found in:\n{chosen}")
            return

        self.import_files(image_files)

    def import_files(self, file_paths: List[str]):
        """Import a list of file paths with fast thumbnail creation."""
        if not file_paths:
            return

        valid_paths = [p for p in file_paths if os.path.isfile(p) and Path(p).suffix.lower() in IMAGE_EXTENSIONS]
        if not valid_paths:
            return

        first_added = None
        for path_str in valid_paths:
            p = Path(path_str)
            # Avoid duplicate path in bin
            if any(it.file_path == str(p.resolve()) for it in self.items):
                continue

            try:
                # Fast metadata read
                file_size = os.path.getsize(path_str)
                size_str = format_file_size(file_size)

                # Decode image to get resolution & build thumbnail
                with open(path_str, "rb") as f:
                    bytes_data = bytearray(f.read())
                numpy_arr = np.asarray(bytes_data, dtype=np.uint8)
                bgr = cv2.imdecode(numpy_arr, cv2.IMREAD_COLOR)
                if bgr is None:
                    continue

                h, w = bgr.shape[:2]
                thumb = make_thumbnail(bgr, 108, 68)

                item = BinItem(
                    name=p.name,
                    width=w,
                    height=h,
                    file_path=str(p.resolve()),
                    bgr_array=None, # lazy-loaded from disk when selected to save RAM
                    thumb_pixmap=thumb,
                    file_size_str=size_str,
                    frame_idx=0
                )
                self.add_item(item, select=False)
                if first_added is None:
                    first_added = item
            except Exception:
                continue

        # If nothing was selected before, select the first newly added item
        if first_added and self.current_selected_id is None:
            self.select_item(first_added.item_id)

    # --- Right-Click Context Menu & Keyboard Delete ---
    def contextMenuEvent(self, event):
        item = self.list_widget.itemAt(self.list_widget.mapFrom(self, event.pos()))
        menu = QMenu(self)
        menu.setStyleSheet("""
            QMenu {
                background-color: #121826;
                border: 1px solid #1e293b;
                color: #e2e8f0;
                padding: 4px;
                border-radius: 6px;
                font-size: 11px;
            }
            QMenu::item {
                padding: 5px 18px 5px 10px;
                border-radius: 4px;
            }
            QMenu::item:selected {
                background-color: #1e293b;
                color: #38bdf8;
            }
        """)
        if item:
            item_id = item.data(Qt.UserRole)
            del_act = menu.addAction("🗑️ Remove from Bin")
            del_act.triggered.connect(lambda: self.remove_item(item_id))
            menu.addSeparator()

        add_act = menu.addAction("＋ Add Images...")
        add_act.triggered.connect(self.import_files_dialog)
        
        folder_act = menu.addAction("📁 Import Folder...")
        folder_act.triggered.connect(self.import_folder_dialog)

        if self.items:
            menu.addSeparator()
            clear_act = menu.addAction("🧹 Clear All")
            clear_act.triggered.connect(self._on_clear_clicked)

        menu.exec(event.globalPos())

    def keyPressEvent(self, event):
        if event.key() in (Qt.Key_Delete, Qt.Key_Backspace):
            cur = self.list_widget.currentItem()
            if cur:
                item_id = cur.data(Qt.UserRole)
                if item_id:
                    self.remove_item(item_id)
                    return
        super().keyPressEvent(event)

    # --- Drag & Drop ---
    def dragEnterEvent(self, event: QDragEnterEvent):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()

    def dragMoveEvent(self, event):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()

    def dropEvent(self, event: QDropEvent):
        paths = []
        for url in event.mimeData().urls():
            p = url.toLocalFile()
            if os.path.isfile(p):
                paths.append(p)
            elif os.path.isdir(p):
                for root, _, files in os.walk(p):
                    for f in sorted(files):
                        if Path(f).suffix.lower() in IMAGE_EXTENSIONS:
                            paths.append(os.path.join(root, f))
        if paths:
            self.import_files(paths)
            event.acceptProposedAction()
