import os
from pathlib import Path
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QLineEdit,
    QPushButton, QComboBox, QSlider, QCheckBox, QFileDialog,
    QGroupBox, QFormLayout, QFrame, QSizePolicy
)
from PySide6.QtCore import Qt, Signal
from ..config import ConfigManager
from ..utils import open_in_explorer, generate_output_filename

class ExportPanel(QWidget):
    """
    Compact export bar with a collapsible dropdown drawer for settings:
    - Compact 1-line action row (Export, Copy, Batch, Open Folder, Settings toggle)
    - Dropdown drawer containing Output Destination & Format/Naming configurations
    - Takes minimal vertical screen space when collapsed!
    """
    export_current_frame_requested = Signal()
    copy_clipboard_requested = Signal()
    batch_export_requested = Signal()
    output_dir_changed = Signal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.config = ConfigManager()
        self.current_video_path = ""
        self.current_frame_idx = 0
        self.fps = 30.0
        self.video_width = 0
        self.video_height = 0
        
        self._setup_ui()
        self._load_saved_settings()

    def _setup_ui(self):
        main_layout = QVBoxLayout(self)
        main_layout.setContentsMargins(6, 2, 6, 2)
        main_layout.setSpacing(4)

        # ========================================================
        # 1. ALWAYS-VISIBLE COMPACT ACTION ROW (Slim 1-line bar)
        # ========================================================
        action_bar = QHBoxLayout()
        action_bar.setContentsMargins(0, 0, 0, 0)
        action_bar.setSpacing(6)

        # Primary Export Button (Compact)
        self.btn_export = QPushButton("📸 Export Frame")
        self.btn_export.setObjectName("primaryBtn")
        self.btn_export.setToolTip("Export frame at 100% original pixel resolution (Shortcut: E or Ctrl+S)")
        self.btn_export.setFixedHeight(28)
        self.btn_export.clicked.connect(self.export_current_frame_requested.emit)
        action_bar.addWidget(self.btn_export)

        # Copy to Clipboard
        self.btn_clipboard = QPushButton("📋 Copy")
        self.btn_clipboard.setToolTip("Copy original resolution frame to Windows clipboard (Ctrl+C)")
        self.btn_clipboard.setFixedHeight(28)
        self.btn_clipboard.clicked.connect(self.copy_clipboard_requested.emit)
        action_bar.addWidget(self.btn_clipboard)

        # Batch Export
        self.btn_batch = QPushButton("⚡ Batch...")
        self.btn_batch.setToolTip("Export frame range or interval (Shortcut: B)")
        self.btn_batch.setFixedHeight(28)
        self.btn_batch.clicked.connect(self.batch_export_requested.emit)
        action_bar.addWidget(self.btn_batch)

        # Flexible spacer separating export actions from folder settings
        action_bar.addStretch()

        # Open Output Folder
        self.btn_open_folder = QPushButton("📁 Open Folder")
        self.btn_open_folder.setToolTip("Open destination directory in Windows Explorer")
        self.btn_open_folder.setFixedHeight(28)
        self.btn_open_folder.clicked.connect(self._on_open_folder)
        action_bar.addWidget(self.btn_open_folder)

        # Quick destination & format indicator label
        self.lbl_quick_info = QLabel("")
        self.lbl_quick_info.setStyleSheet("color: #64748b; font-size: 11px; padding: 0 4px;")
        action_bar.addWidget(self.lbl_quick_info)

        # Dropdown Toggle Button
        self.btn_toggle_settings = QPushButton("⚙️ Settings ▾")
        self.btn_toggle_settings.setToolTip("Click to toggle export destination and format settings")
        self.btn_toggle_settings.setCheckable(True)
        self.btn_toggle_settings.setFixedHeight(28)
        self.btn_toggle_settings.setStyleSheet("""
            QPushButton {
                background-color: #1e2230;
                border: 1px solid #333d54;
                border-radius: 4px;
                padding: 3px 10px;
                color: #cbd5e1;
                font-weight: 600;
                font-size: 11px;
            }
            QPushButton:hover {
                background-color: #293042;
                border-color: #6366f1;
                color: #ffffff;
            }
            QPushButton:checked {
                background-color: #2b2e4a;
                border-color: #818cf8;
                color: #a5b4fc;
            }
        """)
        self.btn_toggle_settings.clicked.connect(self._toggle_settings_panel)
        action_bar.addWidget(self.btn_toggle_settings)

        main_layout.addLayout(action_bar)

        # ========================================================
        # 2. COLLAPSIBLE DROPDOWN DRAWER (Hides to save space)
        # ========================================================
        self.settings_drawer = QFrame()
        self.settings_drawer.setStyleSheet("""
            QFrame#settingsDrawer {
                background-color: #161922;
                border: 1px solid #2a3042;
                border-radius: 8px;
                padding: 8px;
            }
        """)
        self.settings_drawer.setObjectName("settingsDrawer")
        
        drawer_layout = QVBoxLayout(self.settings_drawer)
        drawer_layout.setContentsMargins(10, 8, 10, 10)
        drawer_layout.setSpacing(10)

        # --- A. Destination Row ---
        folder_group = QGroupBox("📁 Output Destination")
        folder_layout = QVBoxLayout(folder_group)
        folder_layout.setContentsMargins(10, 10, 10, 8)
        folder_layout.setSpacing(6)

        path_row = QHBoxLayout()
        path_row.setSpacing(6)

        self.path_edit = QLineEdit()
        self.path_edit.setPlaceholderText("Select output folder...")
        self.path_edit.textChanged.connect(self._on_path_edited)
        path_row.addWidget(self.path_edit)

        self.btn_browse = QPushButton("Browse...")
        self.btn_browse.clicked.connect(self._on_browse_folder)
        path_row.addWidget(self.btn_browse)

        self.btn_set_default = QPushButton("★ Set as Default Folder")
        self.btn_set_default.setToolTip("Permanently save this folder as your default across restarts")
        self.btn_set_default.clicked.connect(self._on_set_as_default)
        path_row.addWidget(self.btn_set_default)

        self.chk_use_video_dir = QCheckBox("Save to video's folder")
        self.chk_use_video_dir.setToolTip("Automatically export frames into the source video's directory")
        self.chk_use_video_dir.toggled.connect(self._on_use_video_dir_toggled)
        path_row.addWidget(self.chk_use_video_dir)

        folder_layout.addLayout(path_row)
        drawer_layout.addWidget(folder_group)

        # --- B. Format & Naming Row ---
        fmt_group = QGroupBox("⚙️ Export Format & Naming")
        fmt_layout = QFormLayout(fmt_group)
        fmt_layout.setContentsMargins(10, 10, 10, 8)
        fmt_layout.setSpacing(8)

        # Format & Quality row
        format_row = QHBoxLayout()
        format_row.setSpacing(10)

        self.combo_format = QComboBox()
        self.combo_format.addItems(["PNG (Lossless)", "JPEG (High Quality)", "WEBP"])
        self.combo_format.currentIndexChanged.connect(self._on_format_changed)
        format_row.addWidget(self.combo_format)

        self.quality_label = QLabel("Quality: 95%")
        self.quality_slider = QSlider(Qt.Horizontal)
        self.quality_slider.setRange(50, 100)
        self.quality_slider.setValue(95)
        self.quality_slider.valueChanged.connect(self._on_quality_changed)
        self.quality_slider.hide()
        self.quality_label.hide()
        format_row.addWidget(self.quality_label)
        format_row.addWidget(self.quality_slider)

        fmt_layout.addRow("Format:", format_row)

        # Naming pattern
        name_row = QHBoxLayout()
        self.pattern_edit = QLineEdit("{video_name}_frame_{frame:06d}")
        self.pattern_edit.setToolTip("Placeholders: {video_name}, {frame}, {timecode}, {resolution}, {fps}")
        self.pattern_edit.textChanged.connect(self._update_preview)
        name_row.addWidget(self.pattern_edit)
        fmt_layout.addRow("Naming Pattern:", name_row)

        # Live Filename Preview
        self.preview_label = QLabel("Preview: -")
        self.preview_label.setStyleSheet("color: #38bdf8; font-family: monospace; font-size: 11px;")
        fmt_layout.addRow("Preview:", self.preview_label)

        drawer_layout.addWidget(fmt_group)

        main_layout.addWidget(self.settings_drawer)

        # Start collapsed by default!
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
        """Restore user preferences from config."""
        saved_dir = self.config.get("default_output_dir", "")
        use_video_dir = self.config.get("use_video_folder", False)
        self.chk_use_video_dir.setChecked(use_video_dir)
        
        if saved_dir and os.path.exists(saved_dir):
            self.path_edit.setText(saved_dir)
        else:
            # Default to user's Pictures/Frames folder
            pictures = Path(os.environ.get("USERPROFILE", ".")) / "Pictures" / "Frames"
            self.path_edit.setText(str(pictures))

        # Format
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

        # Expanded state from config
        is_expanded = self.config.get("settings_expanded", False)
        if is_expanded:
            self._toggle_settings_panel(True)

        self._update_quick_info()

    def set_video_context(self, video_path: str, width: int, height: int, fps: float):
        self.current_video_path = video_path
        self.video_width = width
        self.video_height = height
        self.fps = fps
        
        # If "Save to video folder" is checked, update destination
        if self.chk_use_video_dir.isChecked() and video_path:
            video_dir = str(Path(video_path).parent)
            self.path_edit.setText(video_dir)

        # Update export button text with actual original resolution
        if width > 0 and height > 0:
            self.btn_export.setText(f"📸 Export Frame ({width}×{height})")
        else:
            self.btn_export.setText("📸 Export Frame (Original Resolution)")

        self._update_preview()
        self._update_quick_info()

    def _get_export_btn_text(self) -> str:
        if self.video_width > 0 and self.video_height > 0:
            return f"📸 Export Frame ({self.video_width}×{self.video_height})"
        return "📸 Export Frame (Original Resolution)"

    def show_export_success(self):
        """Show clean '✓ Frame Saved' on the button without any overlapping popup."""
        orig_text = self._get_export_btn_text()
        self.btn_export.setText("✓ Frame Saved")
        self.btn_export.setStyleSheet("""
            QPushButton {
                background: #059669 !important;
                color: #ffffff !important;
                border: 1px solid #10b981 !important;
                font-weight: bold;
                font-size: 13px;
                border-radius: 6px;
            }
        """)
        from PySide6.QtCore import QTimer
        QTimer.singleShot(1400, lambda: self._reset_export_btn(orig_text))

    def _reset_export_btn(self, text: str):
        self.btn_export.setStyleSheet("")
        self.btn_export.setText(text)

    def show_copy_success(self):
        """Show clean '✓ Copied' on the copy button."""
        self.btn_clipboard.setText("✓ Copied")
        self.btn_clipboard.setStyleSheet("""
            QPushButton {
                background: #059669 !important;
                color: #ffffff !important;
                border: 1px solid #10b981 !important;
                font-weight: bold;
                font-size: 13px;
                border-radius: 6px;
            }
        """)
        from PySide6.QtCore import QTimer
        QTimer.singleShot(1400, lambda: self._reset_copy_btn())

    def _reset_copy_btn(self):
        self.btn_clipboard.setStyleSheet("")
        self.btn_clipboard.setText("📋 Copy")

    def update_frame_position(self, frame_idx: int):
        self.current_frame_idx = frame_idx
        self._update_preview()

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

    def _update_quick_info(self):
        """Update subtle one-line folder & format info in the collapsed top bar."""
        dest = self.get_output_directory()
        folder_name = Path(dest).name or dest
        ext = self.get_export_extension().upper()
        self.lbl_quick_info.setText(f"📁 {folder_name} ({ext})")
        self.lbl_quick_info.setToolTip(f"Export target: {dest}\nFormat: {ext}")

    def _on_browse_folder(self):
        start_dir = self.path_edit.text() or str(Path.home())
        chosen = QFileDialog.getExistingDirectory(self, "Select Output Folder for Exported Frames", start_dir)
        if chosen:
            self.path_edit.setText(chosen)
            self._update_quick_info()
            self.output_dir_changed.emit(chosen)

    def _on_set_as_default(self):
        current_dir = self.path_edit.text().strip()
        if current_dir:
            self.config.set("default_output_dir", current_dir)
            self.btn_set_default.setText("✓ Default Saved!")
            self.btn_set_default.setStyleSheet("color: #10b981; font-weight: bold;")
            from PySide6.QtCore import QTimer
            QTimer.singleShot(2000, lambda: self.btn_set_default.setText("★ Set as Default Folder"))
            QTimer.singleShot(2000, lambda: self.btn_set_default.setStyleSheet(""))
            self._update_quick_info()

    def _on_use_video_dir_toggled(self, checked: bool):
        self.config.set("use_video_folder", checked)
        if checked and self.current_video_path:
            self.path_edit.setText(str(Path(self.current_video_path).parent))
        elif not checked:
            default_dir = self.config.get("default_output_dir", "")
            if default_dir:
                self.path_edit.setText(default_dir)
        self._update_quick_info()

    def _on_path_edited(self, new_path: str):
        self._update_quick_info()
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
        self._update_quick_info()

    def _get_export_btn_text(self) -> str:
        if self.video_width > 0 and self.video_height > 0:
            return f"📸 Export Frame ({self.video_width}×{self.video_height})"
        return "📸 Export Frame (Original Resolution)"

    def show_export_success(self):
        """Show clean '✓ Frame Saved' on the button without any overlapping popup."""
        orig_text = self._get_export_btn_text()
        self.btn_export.setText("✓ Frame Saved")
        self.btn_export.setStyleSheet("""
            QPushButton {
                background: #059669 !important;
                color: #ffffff !important;
                border: 1px solid #10b981 !important;
                font-weight: bold;
                font-size: 13px;
                border-radius: 6px;
            }
        """)
        from PySide6.QtCore import QTimer
        QTimer.singleShot(1400, lambda: self._reset_export_btn(orig_text))

    def _reset_export_btn(self, text: str):
        self.btn_export.setStyleSheet("")
        self.btn_export.setText(text)

    def show_copy_success(self):
        """Show clean '✓ Copied' on the copy button."""
        self.btn_clipboard.setText("✓ Copied")
        self.btn_clipboard.setStyleSheet("""
            QPushButton {
                background: #059669 !important;
                color: #ffffff !important;
                border: 1px solid #10b981 !important;
                font-weight: bold;
                font-size: 13px;
                border-radius: 6px;
            }
        """)
        from PySide6.QtCore import QTimer
        QTimer.singleShot(1400, lambda: self._reset_copy_btn())

    def _reset_copy_btn(self):
        self.btn_clipboard.setStyleSheet("")
        self.btn_clipboard.setText("📋 Copy")

    def _on_quality_changed(self, val: int):
        self.quality_label.setText(f"Quality: {val}%")
        self.config.set("jpeg_quality", val)
