import sys
from PySide6.QtWidgets import QApplication

app = QApplication(sys.argv)
from frame_exporter.ui.styles import DARK_THEME_QSS
app.setStyleSheet(DARK_THEME_QSS)

from frame_exporter.ui.cropper_window import ImageCropperWindow
w = ImageCropperWindow()
w.btn_back.setText("← Back to Launcher")
w.btn_launcher.hide()
w.resize(1024, 720)
w.show()
app.processEvents()

pix = w.grab()
w.close()
pix.save("test_cropper_full.png")
pix.copy(0, 0, 1024, 80).save("test_cropper_topbar.png")
print("Saved local screenshots successfully")
