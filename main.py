import sys
import os
from pathlib import Path
from PySide6.QtWidgets import QApplication
from PySide6.QtCore import Qt
from PySide6.QtGui import QIcon

from frame_exporter.ui.main_window import MainWindow
from frame_exporter.ui.cropper_window import ImageCropperWindow
from frame_exporter.ui.launcher_window import LauncherWindow, VIDEO_EXTENSIONS, IMAGE_EXTENSIONS
from frame_exporter.ui.styles import DARK_THEME_QSS

def get_resource_path(relative_path: str) -> str:
    """Get absolute path to resource, works for dev and for PyInstaller."""
    if hasattr(sys, '_MEIPASS'):
        return os.path.join(sys._MEIPASS, relative_path)
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), relative_path)

def main():
    # Enable High DPI pixmaps
    QApplication.setHighDpiScaleFactorRoundingPolicy(Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)

    app = QApplication(sys.argv)
    app.setApplicationName("Frame Studio")
    app.setOrganizationName("FrameStudio")
    app.setStyleSheet(DARK_THEME_QSS)

    ico_path = get_resource_path("app_icon.ico")
    if os.path.exists(ico_path):
        app.setWindowIcon(QIcon(ico_path))

    # If file was passed via CLI or "Open with" in Windows Explorer
    if len(sys.argv) > 1:
        arg_path = sys.argv[1]
        if os.path.exists(arg_path):
            ext = Path(arg_path).suffix.lower()
            if ext in IMAGE_EXTENSIONS:
                cropper = ImageCropperWindow()
                cropper.load_image_file(arg_path)
                cropper.show()
                sys.exit(app.exec())
            else:
                window = MainWindow()
                window.load_video(arg_path)
                window.show()
                sys.exit(app.exec())

    # Default entry point: Open Studio Launcher Hub
    launcher = LauncherWindow()
    launcher.show()
    sys.exit(app.exec())

if __name__ == "__main__":
    main()
