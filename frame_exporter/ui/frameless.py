"""
Custom Frameless Window Chrome and Title Bar for High-End Studio Feel.
Replaces all default OS window decorations with a sleek, hardware-accelerated dark title bar.
"""

from typing import Optional, List, Tuple
from PySide6.QtWidgets import (
    QWidget, QHBoxLayout, QVBoxLayout, QLabel, QPushButton,
    QMenuBar, QMenu, QFrame, QSizePolicy, QDialog
)
from PySide6.QtCore import Qt, QPoint, Signal, QEvent, QRectF
from PySide6.QtGui import QMouseEvent, QCursor, QFont, QColor, QPainter, QLinearGradient

class TitleBarButton(QPushButton):
    """Sleek window control button (min, max, close) using native Windows system glyphs."""
    def __init__(self, text: str, is_close: bool = False, parent=None):
        super().__init__(text, parent)
        self.is_close = is_close
        self.setFixedSize(38, 36)
        self.setFocusPolicy(Qt.NoFocus)
        self._update_style()

    def _update_style(self):
        if self.is_close:
            self.setStyleSheet("""
                QPushButton {
                    background: transparent;
                    color: #94A3B8;
                    border: none;
                    font-size: 10px;
                    font-family: 'Segoe MDL2 Assets', 'Segoe UI Symbol', sans-serif;
                }
                QPushButton:hover {
                    background-color: #E31B23;
                    color: #FFFFFF;
                }
                QPushButton:pressed {
                    background-color: #C0000A;
                    color: #FFFFFF;
                }
            """)
        else:
            self.setStyleSheet("""
                QPushButton {
                    background: transparent;
                    color: #94A3B8;
                    border: none;
                    font-size: 10px;
                    font-family: 'Segoe MDL2 Assets', 'Segoe UI Symbol', sans-serif;
                }
                QPushButton:hover {
                    background-color: rgba(255, 255, 255, 0.08);
                    color: #FFFFFF;
                }
                QPushButton:pressed {
                    background-color: rgba(255, 255, 255, 0.04);
                    color: #CBD5E1;
                }
            """)

class CustomTitleBar(QWidget):
    """
    High-End Studio Custom Title Bar.
    - App Logo & Name
    - Embedded Menus
    - Centered Document Info Badge
    - Native-feel Window Controls (Minimize, Maximize, Close)
    - Full Aero Snap & System Window Move / Double-Click Maximize
    """
    def __init__(self, title: str = "Frame Exporter", icon_text: str = "🎞️",
                 show_menus: bool = True, show_maximize: bool = True, parent=None):
        super().__init__(parent)
        self.app_title_str = title
        self.icon_glyph = icon_text
        self.show_menus = show_menus
        self.show_maximize = show_maximize
        
        self.setFixedHeight(36)
        self.setObjectName("customTitleBar")
        self._setup_ui()

    def _setup_ui(self):
        self.setStyleSheet("""
            QWidget#customTitleBar {
                background-color: #0D0D11;
                border-bottom: 1px solid rgba(255, 255, 255, 0.06);
            }
        """)

        layout = QHBoxLayout(self)
        layout.setContentsMargins(10, 0, 4, 0)
        layout.setSpacing(4)

        # 1. Left: App Icon & Brand Title
        self.lbl_icon = QLabel(self.icon_glyph)
        self.lbl_icon.setFixedHeight(36)
        self.lbl_icon.setAlignment(Qt.AlignVCenter | Qt.AlignCenter)
        self.lbl_icon.setStyleSheet("font-size: 13px; background: transparent;")
        layout.addWidget(self.lbl_icon, 0, Qt.AlignVCenter)

        self.lbl_app_name = QLabel(self.app_title_str)
        self.lbl_app_name.setFixedHeight(36)
        self.lbl_app_name.setAlignment(Qt.AlignVCenter | Qt.AlignLeft)
        self.lbl_app_name.setStyleSheet("""
            QLabel {
                color: #F4F5F7;
                font-size: 11px;
                font-weight: 800;
                letter-spacing: 0.5px;
                background: transparent;
            }
        """)
        layout.addWidget(self.lbl_app_name, 0, Qt.AlignVCenter)

        layout.addSpacing(4)

        # 2. Integrated Menubar (embedded directly in title bar, vertically centered)
        if self.show_menus:
            self.menu_bar = QMenuBar(self)
            self.menu_bar.setFixedHeight(36)
            self.menu_bar.setStyleSheet("""
                QMenuBar {
                    background: transparent;
                    color: #94A3B8;
                    font-size: 11px;
                    font-weight: 600;
                    border: none;
                    spacing: 2px;
                }
                QMenuBar::item {
                    background: transparent;
                    padding: 5px 8px;
                    margin-top: 5px;
                    margin-bottom: 3px;
                    border-radius: 4px;
                }
                QMenuBar::item:selected {
                    background-color: rgba(255, 255, 255, 0.08);
                    color: #FFFFFF;
                }
                QMenu {
                    background-color: #1A1A22;
                    color: #F4F5F7;
                    border: 1px solid rgba(255, 255, 255, 0.08);
                    border-radius: 8px;
                    padding: 5px;
                    font-size: 12px;
                }
                QMenu::item {
                    padding: 6px 24px 6px 12px;
                    border-radius: 4px;
                }
                QMenu::item:selected {
                    background-color: #C0000A;
                    color: #FFFFFF;
                }
                QMenu::separator {
                    height: 1px;
                    background: rgba(255, 255, 255, 0.06);
                    margin: 4px 8px;
                }
            """)
            layout.addWidget(self.menu_bar, 0, Qt.AlignVCenter)
        else:
            self.menu_bar = None

        # Clean draggable title bar stretch across center
        layout.addStretch(1)

        self.status_pill = None
        self._full_status_text = ""

        # 3. Right: Window Management Controls
        self.btn_min = TitleBarButton("\uE921", parent=self)
        self.btn_min.setToolTip("Minimize")
        self.btn_min.clicked.connect(self._on_minimize)
        layout.addWidget(self.btn_min)

        if self.show_maximize:
            self.btn_max = TitleBarButton("\uE922", parent=self)
            self.btn_max.setToolTip("Maximize")
            self.btn_max.clicked.connect(self._on_toggle_maximize)
            layout.addWidget(self.btn_max)
        else:
            self.btn_max = None

        self.btn_close = TitleBarButton("\uE8BB", is_close=True, parent=self)
        self.btn_close.setToolTip("Close")
        self.btn_close.clicked.connect(self._on_close)
        layout.addWidget(self.btn_close)

    def set_status_pill(self, text: str, is_active: bool = True):
        """Maintains API compatibility without cluttering top bar."""
        self._full_status_text = text

    def update_max_button(self, is_maximized: bool):
        """Toggle glyph between maximize and restore."""
        if self.btn_max:
            self.btn_max.setText("\uE923" if is_maximized else "\uE922")
            self.btn_max.setToolTip("Restore" if is_maximized else "Maximize")

    def _on_minimize(self):
        w = self.window()
        if w:
            w.showMinimized()

    def _on_toggle_maximize(self):
        if not self.show_maximize:
            return
        w = self.window()
        if not w:
            return
        if w.isMaximized():
            w.showNormal()
            self.update_max_button(False)
        else:
            w.showMaximized()
            self.update_max_button(True)

    def _on_close(self):
        w = self.window()
        if w:
            w.close()

    # --- Window Dragging and Native Move ---
    def mousePressEvent(self, event: QMouseEvent):
        if event.button() == Qt.LeftButton:
            # If user clicked on a menu item or button, don't drag
            child = self.childAt(event.position().toPoint())
            ctrl_buttons = (self.btn_min, self.btn_close) if self.btn_max is None else (self.btn_min, self.btn_max, self.btn_close)
            if child in ctrl_buttons or (self.menu_bar and self.menu_bar.geometry().contains(event.position().toPoint())):
                super().mousePressEvent(event)
                return
            
            wh = self.window().windowHandle()
            if wh:
                wh.startSystemMove()
                event.accept()
                return
        super().mousePressEvent(event)

    def mouseDoubleClickEvent(self, event: QMouseEvent):
        if event.button() == Qt.LeftButton:
            child = self.childAt(event.position().toPoint())
            ctrl_buttons = (self.btn_min, self.btn_close) if self.btn_max is None else (self.btn_min, self.btn_max, self.btn_close)
            if child not in ctrl_buttons:
                if self.show_maximize:
                    self._on_toggle_maximize()
                    event.accept()
                    return
        super().mouseDoubleClickEvent(event)


class FramelessWindowMixin:
    """
    Mixin for QMainWindow or QWidget to enable native hardware-accelerated edge resizing
    and frameless window management on Windows.
    """
    RESIZE_MARGIN = 7

    def setup_frameless(self, title_bar: CustomTitleBar):
        self.custom_title_bar = title_bar
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.Window)
        self.setMouseTracking(True)
        self.installEventFilter(self)

    def _get_resize_edges(self, pos: QPoint):
        if self.isMaximized() or self.isFullScreen():
            return Qt.Edges()
        w = self.width()
        h = self.height()
        m = self.RESIZE_MARGIN
        edges = Qt.Edges()
        if pos.x() <= m:
            edges |= Qt.Edge.LeftEdge
        elif pos.x() >= w - m:
            edges |= Qt.Edge.RightEdge
        if pos.y() <= m:
            edges |= Qt.Edge.TopEdge
        elif pos.y() >= h - m:
            edges |= Qt.Edge.BottomEdge
        return edges

    def eventFilter(self, obj, event: QEvent) -> bool:
        if event.type() == QEvent.MouseMove and not (self.isMaximized() or self.isFullScreen()):
            pos = event.position().toPoint() if hasattr(event, "position") else event.pos()
            edges = self._get_resize_edges(pos)
            if edges in (Qt.Edge.LeftEdge | Qt.Edge.TopEdge, Qt.Edge.RightEdge | Qt.Edge.BottomEdge):
                self.setCursor(Qt.SizeFDiagCursor)
            elif edges in (Qt.Edge.RightEdge | Qt.Edge.TopEdge, Qt.Edge.LeftEdge | Qt.Edge.BottomEdge):
                self.setCursor(Qt.SizeBDiagCursor)
            elif edges in (Qt.Edge.LeftEdge, Qt.Edge.RightEdge):
                self.setCursor(Qt.SizeHorCursor)
            elif edges in (Qt.Edge.TopEdge, Qt.Edge.BottomEdge):
                self.setCursor(Qt.SizeVerCursor)
            else:
                self.setCursor(Qt.ArrowCursor)

        elif event.type() == QEvent.MouseButtonPress and not (self.isMaximized() or self.isFullScreen()):
            if event.button() == Qt.LeftButton:
                pos = event.position().toPoint() if hasattr(event, "position") else event.pos()
                edges = self._get_resize_edges(pos)
                if edges:
                    wh = self.windowHandle()
                    if wh:
                        wh.startSystemResize(edges)
                        return True

        elif event.type() == QEvent.WindowStateChange:
            if hasattr(self, "custom_title_bar") and self.custom_title_bar:
                self.custom_title_bar.update_max_button(self.isMaximized())

        return super().eventFilter(obj, event)


class DarkModalDialog(FramelessWindowMixin, QDialog):
    """
    Sleek Frameless Modal Dialog with custom dark title bar and glowing border.
    Eliminates all native Windows OS message box chrome.
    """
    def __init__(self, title: str = "Dialog", parent=None):
        super().__init__(parent)
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.Dialog)

        self.root_frame = QFrame(self)
        self.root_frame.setObjectName("windowRootFrame")
        self.root_frame.setStyleSheet("""
            QFrame#windowRootFrame {
                background-color: #15151A;
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-radius: 10px;
            }
        """)

        outer_layout = QVBoxLayout(self)
        outer_layout.setContentsMargins(0, 0, 0, 0)
        outer_layout.addWidget(self.root_frame)

        self.inner_layout = QVBoxLayout(self.root_frame)
        self.inner_layout.setContentsMargins(0, 0, 0, 0)
        self.inner_layout.setSpacing(0)

        # Title bar (no menus, just title and close button)
        self.title_bar = CustomTitleBar(title=title, icon_text="✨", show_menus=False, parent=self)
        self.title_bar.btn_min.hide()
        self.title_bar.btn_max.hide()
        self.inner_layout.addWidget(self.title_bar)

        # Content widget
        self.content_widget = QWidget(self)
        self.content_layout = QVBoxLayout(self.content_widget)
        self.content_layout.setContentsMargins(18, 14, 18, 16)
        self.content_layout.setSpacing(12)
        self.inner_layout.addWidget(self.content_widget, 1)

        self.setup_frameless(self.title_bar)


