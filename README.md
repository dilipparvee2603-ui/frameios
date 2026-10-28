# Frame Exporter for Windows 🎬

A modern, high-performance desktop application for Windows to inspect videos, navigate frame-by-frame with arrow keys, and extract frames at **100% original resolution**.

---

## ✨ Features

- **Import Any Video Format**: Drag and drop or browse MP4, MKV, MOV, AVI, WEBM, FLV, WMV, TS, etc.
- **Precision Frame-by-Frame Scrubbing**:
  - `←` Left Arrow: Step backward 1 frame
  - `→` Right Arrow: Step forward 1 frame
  - `Shift + ←` / `Shift + →`: Step 10 frames back / forward
  - `Ctrl + ←` / `Ctrl + →`: Jump 1 second back / forward
  - Smooth interactive timeline slider with live timecode & frame number hover tooltips.
- **100% Original Resolution Extraction**:
  - Frames are extracted directly from native video frames at true pixel dimensions (e.g. 1080p, 4K, 8K) without downscaling or screen-capture degradation.
  - Supports **PNG** (lossless), **JPEG** (customizable quality 50-100%), and **WEBP**.
- **Default Output Folder Setting**:
  - Choose any output folder and click **`★ Set as Default Folder`** to persist your choice across app restarts.
  - Optional **"Save to video's folder"** toggle.
  - **"Open Folder"** button to jump straight to the exported files in Windows Explorer.
- **Interactive Detail Zoom & Pan**:
  - Mouse wheel to zoom in (up to 800%) to inspect fine focus before exporting.
  - Drag with mouse to pan around while zoomed.
  - Press `0` to Fit to Screen, `1` for 100% actual pixel size.
- **Quick Actions**:
  - One-click export button or press `E` / `Ctrl+S`.
  - **Dedicated Image Cropper Window** (`✂️ Crop` / `Ctrl+K`): Crop frames to **4:5**, **16:9**, **9:16**, **1:1**, or **Free** ratios at 100% original pixel quality!
  - Copy frame to clipboard (`Ctrl+C`) to paste directly into Photoshop or chat apps.
  - Batch / Range Export (`B`) to extract a sequence of frames or every *N* frames.

---

## 🚀 Quick Start

### 1. Launching the App
Double-click `run.bat` or run in terminal:
```bash
python main.py
```
*(You can also pass a video path directly, e.g.: `python main.py "path\to\video.mp4"`)*

### 2. Dependencies
If running on a fresh machine:
```bash
pip install -r requirements.txt
```

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| **`←` (Left Arrow)** | Step backward **1 frame** |
| **`→` (Right Arrow)** | Step forward **1 frame** |
| **`Shift + ←`** | Step backward **10 frames** |
| **`Shift + →`** | Step forward **10 frames** |
| **`Ctrl + ←`** | Jump backward **1 second** |
| **`Ctrl + →`** | Jump forward **1 second** |
| **`Spacebar`** | Play / Pause video playback |
| **`E` or `Ctrl + S`** | **Export current frame (Original Resolution)** |
| **`Ctrl + K`** | **Open Image Cropper in separate window (4:5, 16:9, 9:16, 1:1)** |
| **`Ctrl + C`** | Copy current frame to clipboard |
| **`Ctrl + O`** | Open video file |
| **`Home` / `End`** | Jump to start / end of video |
| **`I` / `O`** | Mark In-Point / Out-Point for batch range |
| **`B`** | Open Batch Export dialog |
| **`Mouse Wheel`** | Zoom in / out on video canvas |
| **`0`** | Fit image to window |
| **`1`** | 100% 1:1 Actual Pixel view |
| **`F11`** | Toggle Fullscreen |

---

## 📁 Output Folder Options

1. **Custom Default Folder**:
   - In the **Output Destination** section, click **Browse...** to pick your preferred folder.
   - Click **`★ Set as Default Folder`**. The software will remember this directory permanently in `settings.json`.
2. **Video's Folder Toggle**:
   - Check **"Save to video's folder"** to automatically save exported frames alongside the source video.
3. **Naming Customization**:
   - Customizable naming patterns such as `{video_name}_frame_{frame:06d}` or `{video_name}_{timecode}` with a live filename preview before saving.
