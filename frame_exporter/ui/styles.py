"""
🎨 CFX Studio Glass Design System Stylesheet.
A comprehensive modern "Dark Glassmorphic Studio" design system specification
for high-performance desktop applications.

Key Tokens:
- Canvas Void Background: #0D0D11
- Card Surface (Base): #15151A
- Elevated Surface (Modals, Popovers, Dropdowns): #1A1A22
- Hairline Borders: rgba(255, 255, 255, 0.06) (default) to rgba(255, 255, 255, 0.12)
- Primary Brand Accent: #C0000A
- Brand Vibrant Red: #E31B23
- Primary CTA Gradient: #FF4A3D -> #D92A20 (Coral to Scarlet)
- Status: Emerald #10B981, Amber #F59E0B, Danger #EF4444
- Foregrounds: Primary #F4F5F7, Muted #94A3B8
- Fonts: 'Nunito', 'Segoe UI', -apple-system, BlinkMacSystemFont, 'Inter', Roboto, sans-serif
"""

DARK_THEME_QSS = """
/* ========================================================
   1. GLOBAL WINDOW & BASE TYPOGRAPHY (OLED DEPTH CANVAS)
   ======================================================== */
QWidget {
    background-color: #0D0D11;
    color: #F4F5F7;
    font-family: 'Nunito', 'Segoe UI', -apple-system, BlinkMacSystemFont, 'Inter', Roboto, sans-serif;
    font-size: 12px;
    selection-background-color: #C0000A;
    selection-color: #FFFFFF;
}

QMainWindow, QDialog {
    background-color: #0D0D11;
}

/* Master Outer Window Frame */
#windowRootFrame {
    background-color: #0D0D11;
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 8px;
}

/* Glass Card Container */
.glassCard {
    background-color: #15151A;
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 8px;
}

/* ========================================================
   2. MENU BAR & FLOATING MENUS (ELEVATED GLASS)
   ======================================================== */
QMenuBar {
    background: transparent;
    color: #94A3B8;
    border: none;
    padding: 2px 4px;
}

QMenuBar::item {
    background: transparent;
    padding: 4px 8px;
    border-radius: 4px;
}

QMenuBar::item:selected {
    background-color: rgba(255, 255, 255, 0.06);
    color: #F4F5F7;
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

/* ========================================================
   3. TOOLBARS
   ======================================================== */
QToolBar {
    background-color: #0D0D11;
    border-bottom: 1px solid rgba(255, 255, 255, 0.06);
    spacing: 6px;
    padding: 4px 8px;
}

/* ========================================================
   4. BUTTONS & MICRO-INTERACTIONS
   ======================================================== */
/* Ghost / Neutral Button */
QPushButton {
    background-color: #15151A;
    color: #F4F5F7;
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 6px;
    padding: 4px 12px;
    font-weight: 600;
    font-size: 12px;
    min-height: 22px;
}

QPushButton:hover {
    background-color: #1E1E26;
    border: 1px solid rgba(255, 255, 255, 0.12);
    color: #FFFFFF;
}

QPushButton:pressed {
    background-color: #121217;
    border: 1px solid rgba(255, 255, 255, 0.04);
}

QPushButton:disabled {
    background-color: rgba(255, 255, 255, 0.02);
    color: #555566;
    border: 1px solid rgba(255, 255, 255, 0.03);
}

/* Primary CTA Button: Coral to Scarlet Gradient with Soft Glow */
QPushButton#primaryBtn, QPushButton#exportBtn {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #FF4A3D, stop:1 #D92A20);
    color: #FFFFFF;
    border: 1px solid rgba(255, 74, 61, 0.4);
    font-weight: 700;
    font-size: 12px;
    padding: 4px 16px;
    border-radius: 6px;
}

QPushButton#primaryBtn:hover, QPushButton#exportBtn:hover {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #FF6257, stop:1 #E83328);
    border: 1px solid rgba(255, 74, 61, 0.6);
    color: #FFFFFF;
}

QPushButton#primaryBtn:pressed, QPushButton#exportBtn:pressed {
    background: #C0000A;
    border: 1px solid #C0000A;
}

QPushButton#primaryBtn:disabled, QPushButton#exportBtn:disabled {
    background: rgba(255, 74, 61, 0.15);
    color: #777788;
    border: 1px solid rgba(255, 255, 255, 0.04);
}

/* Success / Emerald Button */
QPushButton#successBtn {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #059669, stop:1 #10B981);
    color: #FFFFFF;
    border: 1px solid rgba(16, 185, 129, 0.4);
    font-weight: 700;
    padding: 4px 14px;
    border-radius: 6px;
}

QPushButton#successBtn:hover {
    background: #10B981;
    border: 1px solid rgba(16, 185, 129, 0.6);
}

QPushButton#successBtn:pressed {
    background: #047857;
}

/* Amber / Warning Button */
QPushButton#amberBtn {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #D97706, stop:1 #F59E0B);
    color: #FFFFFF;
    border: 1px solid rgba(245, 158, 11, 0.4);
    font-weight: 700;
    padding: 4px 14px;
    border-radius: 6px;
}

QPushButton#amberBtn:hover {
    background: #F59E0B;
    border: 1px solid rgba(245, 158, 11, 0.6);
}

/* Cyan / Vibrant Tool Button */
QPushButton#cyanBtn {
    background-color: rgba(6, 182, 212, 0.12);
    border: 1px solid rgba(6, 182, 212, 0.35);
    color: #38BDF8;
    font-weight: 700;
    font-size: 12px;
    padding: 4px 14px;
    border-radius: 6px;
}

QPushButton#cyanBtn:hover {
    background-color: rgba(6, 182, 212, 0.22);
    border: 1px solid rgba(6, 182, 212, 0.6);
    color: #FFFFFF;
}

/* Transport Buttons (Video Scrubbing) */
QPushButton.transportBtn {
    background-color: #15151A;
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 5px;
    min-width: 28px;
    min-height: 26px;
    max-height: 26px;
    padding: 2px 6px;
    font-size: 11px;
    font-weight: 600;
    color: #CBD5E1;
}

QPushButton.transportBtn:hover {
    background-color: #1E1E26;
    border: 1px solid rgba(255, 255, 255, 0.14);
    color: #FFFFFF;
}

QPushButton.transportBtn:pressed {
    background-color: #111116;
    border: 1px solid rgba(255, 255, 255, 0.04);
}

/* ========================================================
   5. FORM INPUTS & SELECTORS
   ======================================================== */
QLineEdit, QSpinBox, QDoubleSpinBox, QComboBox {
    background-color: #15151A;
    color: #F4F5F7;
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 6px;
    padding: 4px 8px;
    font-size: 12px;
    min-height: 22px;
}

QLineEdit:focus, QSpinBox:focus, QDoubleSpinBox:focus, QComboBox:focus {
    border: 1px solid #C0000A;
    background-color: #1A1A22;
}

QLineEdit:disabled, QSpinBox:disabled, QComboBox:disabled {
    background-color: rgba(255, 255, 255, 0.02);
    color: #555566;
    border-color: rgba(255, 255, 255, 0.04);
}

QComboBox::drop-down {
    subcontrol-origin: padding;
    subcontrol-position: top right;
    width: 22px;
    border-left: 1px solid rgba(255, 255, 255, 0.06);
}

QComboBox QAbstractItemView {
    background-color: #1A1A22;
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 6px;
    selection-background-color: #C0000A;
    selection-color: #FFFFFF;
    padding: 4px;
}

/* Checkbox */
QCheckBox {
    spacing: 8px;
    color: #CBD5E1;
    font-size: 12px;
}

QCheckBox::indicator {
    width: 16px;
    height: 16px;
    border-radius: 4px;
    border: 1px solid rgba(255, 255, 255, 0.12);
    background-color: #15151A;
}

QCheckBox::indicator:hover {
    border-color: #C0000A;
}

QCheckBox::indicator:checked {
    background-color: #C0000A;
    border-color: #E31B23;
}

/* ========================================================
   6. SLIDERS & PROGRESS BARS
   ======================================================== */
QSlider::groove:horizontal {
    height: 5px;
    background: #15151A;
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 2px;
}

QSlider::sub-page:horizontal {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #FF4A3D, stop:1 #D92A20);
    border-radius: 2px;
}

QSlider::handle:horizontal {
    background: #FFFFFF;
    border: 2px solid #C0000A;
    width: 14px;
    margin-top: -5px;
    margin-bottom: -5px;
    border-radius: 7px;
}

QSlider::handle:horizontal:hover {
    background: #FF4A3D;
    border-color: #FFFFFF;
    width: 16px;
    margin-top: -6px;
    margin-bottom: -6px;
    border-radius: 8px;
}

QProgressBar {
    background-color: #15151A;
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 5px;
    text-align: center;
    color: #F4F5F7;
    font-size: 11px;
    font-weight: 600;
}

QProgressBar::chunk {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #FF4A3D, stop:1 #D92A20);
    border-radius: 4px;
}

/* ========================================================
   7. GROUP BOXES & SURFACES
   ======================================================== */
QGroupBox {
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 8px;
    margin-top: 14px;
    padding-top: 14px;
    font-weight: 700;
    font-size: 11px;
    color: #94A3B8;
}

QGroupBox::title {
    subcontrol-origin: margin;
    subcontrol-position: top left;
    padding: 0 6px;
    left: 10px;
    color: #F4F5F7;
}

/* ========================================================
   8. ULTRA-THIN 6PX SCROLLBARS (CFX TOKEN SPEC)
   ======================================================== */
QScrollBar:vertical {
    background: transparent;
    width: 6px;
    margin: 0;
    border-radius: 3px;
}

QScrollBar::handle:vertical {
    background: rgba(255, 255, 255, 0.12);
    border-radius: 3px;
    min-height: 24px;
}

QScrollBar::handle:vertical:hover {
    background: rgba(255, 255, 255, 0.25);
}

QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
    height: 0px;
}

QScrollBar:horizontal {
    background: transparent;
    height: 6px;
    margin: 0;
    border-radius: 3px;
}

QScrollBar::handle:horizontal {
    background: rgba(255, 255, 255, 0.12);
    border-radius: 3px;
    min-width: 24px;
}

QScrollBar::handle:horizontal:hover {
    background: rgba(255, 255, 255, 0.25);
}

QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal {
    width: 0px;
}

/* ========================================================
   9. TOOLTIPS & DIALOGS
   ======================================================== */
QToolTip {
    background-color: #1A1A22;
    color: #F4F5F7;
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 6px;
    padding: 5px 9px;
    font-size: 11px;
    font-family: 'Nunito', 'Segoe UI', sans-serif;
}

/* ========================================================
   10. STATUS BAR & SPLITTERS
   ======================================================== */
QStatusBar {
    background-color: #0D0D11;
    border-top: 1px solid rgba(255, 255, 255, 0.06);
    color: #94A3B8;
    font-size: 11px;
    min-height: 24px;
}

QStatusBar QLabel {
    background: transparent;
    padding: 1px 6px;
}

QSplitter::handle {
    background-color: rgba(255, 255, 255, 0.06);
}
"""
