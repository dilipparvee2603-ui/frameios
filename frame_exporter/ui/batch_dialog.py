import os
from pathlib import Path
from PySide6.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout, QLabel, QSpinBox,
    QPushButton, QProgressBar, QGroupBox, QFormLayout, QMessageBox, QFrame, QWidget
)
from PySide6.QtCore import Qt, QThread, Signal
from ..utils import generate_output_filename, open_in_explorer
from .frameless import CustomTitleBar, FramelessWindowMixin

class BatchExportWorker(QThread):
    progress = Signal(int, int, str) # current, total, last_saved_file
    finished = Signal(int, int)      # success_count, fail_count
    error = Signal(str)

    def __init__(self, video_engine, start_frame: int, end_frame: int, step: int,
                 output_dir: str, template: str, ext: str, quality: int):
        super().__init__()
        self.video_engine = video_engine
        self.start_frame = start_frame
        self.end_frame = end_frame
        self.step = max(1, step)
        self.output_dir = output_dir
        self.template = template
        self.ext = ext
        self.quality = quality
        self._is_cancelled = False

    def cancel(self):
        self._is_cancelled = True

    def run(self):
        frames_to_export = list(range(self.start_frame, self.end_frame + 1, self.step))
        total = len(frames_to_export)
        success_count = 0
        fail_count = 0

        info = self.video_engine.get_info()
        video_path = info["path"]
        fps = info["fps"]
        width = info["width"]
        height = info["height"]

        for i, f_idx in enumerate(frames_to_export):
            if self._is_cancelled:
                break
                
            fname = generate_output_filename(video_path, f_idx, fps, width, height, self.template, self.ext)
            out_path = str(Path(self.output_dir) / fname)
            
            ok, saved_path, _ = self.video_engine.export_frame(f_idx, out_path, self.ext, self.quality)
            if ok:
                success_count += 1
                self.progress.emit(i + 1, total, fname)
            else:
                fail_count += 1

        self.finished.emit(success_count, fail_count)

class BatchExportDialog(FramelessWindowMixin, QDialog):
    """Dialog to configure and execute batch frame extraction."""

    def __init__(self, video_engine, default_output_dir: str, template: str, ext: str, quality: int, parent=None):
        super().__init__(parent)
        self.video_engine = video_engine
        self.output_dir = default_output_dir
        self.template = template
        self.ext = ext
        self.quality = quality
        self.worker = None

        self.setMinimumWidth(480)
        self._setup_ui()
        self.setup_frameless(self.title_bar)

    def _setup_ui(self):
        root_frame = QFrame(self)
        root_frame.setObjectName("windowRootFrame")
        outer_layout = QVBoxLayout(self)
        outer_layout.setContentsMargins(0, 0, 0, 0)
        outer_layout.addWidget(root_frame)

        dialog_layout = QVBoxLayout(root_frame)
        dialog_layout.setContentsMargins(0, 0, 0, 0)
        dialog_layout.setSpacing(0)

        # Title bar
        self.title_bar = CustomTitleBar(title="BATCH FRAME EXPORTER", icon_text="⚡", show_menus=False, parent=self)
        self.title_bar.btn_min.hide()
        self.title_bar.btn_max.hide()
        self.title_bar.set_status_pill("High-Speed Range Extraction", is_active=True)
        dialog_layout.addWidget(self.title_bar)

        content_widget = QWidget(self)
        layout = QVBoxLayout(content_widget)
        layout.setContentsMargins(16, 14, 16, 16)
        layout.setSpacing(12)
        dialog_layout.addWidget(content_widget, 1)

        info = self.video_engine.get_info()
        total_frames = max(1, info["total_frames"])
        in_pt = info["in_point"] if info["in_point"] is not None else 0
        out_pt = info["out_point"] if info["out_point"] is not None else (total_frames - 1)

        # Range settings group
        group = QGroupBox("Export Range & Step")
        form = QFormLayout(group)

        self.spin_start = QSpinBox()
        self.spin_start.setRange(0, total_frames - 1)
        self.spin_start.setValue(in_pt)
        form.addRow("Start Frame:", self.spin_start)

        self.spin_end = QSpinBox()
        self.spin_end.setRange(0, total_frames - 1)
        self.spin_end.setValue(out_pt)
        form.addRow("End Frame:", self.spin_end)

        self.spin_step = QSpinBox()
        self.spin_step.setRange(1, 1000)
        self.spin_step.setValue(1)
        self.spin_step.setToolTip("1 = Every frame, 5 = Every 5th frame, etc.")
        form.addRow("Frame Step Interval:", self.spin_step)

        layout.addWidget(group)

        # Info label
        self.info_label = QLabel()
        self.info_label.setStyleSheet("color: #94a3b8; font-size: 11px;")
        layout.addWidget(self.info_label)

        # Progress bar
        self.progress_bar = QProgressBar()
        self.progress_bar.setValue(0)
        self.progress_bar.setTextVisible(True)
        self.progress_bar.hide()
        layout.addWidget(self.progress_bar)

        # Buttons
        btn_box = QHBoxLayout()
        self.btn_cancel = QPushButton("Cancel")
        self.btn_cancel.clicked.connect(self._on_cancel)
        btn_box.addWidget(self.btn_cancel)

        btn_box.addStretch()

        self.btn_start = QPushButton("Start Export")
        self.btn_start.setObjectName("primaryBtn")
        self.btn_start.clicked.connect(self._on_start_batch)
        btn_box.addWidget(self.btn_start)

        layout.addLayout(btn_box)

        self.spin_start.valueChanged.connect(self._update_estimate)
        self.spin_end.valueChanged.connect(self._update_estimate)
        self.spin_step.valueChanged.connect(self._update_estimate)
        self._update_estimate()

    def _update_estimate(self):
        start = self.spin_start.value()
        end = self.spin_end.value()
        step = self.spin_step.value()
        if end >= start:
            count = len(range(start, end + 1, step))
            self.info_label.setText(f"Will export {count:,} frames to:\n{self.output_dir}")
            self.btn_start.setEnabled(True)
        else:
            self.info_label.setText("⚠️ End frame must be greater than or equal to Start frame")
            self.btn_start.setEnabled(False)

    def _on_start_batch(self):
        self.btn_start.setEnabled(False)
        self.spin_start.setEnabled(False)
        self.spin_end.setEnabled(False)
        self.spin_step.setEnabled(False)
        self.progress_bar.show()
        self.progress_bar.setValue(0)

        self.worker = BatchExportWorker(
            self.video_engine,
            self.spin_start.value(),
            self.spin_end.value(),
            self.spin_step.value(),
            self.output_dir,
            self.template,
            self.ext,
            self.quality
        )
        self.worker.progress.connect(self._on_progress)
        self.worker.finished.connect(self._on_finished)
        self.worker.start()

    def _on_progress(self, current, total, filename):
        percent = int((current / total) * 100)
        self.progress_bar.setValue(percent)
        self.progress_bar.setFormat(f"{current} / {total} frames ({percent}%)")

    def _on_finished(self, success_count, fail_count):
        self.progress_bar.setValue(100)
        msg = f"Successfully exported {success_count} frames!"
        if fail_count > 0:
            msg += f"\n({fail_count} failed)"
            
        box = QMessageBox(self)
        box.setWindowTitle("Export Complete")
        box.setText(msg)
        btn_open = box.addButton("Open Folder", QMessageBox.AcceptRole)
        box.addButton(QMessageBox.Ok)
        box.exec()
        
        if box.clickedButton() == btn_open:
            open_in_explorer(self.output_dir)
            
        self.accept()

    def _on_cancel(self):
        if self.worker and self.worker.isRunning():
            self.worker.cancel()
            self.worker.wait()
        self.reject()
