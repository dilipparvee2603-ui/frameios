import os
import time
from pathlib import Path
from typing import Optional, List, Tuple

import cv2
import numpy as np

from PySide6.QtWidgets import (
    QDialog, QWidget, QVBoxLayout, QHBoxLayout, QPushButton,
    QLabel, QComboBox, QCheckBox, QSpinBox, QSlider,
    QProgressBar, QScrollArea, QFileDialog, QMessageBox,
    QFrame, QSizePolicy, QGroupBox, QRadioButton, QButtonGroup
)
from PySide6.QtGui import QPixmap, QImage, QColor, QFont, QPainter, QCursor, QGuiApplication
from PySide6.QtCore import Qt, Signal, QSize, QTimer, QThread

from .frameless import CustomTitleBar, FramelessWindowMixin, DarkModalDialog
from .media_bin import BinItem
from ..scene_detector import SceneDetectWorker
from ..utils import frames_to_timecode, format_file_size, open_in_explorer


class StoryboardDialog(DarkModalDialog):
    """
    Studio Storyboard Contact Sheet Generator & Auto Scene Cut Manager.
    - 1-click Auto Scene Cut Detection (amber pins on timeline)
    - Clean contact sheet grid layouts (3x3, 4x4, 5x5, custom columns)
    - Timecode burn-in, shot numbering, and header info banner
    - Export contact sheet (PNG/JPG), Copy to Clipboard
    - 1-click 'Send All Shots to Cropper Media Bin'
    """
    scene_cuts_updated = Signal(list)
    jump_to_frame_requested = Signal(int)
    send_shots_to_cropper_requested = Signal(list) # list of (bgr_array, shot_name, frame_idx)

    def __init__(self, video_engine, parent=None):
        super().__init__(title="Storyboard Generator & Scene Cut Manager", parent=parent)
        self.video_engine = video_engine
        self.resize(1060, 720)
        self.setMinimumSize(850, 550)

        self.worker: Optional[SceneDetectWorker] = None
        self.contact_sheet_bgr: Optional[np.ndarray] = None
        self.shot_coords: List[Tuple[int, int, int, int, int]] = [] # (x, y, w, h, frame_idx)

        self._setup_ui()
        self._sync_current_state()

    def _setup_ui(self):
        layout = self.content_layout
        layout.setSpacing(8)

        # Main Split / Two-Column Layout
        main_box = QHBoxLayout()
        main_box.setSpacing(10)

        # ========================================================
        # LEFT SIDEBAR: Controls & Settings
        # ========================================================
        sidebar = QWidget()
        sidebar.setFixedWidth(310)
        side_layout = QVBoxLayout(sidebar)
        side_layout.setContentsMargins(0, 0, 0, 0)
        side_layout.setSpacing(8)

        # 1. Scene Cut Detection Panel
        box_detect = QGroupBox("1. Auto Scene Cut Detection")
        box_detect.setStyleSheet("""
            QGroupBox {
                color: #f59e0b;
                font-weight: bold;
                font-size: 11px;
                border: 1px solid rgba(245, 158, 11, 0.25);
                border-radius: 5px;
                margin-top: 6px;
                padding-top: 10px;
            }
            QGroupBox::title { subcontrol-origin: margin; left: 8px; padding: 0 4px; }
        """)
        det_layout = QVBoxLayout(box_detect)
        det_layout.setSpacing(6)

        self.lbl_detect_info = QLabel("Detect shot cuts and mark timeline with amber pins.")
        self.lbl_detect_info.setWordWrap(True)
        self.lbl_detect_info.setStyleSheet("color: #94a3b8; font-size: 10px;")
        det_layout.addWidget(self.lbl_detect_info)

        # Sensitivity Slider
        sens_row = QHBoxLayout()
        lbl_sens = QLabel("Sensitivity:")
        lbl_sens.setStyleSheet("color: #cbd5e1; font-size: 10px;")
        sens_row.addWidget(lbl_sens)
        
        self.slider_sens = QSlider(Qt.Horizontal)
        self.slider_sens.setRange(20, 60)
        self.slider_sens.setValue(38)
        self.slider_sens.setToolTip("Lower = More cuts detected | Higher = Only major scene changes")
        sens_row.addWidget(self.slider_sens)
        
        self.lbl_sens_val = QLabel("Normal")
        self.lbl_sens_val.setStyleSheet("color: #38bdf8; font-size: 10px; font-weight: bold; min-width: 44px;")
        self.slider_sens.valueChanged.connect(self._on_sens_changed)
        sens_row.addWidget(self.lbl_sens_val)
        det_layout.addLayout(sens_row)

        # Detect Buttons
        det_btn_box = QHBoxLayout()
        self.btn_detect = QPushButton("⚡ Scan Scene Cuts")
        self.btn_detect.setObjectName("amberBtn")
        self.btn_detect.setFixedHeight(28)
        self.btn_detect.setStyleSheet("""
            QPushButton#amberBtn {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #d97706, stop:1 #b45309);
                color: #ffffff;
                font-weight: bold;
                font-size: 11px;
                border: none;
                border-radius: 4px;
            }
            QPushButton#amberBtn:hover { background: #f59e0b; }
        """)
        self.btn_detect.clicked.connect(self._toggle_scene_detection)
        det_btn_box.addWidget(self.btn_detect, 2)

        self.btn_clear_cuts = QPushButton("Clear")
        self.btn_clear_cuts.setFixedHeight(28)
        self.btn_clear_cuts.setToolTip("Clear all scene cut markers")
        self.btn_clear_cuts.clicked.connect(self._clear_scene_cuts)
        det_btn_box.addWidget(self.btn_clear_cuts, 1)
        det_layout.addLayout(det_btn_box)

        # Progress bar
        self.prog_bar = QProgressBar()
        self.prog_bar.setFixedHeight(14)
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
            QProgressBar::chunk { background: #f59e0b; border-radius: 2px; }
        """)
        self.prog_bar.hide()
        det_layout.addWidget(self.prog_bar)

        self.lbl_cuts_status = QLabel("No scene cuts detected yet.")
        self.lbl_cuts_status.setStyleSheet("color: #64748b; font-size: 10px; font-weight: 500;")
        det_layout.addWidget(self.lbl_cuts_status)

        side_layout.addWidget(box_detect)

        # 2. Storyboard Settings Panel
        box_grid = QGroupBox("2. Storyboard Layout & Options")
        box_grid.setStyleSheet("""
            QGroupBox {
                color: #38bdf8;
                font-weight: bold;
                font-size: 11px;
                border: 1px solid rgba(56, 189, 248, 0.25);
                border-radius: 5px;
                margin-top: 6px;
                padding-top: 10px;
            }
            QGroupBox::title { subcontrol-origin: margin; left: 8px; padding: 0 4px; }
        """)
        grid_layout = QVBoxLayout(box_grid)
        grid_layout.setSpacing(6)

        # Source Selection
        lbl_mode = QLabel("Shots Selection:")
        lbl_mode.setStyleSheet("color: #cbd5e1; font-size: 10px;")
        grid_layout.addWidget(lbl_mode)

        self.combo_source = QComboBox()
        self.combo_source.addItems([
            "Detected Scene Cuts (1 shot / scene)",
            "3 × 3 Grid (9 evenly spaced shots)",
            "4 × 4 Grid (16 evenly spaced shots)",
            "5 × 5 Grid (25 evenly spaced shots)",
            "In / Out Marked Range (12 shots)"
        ])
        self.combo_source.setFixedHeight(26)
        self.combo_source.currentIndexChanged.connect(self._rebuild_storyboard)
        grid_layout.addWidget(self.combo_source)

        # Columns
        col_row = QHBoxLayout()
        lbl_cols = QLabel("Grid Columns:")
        lbl_cols.setStyleSheet("color: #cbd5e1; font-size: 10px;")
        col_row.addWidget(lbl_cols)
        
        self.combo_cols = QComboBox()
        self.combo_cols.addItems(["2 Columns", "3 Columns", "4 Columns", "5 Columns", "6 Columns"])
        self.combo_cols.setCurrentIndex(1) # 3 columns default
        self.combo_cols.setFixedHeight(26)
        self.combo_cols.currentIndexChanged.connect(self._rebuild_storyboard)
        col_row.addWidget(self.combo_cols)
        grid_layout.addLayout(col_row)

        # Toggles
        self.chk_timecode = QCheckBox("Burn Timecode badge on each shot")
        self.chk_timecode.setChecked(True)
        self.chk_timecode.toggled.connect(self._rebuild_storyboard)
        grid_layout.addWidget(self.chk_timecode)

        self.chk_shot_num = QCheckBox("Show Shot Index (#1, #2...)")
        self.chk_shot_num.setChecked(True)
        self.chk_shot_num.toggled.connect(self._rebuild_storyboard)
        grid_layout.addWidget(self.chk_shot_num)

        self.chk_header = QCheckBox("Include Header Banner (Title, Dur, FPS)")
        self.chk_header.setChecked(True)
        self.chk_header.toggled.connect(self._rebuild_storyboard)
        grid_layout.addWidget(self.chk_header)

        side_layout.addWidget(box_grid)

        # 3. Actions Panel
        box_actions = QWidget()
        act_layout = QVBoxLayout(box_actions)
        act_layout.setContentsMargins(0, 4, 0, 0)
        act_layout.setSpacing(6)

        self.btn_export_sheet = QPushButton("📸 Export Contact Sheet...")
        self.btn_export_sheet.setObjectName("primaryBtn")
        self.btn_export_sheet.setFixedHeight(30)
        self.btn_export_sheet.clicked.connect(self._export_contact_sheet)
        act_layout.addWidget(self.btn_export_sheet)

        self.btn_copy_sheet = QPushButton("📋 Copy to Clipboard")
        self.btn_copy_sheet.setFixedHeight(28)
        self.btn_copy_sheet.clicked.connect(self._copy_contact_sheet)
        act_layout.addWidget(self.btn_copy_sheet)

        self.btn_send_cropper = QPushButton("🗂️ Send Shots to Cropper Media Bin")
        self.btn_send_cropper.setToolTip("Send all extracted shot still frames directly into Image Cropper for cropping")
        self.btn_send_cropper.setFixedHeight(28)
        self.btn_send_cropper.setStyleSheet("""
            QPushButton {
                background: #1e1b4b;
                border: 1px solid rgba(129, 140, 248, 0.35);
                color: #a5b4fc;
                font-weight: 600;
                font-size: 11px;
                border-radius: 4px;
            }
            QPushButton:hover {
                background: #2e2875;
                color: #ffffff;
                border: 1px solid #818cf8;
            }
        """)
        self.btn_send_cropper.clicked.connect(self._send_to_cropper_bin)
        act_layout.addWidget(self.btn_send_cropper)

        side_layout.addWidget(box_actions)
        side_layout.addStretch()

        btn_close = QPushButton("Done")
        btn_close.setFixedHeight(28)
        btn_close.clicked.connect(self.close)
        side_layout.addWidget(btn_close)

        main_box.addWidget(sidebar, 0)

        # ========================================================
        # RIGHT AREA: Interactive Contact Sheet Preview
        # ========================================================
        right_container = QWidget()
        right_layout = QVBoxLayout(right_container)
        right_layout.setContentsMargins(0, 0, 0, 0)
        right_layout.setSpacing(4)

        header_preview = QHBoxLayout()
        lbl_prev_title = QLabel("Storyboard Preview (Click any shot to jump in video)")
        lbl_prev_title.setStyleSheet("color: #e2e8f0; font-weight: bold; font-size: 11px;")
        header_preview.addWidget(lbl_prev_title)

        self.lbl_sheet_dims = QLabel("")
        self.lbl_sheet_dims.setStyleSheet("color: #38bdf8; font-family: 'Consolas', monospace; font-size: 10px;")
        header_preview.addWidget(self.lbl_sheet_dims)
        header_preview.addStretch()

        self.btn_refresh = QPushButton("🔄 Refresh")
        self.btn_refresh.setFixedSize(68, 22)
        self.btn_refresh.setStyleSheet("font-size: 10px; padding: 2px 6px;")
        self.btn_refresh.clicked.connect(self._rebuild_storyboard)
        header_preview.addWidget(self.btn_refresh)
        right_layout.addLayout(header_preview)

        # ScrollArea for Contact Sheet
        self.scroll_area = QScrollArea()
        self.scroll_area.setWidgetResizable(True)
        self.scroll_area.setStyleSheet("""
            QScrollArea {
                background-color: #0b0e14;
                border: 1px solid #1a2233;
                border-radius: 6px;
            }
        """)

        self.preview_label = QLabel()
        self.preview_label.setAlignment(Qt.AlignCenter)
        self.preview_label.setCursor(Qt.PointingHandCursor)
        self.preview_label.mousePressEvent = self._on_preview_clicked
        self.scroll_area.setWidget(self.preview_label)
        right_layout.addWidget(self.scroll_area, 1)

        main_box.addWidget(right_container, 1)
        layout.addLayout(main_box)

    def _sync_current_state(self):
        cuts = self.video_engine.scene_cuts
        if cuts:
            self.lbl_cuts_status.setText(f"✓ {len(cuts)} scene cuts active on timeline")
            self.lbl_cuts_status.setStyleSheet("color: #f59e0b; font-weight: bold; font-size: 10px;")
            self.btn_clear_cuts.setEnabled(True)
        else:
            self.lbl_cuts_status.setText("No scene cuts detected yet.")
            self.lbl_cuts_status.setStyleSheet("color: #64748b; font-size: 10px;")
            self.btn_clear_cuts.setEnabled(False)

        QTimer.singleShot(50, self._rebuild_storyboard)

    def _on_sens_changed(self, val: int):
        if val <= 28:
            self.lbl_sens_val.setText("High")
        elif val >= 46:
            self.lbl_sens_val.setText("Low")
        else:
            self.lbl_sens_val.setText("Normal")

    # --- Scene Cut Detection Execution ---
    def _toggle_scene_detection(self):
        if self.worker is not None and self.worker.isRunning():
            self.worker.cancel()
            self.btn_detect.setText("⚡ Scan Scene Cuts")
            self.prog_bar.hide()
            return

        if not self.video_engine.is_loaded:
            return

        self.btn_detect.setText("⏹ Stop Scanning")
        self.prog_bar.show()
        self.prog_bar.setRange(0, self.video_engine.total_frames)
        self.prog_bar.setValue(0)

        # Invert sensitivity slider to distance threshold (0.20 to 0.60)
        sens_val = self.slider_sens.value()
        threshold = float(sens_val) / 100.0

        self.worker = SceneDetectWorker(
            video_path=self.video_engine.video_path,
            total_frames=self.video_engine.total_frames,
            fps=self.video_engine.fps,
            threshold=threshold,
            min_scene_len=int(self.video_engine.fps * 0.5), # at least 0.5 sec between cuts
            preview_path=self.video_engine.preview_path
        )
        self.worker.progress.connect(self._on_worker_progress)
        self.worker.finished.connect(self._on_worker_finished)
        self.worker.failed.connect(self._on_worker_failed)
        self.worker.start()

    def _on_worker_progress(self, cur: int, total: int, fps: float):
        self.prog_bar.setValue(cur)
        self.lbl_cuts_status.setText(f"Scanning... {cur:,}/{total:,} ({fps:.0f} FPS)")

    def _on_worker_finished(self, cuts: List[int], elapsed: float):
        self.btn_detect.setText("⚡ Scan Scene Cuts")
        self.prog_bar.hide()
        self.video_engine.scene_cuts = cuts
        self.scene_cuts_updated.emit(cuts)
        self._sync_current_state()

        # If source is set to scene cuts, rebuild
        if self.combo_source.currentIndex() == 0:
            self._rebuild_storyboard()

    def _on_worker_failed(self, err: str):
        self.btn_detect.setText("⚡ Scan Scene Cuts")
        self.prog_bar.hide()
        QMessageBox.warning(self, "Detection Failed", err)

    def _clear_scene_cuts(self):
        self.video_engine.scene_cuts.clear()
        self.scene_cuts_updated.emit([])
        self._sync_current_state()

    # --- Storyboard Image Generation ---
    def _get_target_frame_indices(self) -> List[int]:
        if not self.video_engine.is_loaded:
            return []

        idx = self.combo_source.currentIndex()
        total = self.video_engine.total_frames

        if idx == 0: # Scene cuts
            cuts = self.video_engine.scene_cuts
            if cuts:
                # Include first frame + each cut
                frames = [0] + [c for c in cuts if c != 0]
                return sorted(list(set(frames)))
            # Fallback to 9 shots if no cuts detected
            count = 9
            step = max(1, total // count)
            return [min(total - 1, i * step) for i in range(count)]

        elif idx == 1: # 3x3 = 9
            count = 9
            step = max(1, total // count)
            return [min(total - 1, i * step) for i in range(count)]

        elif idx == 2: # 4x4 = 16
            count = 16
            step = max(1, total // count)
            return [min(total - 1, i * step) for i in range(count)]

        elif idx == 3: # 5x5 = 25
            count = 25
            step = max(1, total // count)
            return [min(total - 1, i * step) for i in range(count)]

        else: # In / Out Range
            start = self.video_engine.in_point or 0
            end = self.video_engine.out_point or (total - 1)
            span = max(1, end - start)
            count = 12
            step = max(1, span // count)
            return [min(end, start + i * step) for i in range(count)]

    def _rebuild_storyboard(self):
        if not self.video_engine.is_loaded:
            return

        indices = self._get_target_frame_indices()
        if not indices:
            return

        cols = self.combo_cols.currentIndex() + 2
        burn_tc = self.chk_timecode.isChecked()
        burn_idx = self.chk_shot_num.isChecked()
        include_header = self.chk_header.isChecked()

        # Thumbnail cell dimensions
        tw = 320
        th = int(round(tw * (self.video_engine.height / float(self.video_engine.width))))
        padding = 10
        header_h = 56 if include_header else 0

        rows = (len(indices) + cols - 1) // cols
        sheet_w = cols * tw + (cols + 1) * padding
        sheet_h = header_h + rows * th + (rows + 1) * padding

        sheet = np.full((sheet_h, sheet_w, 3), (15, 20, 32), dtype=np.uint8) # Dark studio slate

        # Render Header Banner
        info = self.video_engine.get_info()
        filename = info.get("filename", "Video")
        w_v = self.video_engine.width
        h_v = self.video_engine.height
        fps_v = self.video_engine.fps
        dur_v = self.video_engine.duration_sec

        if include_header:
            cv2.putText(sheet, f"STORYBOARD: {filename}", (padding + 4, 28), cv2.FONT_HERSHEY_DUPLEX, 0.65, (255, 255, 255), 1, cv2.LINE_AA)
            sub_text = f"{w_v}x{h_v}  •  {fps_v:.2f} FPS  •  {dur_v:.1f}s ({self.video_engine.total_frames:,} frames)  •  {len(indices)} Shots"
            cv2.putText(sheet, sub_text, (padding + 4, 46), cv2.FONT_HERSHEY_SIMPLEX, 0.42, (56, 189, 248), 1, cv2.LINE_AA)
            cv2.line(sheet, (padding, header_h - 2), (sheet_w - padding, header_h - 2), (30, 41, 59), 1)

        self.shot_coords.clear()

        # Render Thumbnails
        for i, f_idx in enumerate(indices):
            raw_frame = self.video_engine.get_frame(f_idx)
            if raw_frame is None:
                continue

            thumb = cv2.resize(raw_frame, (tw, th), interpolation=cv2.INTER_AREA)

            r = i // cols
            c = i % cols
            x = padding + c * (tw + padding)
            y = header_h + padding + r * (th + padding)

            sheet[y : y + th, x : x + tw] = thumb
            cv2.rectangle(sheet, (x, y), (x + tw - 1, y + th - 1), (51, 65, 85), 1)

            # Store hit-test bounding box for click navigation
            self.shot_coords.append((x, y, tw, th, f_idx))

            # Burn Overlays
            if burn_tc:
                tc = frames_to_timecode(f_idx, self.video_engine.fps)
                (t_w, t_h), _ = cv2.getTextSize(tc, cv2.FONT_HERSHEY_SIMPLEX, 0.38, 1)
                # Background pill
                cv2.rectangle(sheet, (x + 6, y + th - t_h - 10), (x + 12 + t_w, y + th - 4), (10, 14, 22), -1)
                cv2.putText(sheet, tc, (x + 9, y + th - 7), cv2.FONT_HERSHEY_SIMPLEX, 0.38, (56, 189, 248), 1, cv2.LINE_AA)

            if burn_idx:
                idx_str = f"#{i+1}"
                (i_w, i_h), _ = cv2.getTextSize(idx_str, cv2.FONT_HERSHEY_SIMPLEX, 0.42, 1)
                cv2.rectangle(sheet, (x + 6, y + 6), (x + 12 + i_w, y + 10 + i_h), (10, 14, 22), -1)
                cv2.putText(sheet, idx_str, (x + 9, y + 8 + i_h), cv2.FONT_HERSHEY_SIMPLEX, 0.42, (245, 158, 11), 1, cv2.LINE_AA)

        self.contact_sheet_bgr = sheet

        # Update preview pixmap
        h_s, w_s = sheet.shape[:2]
        self.lbl_sheet_dims.setText(f"{w_s} × {h_s} px")
        qimg = QImage(sheet.data, w_s, h_s, w_s * 3, QImage.Format.Format_BGR888)
        self.preview_label.setPixmap(QPixmap.fromImage(qimg))

    def _on_preview_clicked(self, event):
        pos = event.pos()
        px, py = pos.x(), pos.y()

        # Check which shot was clicked
        for (x, y, w, h, f_idx) in self.shot_coords:
            if x <= px <= x + w and y <= py <= y + h:
                self.jump_to_frame_requested.emit(f_idx)
                break

    # --- Export & Clipboard ---
    def _export_contact_sheet(self):
        if self.contact_sheet_bgr is None:
            return

        info = self.video_engine.get_info()
        base_name = Path(info.get("filename", "video")).stem
        default_name = f"{base_name}_storyboard.png"

        chosen, _ = QFileDialog.getSaveFileName(
            self,
            "Save Storyboard Contact Sheet",
            str(Path.home() / "Pictures" / default_name),
            "PNG Image (*.png);;JPEG Image (*.jpg);;All Files (*.*)"
        )
        if chosen:
            try:
                ext = Path(chosen).suffix.lower()
                params = [cv2.IMWRITE_JPEG_QUALITY, 95] if ext in (".jpg", ".jpeg") else [cv2.IMWRITE_PNG_COMPRESSION, 3]
                ok, buf = cv2.imencode(ext if ext else ".png", self.contact_sheet_bgr, params)
                if ok:
                    with open(chosen, "wb") as f:
                        f.write(buf.tobytes())
                    self.btn_export_sheet.setText("✓ Contact Sheet Saved!")
                    QTimer.singleShot(1600, lambda: self.btn_export_sheet.setText("📸 Export Contact Sheet..."))
            except Exception as e:
                QMessageBox.critical(self, "Export Error", f"Failed to save contact sheet:\n{e}")

    def _copy_contact_sheet(self):
        if self.contact_sheet_bgr is None:
            return
        h, w = self.contact_sheet_bgr.shape[:2]
        qimg = QImage(self.contact_sheet_bgr.data, w, h, w * 3, QImage.Format.Format_BGR888).copy()
        QGuiApplication.clipboard().setImage(qimg)
        self.btn_copy_sheet.setText("✓ Copied to Clipboard!")
        QTimer.singleShot(1400, lambda: self.btn_copy_sheet.setText("📋 Copy to Clipboard"))

    def _send_to_cropper_bin(self):
        """Extract all storyboard shot frames and send them to the Image Cropper Media Bin."""
        if not self.video_engine.is_loaded:
            return

        indices = self._get_target_frame_indices()
        if not indices:
            return

        info = self.video_engine.get_info()
        stem = Path(info.get("filename", "shot")).stem

        shots = []
        for i, f_idx in enumerate(indices):
            raw = self.video_engine.get_frame(f_idx)
            if raw is not None:
                shots.append((raw.copy(), f"{stem}_shot_{i+1:02d}", f_idx))

        if shots:
            self.send_shots_to_cropper_requested.emit(shots)
            self.btn_send_cropper.setText(f"✓ {len(shots)} Shots Sent to Cropper!")
            QTimer.singleShot(1600, lambda: self.btn_send_cropper.setText("🗂️ Send Shots to Cropper Media Bin"))

    def closeEvent(self, event):
        if self.worker is not None and self.worker.isRunning():
            self.worker.cancel()
            self.worker.wait(500)
        super().closeEvent(event)
