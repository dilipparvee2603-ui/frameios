from PySide6.QtWidgets import QWidget, QHBoxLayout, QLabel, QPushButton, QGraphicsOpacityEffect
from PySide6.QtCore import Qt, QTimer, QPropertyAnimation, QEasingCurve
from ..utils import open_in_explorer

class ToastNotification(QWidget):
    """Floating notification toast with interactive action button."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.target_path = None
        self._setup_ui()
        
        self.opacity_effect = QGraphicsOpacityEffect(self)
        self.setGraphicsEffect(self.opacity_effect)
        self.opacity_effect.setOpacity(0.0)
        
        self.hide_timer = QTimer(self)
        self.hide_timer.setSingleShot(True)
        self.hide_timer.timeout.connect(self.fade_out)
        
        self.anim = None
        self.hide()

    def _setup_ui(self):
        self.setAttribute(Qt.WA_TransparentForMouseEvents, False)
        self.setStyleSheet("""
            QWidget#toastWidget {
                background-color: #1A1A22;
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-left: 4px solid #10B981;
                border-radius: 8px;
            }
            QLabel {
                color: #F4F5F7;
                font-size: 12px;
                font-weight: 500;
                background: transparent;
            }
            QPushButton#actionBtn {
                background-color: #15151A;
                color: #F4F5F7;
                border: 1px solid rgba(255, 255, 255, 0.12);
                border-radius: 5px;
                padding: 4px 10px;
                font-weight: 600;
                font-size: 11px;
            }
            QPushButton#actionBtn:hover {
                background-color: #1E1E26;
                border: 1px solid rgba(255, 255, 255, 0.2);
                color: #FFFFFF;
            }
            QPushButton#closeBtn {
                background: transparent;
                border: none;
                color: #94A3B8;
                font-weight: bold;
                font-size: 14px;
                padding: 2px 4px;
            }
            QPushButton#closeBtn:hover {
                color: #FFFFFF;
            }
        """)
        self.setObjectName("toastWidget")

        layout = QHBoxLayout(self)
        layout.setContentsMargins(14, 10, 10, 10)
        layout.setSpacing(12)

        self.msg_label = QLabel(self)
        self.msg_label.setWordWrap(False)
        layout.addWidget(self.msg_label)

        self.action_btn = QPushButton("Open File", self)
        self.action_btn.setObjectName("actionBtn")
        self.action_btn.clicked.connect(self._on_action_clicked)
        layout.addWidget(self.action_btn)

        self.close_btn = QPushButton("×", self)
        self.close_btn.setObjectName("closeBtn")
        self.close_btn.clicked.connect(self.fade_out)
        layout.addWidget(self.close_btn)

    def show_message(self, message: str, file_path: str = None, duration_ms: int = 4000):
        self.msg_label.setText(message)
        self.target_path = file_path
        
        if file_path:
            self.action_btn.show()
        else:
            self.action_btn.hide()

        self.adjustSize()
        self.reposition()
        self.show()
        self.raise_()

        # Fade in
        self.anim = QPropertyAnimation(self.opacity_effect, b"opacity")
        self.anim.setDuration(220)
        self.anim.setStartValue(self.opacity_effect.opacity())
        self.anim.setEndValue(1.0)
        self.anim.setEasingCurve(QEasingCurve.OutCubic)
        self.anim.start()

        self.hide_timer.start(duration_ms)

    def fade_out(self):
        self.hide_timer.stop()
        self.anim = QPropertyAnimation(self.opacity_effect, b"opacity")
        self.anim.setDuration(250)
        self.anim.setStartValue(self.opacity_effect.opacity())
        self.anim.setEndValue(0.0)
        self.anim.setEasingCurve(QEasingCurve.InCubic)
        self.anim.finished.connect(self.hide)
        self.anim.start()

    def reposition(self):
        if self.parent():
            parent_rect = self.parent().rect()
            margin = 24
            x = parent_rect.width() - self.width() - margin
            y = parent_rect.height() - self.height() - margin - 30 # above status bar
            self.move(max(10, x), max(10, y))

    def _on_action_clicked(self):
        if self.target_path:
            open_in_explorer(self.target_path)
