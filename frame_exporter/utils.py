import os
import re
import subprocess
from pathlib import Path
from typing import Tuple

def sanitize_filename(name: str) -> str:
    """Strip or replace invalid Windows filename characters."""
    return re.sub(r'[\\/*?:"<>|]', '_', name)

def frames_to_timecode(frame_idx: int, fps: float) -> str:
    """Format frame index into standard HH:MM:SS.mmm timecode."""
    if fps <= 0:
        return "00:00:00.000"
    
    total_seconds = frame_idx / fps
    hours = int(total_seconds // 3600)
    minutes = int((total_seconds % 3600) // 60)
    seconds = int(total_seconds % 60)
    milliseconds = int(round((total_seconds - int(total_seconds)) * 1000))
    if milliseconds >= 1000:
        milliseconds = 999
    
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}.{milliseconds:03d}"

def frames_to_smpte(frame_idx: int, fps: float) -> str:
    """Format frame index into SMPTE timecode HH:MM:SS:FF."""
    if fps <= 0:
        return "00:00:00:00"
    
    total_seconds = int(frame_idx // fps)
    rem_frame = int(round(frame_idx % fps))
    hours = total_seconds // 3600
    minutes = (total_seconds % 3600) // 60
    seconds = total_seconds % 60
    
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}:{rem_frame:02d}"

def timecode_to_frames(tc_str: str, fps: float) -> int:
    """
    Parse timecode string into frame number.
    Supports:
      - SMPTE 'HH:MM:SS:FF' (4 colon-separated parts)
      - Standard 'HH:MM:SS.mmm' (3 parts with decimal seconds)
      - Short 'MM:SS.mmm' or 'MM:SS' (2 parts)
      - Pure seconds 'SS.mmm' (1 part with float)
      - Pure integer frame number '1234'
    """
    if not tc_str or fps <= 0:
        return 0
    
    tc_str = tc_str.strip()
    
    # Try plain integer frame
    if tc_str.isdigit():
        return int(tc_str)
        
    parts = tc_str.split(':')
    try:
        if len(parts) == 4:
            # HH:MM:SS:FF SMPTE format
            h = int(parts[0])
            m = int(parts[1])
            s = int(parts[2])
            f = int(parts[3])
            total_sec = h * 3600 + m * 60 + s
            return int(round(total_sec * fps)) + f
        elif len(parts) == 3:
            h = float(parts[0])
            m = float(parts[1])
            s = float(parts[2])
            total_sec = h * 3600 + m * 60 + s
            return int(round(total_sec * fps))
        elif len(parts) == 2:
            m = float(parts[0])
            s = float(parts[1])
            total_sec = m * 60 + s
            return int(round(total_sec * fps))
        elif len(parts) == 1:
            total_sec = float(parts[0])
            return int(round(total_sec * fps))
    except (ValueError, TypeError):
        pass
    return 0

def format_file_size(size_bytes: int) -> str:
    """Format raw byte size into human readable string (KB, MB)."""
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    else:
        return f"{size_bytes / (1024 * 1024):.2f} MB"

def generate_output_filename(video_path: str, frame_idx: int, fps: float, width: int, height: int,
                             template: str = "{video_name}_frame_{frame:06d}", ext: str = "png") -> str:
    """Generate output filename using template placeholders."""
    video_stem = Path(video_path).stem if video_path else "frame"
    tc_clean = frames_to_timecode(frame_idx, fps).replace(":", "-").replace(".", "_")
    
    data = {
        "video_name": video_stem,
        "frame": frame_idx,
        "timecode": tc_clean,
        "width": width,
        "height": height,
        "resolution": f"{width}x{height}",
        "fps": f"{fps:.2f}"
    }
    
    try:
        base_name = template.format(**data)
    except Exception:
        base_name = f"{video_stem}_frame_{frame_idx:06d}"
        
    base_name = sanitize_filename(base_name)
    ext = ext.lstrip('.').lower()
    return f"{base_name}.{ext}"

def open_in_explorer(target_path: str):
    """Open Windows Explorer and highlight the file or open the folder."""
    if not target_path:
        return
        
    p = Path(target_path)
    if not p.exists():
        # Fallback to parent if file doesn't exist yet
        p = p.parent
        if not p.exists():
            return

    try:
        if p.is_file():
            # Use explorer /select,"path" to highlight the file
            subprocess.run(["explorer", f"/select,{str(p.resolve())}"], check=False)
        else:
            os.startfile(str(p.resolve()))
    except Exception as e:
        # Fallback
        try:
            os.startfile(str(p.parent if p.is_file() else p))
        except Exception:
            pass
