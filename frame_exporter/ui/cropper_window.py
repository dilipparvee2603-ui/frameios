import os
import cv2
import numpy as np
from pathlib import Path
from typing import Optional

from PySide6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QPushButton,
    QLabel, QFileDialog, QComboBox, QLineEdit, QButtonGroup,
    QMessageBox, QFrame, QSizePolicy, QSplitter,
    QProgressBar, QRadioButton, QApplication
)
from PySide6.QtGui import QGuiApplication, QImage, QKeySequence, QAction
from PySide6.QtCore import Qt, Signal, QTimer, QEvent

from .cropper_canvas import CropperCanvas
from .media_bin import MediaBinWidget, BinItem
from .frameless import CustomTitleBar, FramelessWindowMixin, DarkModalDialog
from ..config import ConfigManager
from ..utils import open_in_explorer, format_file_size, sanitize_filename


class ImageCropperWindow(FramelessWindowMixin, QMainWindow):
    """
    Studio Image Cropper with Visual Media Bin.
    - Pure visual Media Bin gallery (no text clutter, clean thumbnails)
    - Aspect ratio cropping presets (4:5, 16:9, 9:16, 1:1, Free)
    - One-click auto-detection & snapping past black bars
    - 4x pixel magnification loupe on crop handles
    - Keyboard 1-pixel nudging (Arrow keys directly on canvas)
    - 100% full original resolution export with zero downsampling
    - Batch export all cropped images from the Media Bin
    - Frameless hardware-accelerated studio UI
    """
    window_closed = Signal()
    return_to_launcher_requested = Signal(object)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.config = ConfigManager()
        
        self.resize(1180, 780)
        self.setMinimumSize(850, 560)

        self.current_source_name = "frame"
        self.current_frame_idx = 0
        self.current_bin_item: Optional[BinItem] = None
        self._force_close = False
        
        self._setup_ui()
        self._setup_shortcuts()
        self._load_config()
        self.setup_frameless(self.custom_title_bar)

    def _setup_ui(self):
        # 1. Master Root Frame
        root_frame = QFrame(self)
        root_frame.setObjectName("windowRootFrame")
        self.setCentralWidget(root_frame)

        root_layout = QVBoxLayout(root_frame)
        root_layout.setContentsMargins(0, 0, 0, 0)
        root_layout.setSpacing(0)

        # 2. Custom Frameless Title Bar
        self.custom_title_bar = CustomTitleBar(
            title="IMAGE CROPPER STUDIO",
            icon_text="✂️",
            show_menus=False,
            parent=self
        )
        self.custom_title_bar.set_status_pill("Original Quality Lossless Cropper", is_active=False)
        root_layout.addWidget(self.custom_title_bar)

        # 3. Main Workspace Container
        workspace = QWidget(self)
        main_layout = QVBoxLayout(workspace)
        main_layout.setContentsMargins(10, 8, 10, 8)
        main_layout.setSpacing(8)

        # ========================================================
        # 1. TOP TOOLBAR: Navigation, Media Bin Toggle, Ratios & Badges
        # ========================================================
        top_bar = QHBoxLayout()
        top_bar.setContentsMargins(0, 0, 0, 0)
        top_bar.setSpacing(6)

        # Navigation & Media Bin
        self.btn_back = QPushButton("← Back to Video")
        self.btn_back.setToolTip("Return to Frame Extractor window")
        self.btn_back.setFixedHeight(28)
        self.btn_back.setStyleSheet("""
            QPushButton {
                background-color: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #CBD5E1;
                font-weight: 600;
                font-size: 11px;
                border-radius: 6px;
                padding: 3px 12px;
            }
            QPushButton:hover {
                background-color: #1E1E26;
                border: 1px solid rgba(255, 255, 255, 0.16);
                color: #FFFFFF;
            }
        """)
        self.btn_back.clicked.connect(self.close)
        top_bar.addWidget(self.btn_back)

        # Return to Launcher Hub button (shown when opened from video, hidden when already from launcher)
        self.btn_launcher = QPushButton("✨ Launcher")
        self.btn_launcher.setToolTip("Return to Frame Studio Launcher Hub (Ctrl+H)")
        self.btn_launcher.setFixedHeight(28)
        self.btn_launcher.setStyleSheet("""
            QPushButton {
                background-color: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #CBD5E1;
                font-weight: 600;
                font-size: 11px;
                border-radius: 6px;
                padding: 3px 10px;
            }
            QPushButton:hover {
                background-color: #1E1E26;
                border: 1px solid rgba(255, 255, 255, 0.16);
                color: #FFFFFF;
            }
        """)
        self.btn_launcher.clicked.connect(lambda: self.return_to_launcher_requested.emit(self))
        top_bar.addWidget(self.btn_launcher)

        # Media Bin Toggle Button
        self.btn_toggle_bin = QPushButton("📁 Media Bin (0)")
        self.btn_toggle_bin.setCheckable(True)
        self.btn_toggle_bin.setChecked(True)
        self.btn_toggle_bin.setToolTip("Toggle Media Bin panel (Ctrl+B)")
        self.btn_toggle_bin.setFixedHeight(28)
        self.btn_toggle_bin.setStyleSheet("""
            QPushButton {
                background-color: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #CBD5E1;
                font-weight: 600;
                font-size: 11px;
                border-radius: 6px;
                padding: 3px 10px;
            }
            QPushButton:hover {
                background-color: #1E1E26;
                border: 1px solid rgba(255, 255, 255, 0.16);
                color: #FFFFFF;
            }
            QPushButton:checked {
                background-color: #1A1A22;
                border: 1px solid #C0000A;
                color: #F4F5F7;
            }
        """)
        self.btn_toggle_bin.clicked.connect(self._toggle_bin_panel)
        top_bar.addWidget(self.btn_toggle_bin)

        # Stretch spacer between left & center
        top_bar.addStretch(1)

        # Center Container (Ratio selection + Snap past black bars)
        lbl_ratio = QLabel("Ratio:")
        lbl_ratio.setStyleSheet("color: #94A3B8; font-weight: 600; font-size: 12px;")
        top_bar.addWidget(lbl_ratio)

        self.ratio_group = QButtonGroup(self)
        self.ratio_group.setExclusive(True)

        self.ratios = [
            ("4:5", 4.0 / 5.0, "Instagram Portrait (4:5)"),
            ("16:9", 16.0 / 9.0, "YouTube / Widescreen (16:9)"),
            ("9:16", 9.0 / 16.0, "Reels / TikTok / Stories (9:16)"),
            ("1:1", 1.0, "Square Feed (1:1)"),
            ("Free", None, "Unconstrained freeform crop"),
        ]

        for i, (label, val, tooltip) in enumerate(self.ratios):
            btn = QPushButton(label)
            btn.setCheckable(True)
            btn.setFocusPolicy(Qt.NoFocus)
            btn.setToolTip(tooltip)
            btn.setFixedHeight(28)
            btn.setStyleSheet("""
                QPushButton {
                    background-color: #15151A;
                    border: 1px solid rgba(255, 255, 255, 0.06);
                    border-radius: 6px;
                    padding: 3px 10px;
                    color: #CBD5E1;
                    font-size: 11px;
                    font-weight: 600;
                }
                QPushButton:hover {
                    background-color: #1E1E26;
                    border: 1px solid rgba(255, 255, 255, 0.14);
                    color: #FFFFFF;
                }
                QPushButton:checked {
                    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #FF4A3D, stop:1 #D92A20);
                    border: 1px solid rgba(255, 74, 61, 0.5);
                    color: #FFFFFF;
                    font-weight: 700;
                }
            """)
            if i == 0:
                btn.setChecked(True)
            btn.clicked.connect(lambda checked, r=val: self._on_ratio_selected(r))
            self.ratio_group.addButton(btn, i)
            top_bar.addWidget(btn)

        top_bar.addSpacing(2)

        # Auto-Detect Black Bars Button
        self.btn_auto_bars = QPushButton("Snap Black Bars")
        self.btn_auto_bars.setFocusPolicy(Qt.NoFocus)
        self.btn_auto_bars.setToolTip("Auto-detect video letterbox/pillarbox borders and snap crop inside active content")
        self.btn_auto_bars.setFixedHeight(28)
        self.btn_auto_bars.setStyleSheet("""
            QPushButton {
                background: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #38BDF8;
                font-weight: 700;
                font-size: 11px;
                border-radius: 6px;
                padding: 3px 10px;
            }
            QPushButton:hover {
                background: #1E1E26;
                border: 1px solid rgba(56, 189, 248, 0.45);
                color: #FFFFFF;
            }
        """)
        self.btn_auto_bars.clicked.connect(self._on_auto_detect_bars)
        top_bar.addWidget(self.btn_auto_bars)

        # Stretch spacer between center & right
        top_bar.addStretch(1)

        # Right: Resolution indicator badge
        self.badge_res = QLabel("Crop: 0 × 0 px")
        self.badge_res.setFixedHeight(28)
        self.badge_res.setStyleSheet("""
            QLabel {
                color: #F4F5F7;
                background-color: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-radius: 6px;
                padding: 2px 8px;
                font-family: 'Consolas', monospace;
                font-size: 11px;
                font-weight: bold;
            }
        """)
        top_bar.addWidget(self.badge_res)

        # Fit / Reset View button
        btn_fit = QPushButton("Fit (0)")
        btn_fit.setFocusPolicy(Qt.NoFocus)
        btn_fit.setToolTip("Reset canvas zoom to fit window")
        btn_fit.setFixedHeight(28)
        btn_fit.clicked.connect(self._on_fit_view)
        top_bar.addWidget(btn_fit)

        # Multi-Image Import Button
        self.btn_add_images = QPushButton("＋ Add Images...")
        self.btn_add_images.setFocusPolicy(Qt.NoFocus)
        self.btn_add_images.setToolTip("Import one or multiple images into the Media Bin (Ctrl+O)")
        self.btn_add_images.setFixedHeight(28)
        self.btn_add_images.setStyleSheet("""
            QPushButton {
                background-color: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                color: #F4F5F7;
                font-weight: 700;
                font-size: 11px;
                border-radius: 6px;
                padding: 3px 12px;
            }
            QPushButton:hover {
                background-color: #1E1E26;
                border: 1px solid rgba(255, 255, 255, 0.18);
                color: #FFFFFF;
            }
        """)
        self.btn_add_images.clicked.connect(lambda: self.bin_panel.import_files_dialog())
        top_bar.addWidget(self.btn_add_images)

        main_layout.addLayout(top_bar)

        # ========================================================
        # 2. CENTER: Media Bin (Left) + Interactive Cropper Canvas (Right)
        # ========================================================
        self.splitter = QSplitter(Qt.Horizontal, self)
        self.splitter.setHandleWidth(3)
        self.splitter.setStyleSheet("""
            QSplitter::handle {
                background-color: rgba(255, 255, 255, 0.06);
            }
            QSplitter::handle:hover {
                background-color: #C0000A;
            }
        """)

        # Media Bin Sidebar Panel (Pure visual thumbnail gallery)
        self.bin_panel = MediaBinWidget(self)
        self.bin_panel.setMinimumWidth(180)
        self.bin_panel.setMaximumWidth(460)
        self.bin_panel.item_selected.connect(self._on_bin_item_selected)
        self.bin_panel.items_changed.connect(self._on_bin_items_changed)
        self.bin_panel.batch_export_requested.connect(self._on_batch_export_bin)
        self.splitter.addWidget(self.bin_panel)

        # Interactive Cropping Canvas
        self.canvas = CropperCanvas(self)
        self.canvas.crop_changed.connect(self._on_crop_changed)
        self.canvas.files_dropped.connect(self.bin_panel.import_files)
        self.splitter.addWidget(self.canvas)

        self.splitter.setStretchFactor(0, 0)
        self.splitter.setStretchFactor(1, 1)
        self.splitter.setSizes([260, 920])
        main_layout.addWidget(self.splitter, 1)

        # ========================================================
        # 3. BOTTOM BAR: Destination, Format & Export Actions
        # ========================================================
        bottom_bar = QHBoxLayout()
        bottom_bar.setSpacing(6)

        lbl_dest = QLabel("Save to:")
        lbl_dest.setStyleSheet("color: #94a3b8; font-size: 11px;")
        bottom_bar.addWidget(lbl_dest)

        self.path_edit = QLineEdit()
        self.path_edit.setFixedHeight(28)
        bottom_bar.addWidget(self.path_edit, 3)

        btn_browse = QPushButton("Browse...")
        btn_browse.setFocusPolicy(Qt.NoFocus)
        btn_browse.setFixedHeight(28)
        btn_browse.clicked.connect(self._on_browse_folder)
        bottom_bar.addWidget(btn_browse)

        # Format selector
        self.combo_format = QComboBox()
        self.combo_format.setFocusPolicy(Qt.NoFocus)
        self.combo_format.addItems(["PNG (Lossless)", "JPEG (95%)", "WEBP"])
        self.combo_format.setFixedHeight(28)
        bottom_bar.addWidget(self.combo_format)

        bottom_bar.addSpacing(6)

        # Save Cropped Image Button
        self.btn_save = QPushButton("📸 Save Cropped Image")
        self.btn_save.setFocusPolicy(Qt.NoFocus)
        self.btn_save.setObjectName("primaryBtn")
        self.btn_save.setToolTip("Save cropped image at full original pixel resolution (Ctrl+S / Enter)")
        self.btn_save.setFixedHeight(28)
        self.btn_save.clicked.connect(self.save_cropped_image)
        bottom_bar.addWidget(self.btn_save)

        # Copy to Clipboard
        self.btn_copy = QPushButton("📋 Copy Cropped")
        self.btn_copy.setFocusPolicy(Qt.NoFocus)
        self.btn_copy.setToolTip("Copy cropped region at original resolution to clipboard (Ctrl+C)")
        self.btn_copy.setFixedHeight(28)
        self.btn_copy.clicked.connect(self.copy_cropped_image)
        bottom_bar.addWidget(self.btn_copy)

        # Open Output Folder
        btn_folder = QPushButton("📁 Folder")
        btn_folder.setFocusPolicy(Qt.NoFocus)
        btn_folder.setToolTip("Open save folder in Windows Explorer")
        btn_folder.setFixedHeight(28)
        btn_folder.clicked.connect(self._on_open_folder)
        bottom_bar.addWidget(btn_folder)

        main_layout.addLayout(bottom_bar)
        root_layout.addWidget(workspace, 1)

    def _setup_shortcuts(self):
        act_save = QAction(self)
        act_save.setShortcut("Ctrl+S")
        act_save.triggered.connect(self.save_cropped_image)
        self.addAction(act_save)

        act_copy = QAction(self)
        act_copy.setShortcut(QKeySequence.Copy)
        act_copy.triggered.connect(self.copy_cropped_image)
        self.addAction(act_copy)

        act_open = QAction(self)
        act_open.setShortcut(QKeySequence.Open) # Ctrl+O
        act_open.triggered.connect(lambda: self.bin_panel.import_files_dialog())
        self.addAction(act_open)

        act_bin = QAction(self)
        act_bin.setShortcut("Ctrl+B")
        act_bin.triggered.connect(self._toggle_bin_panel)
        self.addAction(act_bin)

        act_fit = QAction(self)
        act_fit.setShortcut("0")
        act_fit.triggered.connect(self._on_fit_view)
        self.addAction(act_fit)

        act_close = QAction(self)
        act_close.setShortcut("Esc")
        act_close.triggered.connect(self.close)
        self.addAction(act_close)

        # 1-Pixel Precision Keyboard Nudging & Resizing Shortcuts
        act_left = QAction(self)
        act_left.setShortcut(Qt.Key_Left)
        act_left.triggered.connect(lambda: self.canvas.nudge_crop(-1, 0))
        self.addAction(act_left)

        act_right = QAction(self)
        act_right.setShortcut(Qt.Key_Right)
        act_right.triggered.connect(lambda: self.canvas.nudge_crop(1, 0))
        self.addAction(act_right)

        act_up = QAction(self)
        act_up.setShortcut(Qt.Key_Up)
        act_up.triggered.connect(lambda: self.canvas.nudge_crop(0, -1))
        self.addAction(act_up)

        act_down = QAction(self)
        act_down.setShortcut(Qt.Key_Down)
        act_down.triggered.connect(lambda: self.canvas.nudge_crop(0, 1))
        self.addAction(act_down)

        # 10-Pixel Stepping with Shift
        act_s_left = QAction(self)
        act_s_left.setShortcut("Shift+Left")
        act_s_left.triggered.connect(lambda: self.canvas.nudge_crop(-10, 0))
        self.addAction(act_s_left)

        act_s_right = QAction(self)
        act_s_right.setShortcut("Shift+Right")
        act_s_right.triggered.connect(lambda: self.canvas.nudge_crop(10, 0))
        self.addAction(act_s_right)

        act_s_up = QAction(self)
        act_s_up.setShortcut("Shift+Up")
        act_s_up.triggered.connect(lambda: self.canvas.nudge_crop(0, -10))
        self.addAction(act_s_up)

        act_s_down = QAction(self)
        act_s_down.setShortcut("Shift+Down")
        act_s_down.triggered.connect(lambda: self.canvas.nudge_crop(0, 10))
        self.addAction(act_s_down)

        # Sizing with Ctrl
        act_c_left = QAction(self)
        act_c_left.setShortcut("Ctrl+Left")
        act_c_left.triggered.connect(lambda: self.canvas.resize_crop_delta(-1))
        self.addAction(act_c_left)

        act_c_right = QAction(self)
        act_c_right.setShortcut("Ctrl+Right")
        act_c_right.triggered.connect(lambda: self.canvas.resize_crop_delta(1))
        self.addAction(act_c_right)

        act_c_up = QAction(self)
        act_c_up.setShortcut("Ctrl+Up")
        act_c_up.triggered.connect(lambda: self.canvas.resize_crop_delta(-1))
        self.addAction(act_c_up)

        act_c_down = QAction(self)
        act_c_down.setShortcut("Ctrl+Down")
        act_c_down.triggered.connect(lambda: self.canvas.resize_crop_delta(1))
        self.addAction(act_c_down)

        from PySide6.QtCore import QCoreApplication
        app = QCoreApplication.instance()
        if app:
            app.installEventFilter(self)

    def eventFilter(self, watched, event):
        """Global key event filter to guarantee 1-pixel nudging anywhere in the window."""
        if event.type() == QEvent.KeyPress:
            if not self.isVisible() or not (self.isActiveWindow() or QApplication.activeWindow() == self or self.isAncestorOf(QApplication.focusWidget())):
                return super().eventFilter(watched, event)

            focused = QApplication.focusWidget()
            from PySide6.QtWidgets import QLineEdit, QSpinBox
            if isinstance(focused, (QLineEdit, QSpinBox)):
                return super().eventFilter(watched, event)

            key = event.key()
            modifiers = event.modifiers()
            step = 10 if (modifiers & Qt.ShiftModifier) else 1

            if key in (Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down):
                if modifiers & Qt.ControlModifier:
                    if key in (Qt.Key_Right, Qt.Key_Down):
                        self.canvas.resize_crop_delta(step)
                        return True
                    elif key in (Qt.Key_Left, Qt.Key_Up):
                        self.canvas.resize_crop_delta(-step)
                        return True
                else:
                    if key == Qt.Key_Left:
                        self.canvas.nudge_crop(-step, 0)
                        return True
                    elif key == Qt.Key_Right:
                        self.canvas.nudge_crop(step, 0)
                        return True
                    elif key == Qt.Key_Up:
                        self.canvas.nudge_crop(0, -step)
                        return True
                    elif key == Qt.Key_Down:
                        self.canvas.nudge_crop(0, step)
                        return True

        return super().eventFilter(watched, event)

    def _load_config(self):
        default_dir = self.config.get("default_output_dir", "")
        if default_dir and os.path.exists(default_dir):
            self.path_edit.setText(default_dir)
        else:
            pics = str(Path.home() / "Pictures" / "Frames")
            self.path_edit.setText(pics)

    def _toggle_bin_panel(self, checked: bool = None):
        if checked is None:
            checked = not self.bin_panel.isVisible()
        self.bin_panel.setVisible(checked)
        self.btn_toggle_bin.setChecked(checked)

    def _on_bin_items_changed(self, count: int):
        self.btn_toggle_bin.setText(f"🗂️ Media Bin ({count})")

    # --- Public API to Load Video Frame or Image ---
    def load_frame(self, bgr_array: np.ndarray, source_name: str = "frame", frame_idx: int = 0):
        """Load native BGR array directly from video engine into the Media Bin."""
        self.bin_panel.add_bgr_frame(bgr_array, source_name=source_name, frame_idx=frame_idx, select=True)

    def load_image_file(self, file_path: str):
        if not file_path or not os.path.exists(file_path):
            return
        self.bin_panel.import_files([file_path])

    # --- Item Selected from Media Bin ---
    def _on_bin_item_selected(self, item: Optional[BinItem]):
        # Save previous item's current crop coordinates if active
        if self.current_bin_item is not None and self.canvas.raw_bgr_frame is not None:
            x = int(round(self.canvas.crop_native.x()))
            y = int(round(self.canvas.crop_native.y()))
            w = int(round(self.canvas.crop_native.width()))
            h = int(round(self.canvas.crop_native.height()))
            self.current_bin_item.saved_crop_rect = (x, y, w, h)
            self.current_bin_item.saved_aspect_ratio = self.canvas.aspect_ratio

        self.current_bin_item = item

        if item is None:
            self.canvas.set_image(None)
            self.badge_res.setText("Crop: 0 × 0 px")
            self.custom_title_bar.set_status_pill("No Image Selected", is_active=False)
            return

        bgr = item.get_bgr()
        if bgr is None:
            QMessageBox.critical(self, "Load Error", f"Could not load image: {item.name}")
            return

        self.current_source_name = sanitize_filename(Path(item.name).stem)
        self.current_frame_idx = item.frame_idx

        h, w = bgr.shape[:2]
        self.custom_title_bar.set_status_pill(f"✂️ {item.name}  •  {w}×{h} Original", is_active=True)

        self.canvas.set_image(bgr)

        # Restore saved crop rectangle if previously customized
        if item.saved_crop_rect is not None:
            x, y, cw, ch = item.saved_crop_rect
            self.canvas.set_native_rect(x, y, cw, ch)
        self.canvas.reset_view()
        self.canvas.setFocus()

    # --- UI Callbacks & Precise Synchronization ---
    def _on_ratio_selected(self, ratio: Optional[float]):
        self.canvas.set_aspect_ratio(ratio)

    def _on_auto_detect_bars(self):
        ok, has_bars = self.canvas.auto_detect_black_bars()
        if ok:
            orig_text = "🪄 Snap Past Black Bars"
            if has_bars:
                self.btn_auto_bars.setText("✓ Snapped Past Black Bars!")
            else:
                self.btn_auto_bars.setText("✓ Full Content (No Bars)")
            self.btn_auto_bars.setStyleSheet("""
                QPushButton {
                    background: #059669 !important;
                    color: #ffffff !important;
                    border: none !important;
                    font-weight: bold;
                    font-size: 11px;
                    border-radius: 4px;
                    padding: 3px 10px;
                }
            """)
            QTimer.singleShot(1800, lambda: self._reset_auto_bars_btn(orig_text))
        else:
            QMessageBox.information(self, "Auto-Detect", "Could not determine content boundaries (image may be pure black).")

    def _reset_auto_bars_btn(self, orig_text):
        self.btn_auto_bars.setStyleSheet("""
            QPushButton {
                background: #121c2b;
                border: 1px solid rgba(6, 182, 212, 0.22);
                color: #38bdf8;
                font-weight: bold;
                font-size: 11px;
                border-radius: 4px;
                padding: 3px 10px;
            }
            QPushButton:hover {
                background: #18283d;
                border: 1px solid rgba(6, 182, 212, 0.38);
                color: #ffffff;
            }
        """)
        self.btn_auto_bars.setText(orig_text)

    def _on_crop_changed(self, x: int, y: int, w: int, h: int):
        ratio_str = ""
        if self.canvas.aspect_ratio:
            for label, val, _ in self.ratios:
                if val and abs(val - self.canvas.aspect_ratio) < 0.01:
                    ratio_str = f" ({label.split()[0]})"
                    break
        self.badge_res.setText(f"Crop: {w} × {h} px{ratio_str}")

    def _on_fit_view(self):
        self.canvas.reset_view()

    def _on_browse_folder(self):
        start = self.path_edit.text() or str(Path.home())
        chosen = QFileDialog.getExistingDirectory(self, "Select Save Folder", start)
        if chosen:
            self.path_edit.setText(chosen)

    def _on_open_folder(self):
        dest = self.path_edit.text().strip()
        if dest:
            Path(dest).mkdir(parents=True, exist_ok=True)
            open_in_explorer(dest)

    # --- Export Single Active Image at Original Quality ---
    def save_cropped_image(self):
        cropped_bgr = self.canvas.get_cropped_bgr()
        if cropped_bgr is None:
            QMessageBox.warning(self, "No Image", "No image loaded to crop.")
            return

        dest_dir = self.path_edit.text().strip()
        if not dest_dir:
            dest_dir = str(Path.home() / "Pictures" / "Frames")
        Path(dest_dir).mkdir(parents=True, exist_ok=True)

        h, w = cropped_bgr.shape[:2]
        
        tag = "free"
        if self.canvas.aspect_ratio:
            for label, val, _ in self.ratios:
                if val and abs(val - self.canvas.aspect_ratio) < 0.01:
                    tag = label.split()[0].replace(":", "x")
                    break

        idx_fmt = self.combo_format.currentIndex()
        if idx_fmt == 1:
            ext = "jpg"
            params = [cv2.IMWRITE_JPEG_QUALITY, 95]
        elif idx_fmt == 2:
            ext = "webp"
            params = [cv2.IMWRITE_WEBP_QUALITY, 95]
        else:
            ext = "png"
            params = [cv2.IMWRITE_PNG_COMPRESSION, 3]

        filename = f"{self.current_source_name}_cropped_{tag}_{w}x{h}.{ext}"
        out_path = Path(dest_dir) / filename

        try:
            ok, buf = cv2.imencode(f".{ext}", cropped_bgr, params)
            if ok:
                with open(out_path, "wb") as f:
                    f.write(buf.tobytes())
                
                self.btn_save.setText(f"✓ Saved ({w}×{h})")
                self.btn_save.setStyleSheet("""
                    QPushButton {
                        background: #10B981 !important;
                        color: #ffffff !important;
                        border: 1px solid rgba(16, 185, 129, 0.6) !important;
                        font-weight: bold;
                        border-radius: 6px;
                    }
                """)
                QTimer.singleShot(1500, lambda: self._reset_save_btn())
            else:
                QMessageBox.critical(self, "Export Error", "Failed to encode cropped image.")
        except Exception as e:
            QMessageBox.critical(self, "Export Error", f"Failed to save image:\n{e}")

    def _reset_save_btn(self):
        self.btn_save.setStyleSheet("")
        self.btn_save.setText("📸 Save Cropped Image")

    def copy_cropped_image(self):
        cropped_bgr = self.canvas.get_cropped_bgr()
        if cropped_bgr is None:
            return

        h, w, ch = cropped_bgr.shape
        qimg = QImage(cropped_bgr.data, w, h, ch * w, QImage.Format.Format_BGR888).copy()
        QGuiApplication.clipboard().setImage(qimg)

        self.btn_copy.setText("✓ Copied")
        self.btn_copy.setStyleSheet("""
            QPushButton {
                background: #059669 !important;
                color: #ffffff !important;
                border: none !important;
                font-weight: bold;
                border-radius: 4px;
            }
        """)
        QTimer.singleShot(1400, lambda: self._reset_copy_btn())

    def _reset_copy_btn(self):
        self.btn_copy.setStyleSheet("")
        self.btn_copy.setText("📋 Copy Cropped")

    # --- Batch Export Media Bin ---
    def _on_batch_export_bin(self):
        items = self.bin_panel.get_all_items()
        if not items:
            QMessageBox.information(self, "Media Bin", "No images in Media Bin to export.")
            return

        dlg = DarkModalDialog(title=f"Batch Export Media Bin ({len(items)} images)", parent=self)
        dlg.resize(500, 290)
        layout = dlg.content_layout

        lbl_desc = QLabel(f"Export all <b>{len(items)}</b> images in the Media Bin cropped at 100% original pixel quality.", dlg.content_widget)
        lbl_desc.setStyleSheet("color: #cbd5e1; font-size: 12px; margin-bottom: 6px;")
        layout.addWidget(lbl_desc)

        # Folder row
        row_folder = QHBoxLayout()
        lbl_f = QLabel("Output Folder:", dlg.content_widget)
        lbl_f.setStyleSheet("color: #94a3b8; font-size: 11px; min-width: 85px;")
        row_folder.addWidget(lbl_f)
        txt_out = QLineEdit(self.path_edit.text(), dlg.content_widget)
        txt_out.setFixedHeight(28)
        row_folder.addWidget(txt_out)
        btn_browse = QPushButton("Browse...", dlg.content_widget)
        btn_browse.setFixedHeight(28)
        def _browse():
            chosen = QFileDialog.getExistingDirectory(dlg, "Select Export Directory", txt_out.text())
            if chosen:
                txt_out.setText(chosen)
        btn_browse.clicked.connect(_browse)
        row_folder.addWidget(btn_browse)
        layout.addLayout(row_folder)

        # Format row
        row_fmt = QHBoxLayout()
        lbl_fmt = QLabel("Format:", dlg.content_widget)
        lbl_fmt.setStyleSheet("color: #94a3b8; font-size: 11px; min-width: 85px;")
        row_fmt.addWidget(lbl_fmt)
        combo_f = QComboBox(dlg.content_widget)
        combo_f.addItems(["PNG (Lossless)", "JPEG (95%)", "WEBP"])
        combo_f.setCurrentIndex(self.combo_format.currentIndex())
        combo_f.setFixedHeight(28)
        row_fmt.addWidget(combo_f)
        row_fmt.addStretch()
        layout.addLayout(row_fmt)

        # Progress bar
        pbar = QProgressBar(dlg.content_widget)
        pbar.setFixedHeight(18)
        pbar.setRange(0, len(items))
        pbar.setValue(0)
        pbar.setTextVisible(True)
        pbar.setStyleSheet("""
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
        pbar.hide()
        layout.addWidget(pbar)

        lbl_status = QLabel("", dlg.content_widget)
        lbl_status.setStyleSheet("color: #38bdf8; font-size: 11px; font-weight: 500;")
        lbl_status.hide()
        layout.addWidget(lbl_status)

        layout.addSpacing(8)

        # Action buttons
        btn_box = QHBoxLayout()
        btn_box.addStretch()
        btn_cancel = QPushButton("Cancel", dlg.content_widget)
        btn_cancel.setFixedHeight(30)
        btn_cancel.clicked.connect(dlg.close)
        btn_box.addWidget(btn_cancel)

        btn_run = QPushButton(f"Start Batch Export ({len(items)})", dlg.content_widget)
        btn_run.setObjectName("primaryBtn")
        btn_run.setFixedHeight(30)
        btn_box.addWidget(btn_run)
        layout.addLayout(btn_box)

        def _execute_export():
            out_dir = txt_out.text().strip()
            if not out_dir:
                return
            Path(out_dir).mkdir(parents=True, exist_ok=True)

            btn_run.setEnabled(False)
            btn_cancel.setEnabled(False)
            pbar.show()
            lbl_status.show()

            fmt_idx = combo_f.currentIndex()
            if fmt_idx == 1:
                ext = "jpg"
                params = [cv2.IMWRITE_JPEG_QUALITY, 95]
            elif fmt_idx == 2:
                ext = "webp"
                params = [cv2.IMWRITE_WEBP_QUALITY, 95]
            else:
                ext = "png"
                params = [cv2.IMWRITE_PNG_COMPRESSION, 3]

            current_aspect = self.canvas.aspect_ratio

            exported_count = 0
            for i, it in enumerate(items):
                lbl_status.setText(f"Exporting {i+1}/{len(items)}: {it.name}...")
                pbar.setValue(i)
                QGuiApplication.processEvents()

                raw_bgr = it.get_bgr()
                if raw_bgr is None:
                    continue

                h, w = raw_bgr.shape[:2]
                if it.saved_crop_rect:
                    cx, cy, cw, ch = it.saved_crop_rect
                else:
                    # Center-crop based on current aspect ratio
                    if current_aspect:
                        img_ratio = w / float(h)
                        if img_ratio > current_aspect:
                            ch = h
                            cw = int(round(h * current_aspect))
                            cy = 0
                            cx = (w - cw) // 2
                        else:
                            cw = w
                            ch = int(round(w / current_aspect))
                            cx = 0
                            cy = (h - ch) // 2
                    else:
                        cx, cy, cw, ch = 0, 0, w, h

                cx = max(0, min(w - 1, int(round(cx))))
                cy = max(0, min(h - 1, int(round(cy))))
                cw = max(1, min(w - cx, int(round(cw))))
                ch = max(1, min(h - cy, int(round(ch))))

                cropped = raw_bgr[cy : cy + ch, cx : cx + cw]
                stem = sanitize_filename(Path(it.name).stem)
                out_path = Path(out_dir) / f"{stem}_cropped_{cw}x{ch}.{ext}"

                ok, buf = cv2.imencode(f".{ext}", cropped, params)
                if ok:
                    with open(out_path, "wb") as f_out:
                        f_out.write(buf.tobytes())
                    exported_count += 1

            pbar.setValue(len(items))
            lbl_status.setText(f"✓ Successfully exported {exported_count} images to {Path(out_dir).name}!")
            btn_run.setText("Done")
            btn_run.setEnabled(True)
            btn_run.clicked.disconnect()
            btn_run.clicked.connect(dlg.close)

            btn_cancel.setText("Open Folder")
            btn_cancel.setEnabled(True)
            btn_cancel.clicked.disconnect()
            btn_cancel.clicked.connect(lambda: open_in_explorer(out_dir))

        btn_run.clicked.connect(_execute_export)
        dlg.exec()

    def force_close(self):
        """Allow closing without triggering return-to-main animation on app quit."""
        from PySide6.QtCore import QCoreApplication
        app = QCoreApplication.instance()
        if app is not None:
            try:
                app.removeEventFilter(self)
            except Exception:
                pass
        self._force_close = True
        self.close()

    def closeEvent(self, event):
        from PySide6.QtCore import QCoreApplication
        app = QCoreApplication.instance()
        if app is not None:
            try:
                app.removeEventFilter(self)
            except Exception:
                pass
        if self._force_close:
            super().closeEvent(event)
            return
        if getattr(self, "return_to_launcher_on_close", False):
            self.return_to_launcher_requested.emit(self)
            event.ignore()
            return
        self.window_closed.emit()
        event.ignore()
