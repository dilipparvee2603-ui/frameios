import os
import cv2
import threading
import numpy as np
import logging
from pathlib import Path
from collections import OrderedDict
from typing import Optional, Tuple, Dict, Any, List

logger = logging.getLogger(__name__)

class VideoEngine:
    """Handles video opening, high-precision frame navigation, caching, and lossless frame export."""
    
    def __init__(self, cache_size: int = 120):
        self.video_path: Optional[str] = None
        self.cap: Optional[cv2.VideoCapture] = None
        
        # Video properties
        self.width: int = 0
        self.height: int = 0
        self.fps: float = 0.0
        self.total_frames: int = 0
        self.duration_sec: float = 0.0
        
        # State
        self.current_frame_idx: int = 0
        self.last_decoded_frame: Optional[np.ndarray] = None
        self.in_point: Optional[int] = None
        self.out_point: Optional[int] = None
        self.scene_cuts: List[int] = []
        
        # LRU Frame Cache & Thread-Safe RAM Pre-Render Buffer
        self.cache_size = cache_size
        self.cache_limit_mb = 3072  # 3 GB RAM cache by default for high-speed playback
        self._cache_lock = threading.Lock()
        self.frame_cache: OrderedDict[int, np.ndarray] = OrderedDict()

        # Full-video GPU-accelerated pre-rendered preview stream
        self.preview_path: Optional[str] = None
        self.preview_cap: Optional[cv2.VideoCapture] = None
        self.preview_frame_idx: int = -1
        self._is_prefetching: bool = False

    def set_cache_limit_mb(self, mb: int):
        """Set maximum RAM memory buffer in megabytes for pre-rendering."""
        self.cache_limit_mb = max(256, mb)

    def _get_max_cache_size(self) -> int:
        """Dynamic cache sizing based on video resolution and allocated RAM limit."""
        frame_bytes = self.width * self.height * 3
        if frame_bytes > 0:
            allowed = int((self.cache_limit_mb * 1024 * 1024) / frame_bytes)
            return max(24, allowed)
        return self.cache_size

    def put_frame_in_cache(self, frame_idx: int, frame: np.ndarray):
        """Thread-safe method to store pre-rendered frame at 100% full original quality."""
        self._put_cache(frame_idx, frame)

    @property
    def has_preview_stream(self) -> bool:
        """True if an entire-video GPU-accelerated preview stream is active."""
        return self.preview_cap is not None and self.preview_cap.isOpened()

    def set_preview_stream(self, filepath: str) -> bool:
        """Attach an entire-video GPU hardware-accelerated preview stream."""
        if not filepath or not os.path.exists(filepath):
            return False

        if self.preview_cap is not None:
            self.preview_cap.release()
            self.preview_cap = None

        cap = None
        try:
            if hasattr(cv2, 'CAP_PROP_HW_ACCELERATION') and hasattr(cv2, 'VIDEO_ACCELERATION_ANY'):
                cap = cv2.VideoCapture(
                    filepath,
                    cv2.CAP_FFMPEG,
                    [cv2.CAP_PROP_HW_ACCELERATION, cv2.VIDEO_ACCELERATION_ANY]
                )
        except Exception:
            cap = None

        if cap is None or not cap.isOpened():
            cap = cv2.VideoCapture(filepath)

        if not cap.isOpened():
            return False

        self.preview_cap = cap
        self.preview_path = filepath
        self.preview_frame_idx = -1
        return True

    def remove_preview_stream(self):
        """Release and clean up preview stream."""
        if self.preview_cap is not None:
            self.preview_cap.release()
            self.preview_cap = None
        if self.preview_path and os.path.exists(self.preview_path):
            try:
                os.remove(self.preview_path)
            except Exception:
                pass
        self.preview_path = None
        self.preview_frame_idx = -1

    def clear_cache(self):
        """Clear all cached frames from RAM and remove pre-rendered preview streams."""
        with self._cache_lock:
            self.frame_cache.clear()
        self.remove_preview_stream()

    def trigger_adjacent_prefetch(self, center_idx: int):
        """Proactively pre-fetch adjacent next/previous frames in background for 0ms arrow stepping."""
        if not self.is_loaded or self.has_preview_stream:
            return
        if self._is_prefetching:
            return

        needed = [i for i in range(center_idx + 1, min(self.total_frames, center_idx + 4)) if i not in self.frame_cache]
        if not needed:
            return

        self._is_prefetching = True

        def _prefetch_task():
            try:
                cap = cv2.VideoCapture(self.video_path)
                if not cap.isOpened():
                    return
                cap.set(cv2.CAP_PROP_POS_FRAMES, needed[0])
                for f_idx in needed:
                    ret, f = cap.read()
                    if ret and f is not None:
                        self.put_frame_in_cache(f_idx, f)
                    else:
                        break
                cap.release()
            except Exception:
                pass
            finally:
                self._is_prefetching = False

        threading.Thread(target=_prefetch_task, daemon=True).start()

    def get_cached_ranges(self) -> List[Tuple[int, int]]:
        """Return list of (start_frame, end_frame) segments currently pre-rendered."""
        if self.has_preview_stream:
            return [(0, max(0, self.total_frames - 1))]
        with self._cache_lock:
            if not self.frame_cache:
                return []
            sorted_indices = sorted(self.frame_cache.keys())
            
        ranges = []
        range_start = sorted_indices[0]
        prev = sorted_indices[0]
        for idx in sorted_indices[1:]:
            if idx == prev + 1:
                prev = idx
            else:
                ranges.append((range_start, prev))
                range_start = idx
                prev = idx
        ranges.append((range_start, prev))
        return ranges

    @property
    def is_loaded(self) -> bool:
        return self.cap is not None and self.cap.isOpened()

    def open(self, filepath: str) -> bool:
        """Open a video file and initialize metadata with GPU hardware acceleration."""
        self.close()
        
        if not filepath or not os.path.exists(filepath):
            logger.error(f"File not found: {filepath}")
            return False
            
        # Check if video is 10-bit HDR / 10-bit HEVC (which OpenCV D3D11 corrupts into green noise)
        is_10bit = False
        try:
            from .ui.pre_render_dialog import find_ffmpeg_path
            import subprocess
            ff_bin = find_ffmpeg_path()
            p = subprocess.run([ff_bin, "-i", filepath], stderr=subprocess.PIPE, stdout=subprocess.DEVNULL, text=True, errors="ignore", timeout=1.0)
            if any(x in p.stderr for x in ("10le", "Main 10", "p010", "yuv420p10", "yuv422p10", "yuv444p10")):
                is_10bit = True
        except Exception:
            pass

        # Try hardware accelerated backend first (D3D11 / NVDEC / VAAPI) only for 8-bit video
        cap = None
        if not is_10bit:
            try:
                if hasattr(cv2, 'CAP_PROP_HW_ACCELERATION') and hasattr(cv2, 'VIDEO_ACCELERATION_ANY'):
                    hw_cap = cv2.VideoCapture(
                        filepath,
                        cv2.CAP_FFMPEG,
                        [cv2.CAP_PROP_HW_ACCELERATION, cv2.VIDEO_ACCELERATION_ANY]
                    )
                    if hw_cap is not None and hw_cap.isOpened():
                        # Validate that this specific video codec can actually be decoded cleanly by the GPU.
                        test_ret, test_frame = hw_cap.read()
                        if test_ret and test_frame is not None:
                            # Stride corruption check: OpenCV D3D11 on 10-bit/unsupported formats outputs
                            # bright neon green padding on the right edge ([0, ~135, 0] in BGR)
                            h_t, w_t = test_frame.shape[:2]
                            edge_sample = test_frame[:, -min(60, max(10, w_t // 20)):]
                            has_green_artifact = (
                                np.mean(edge_sample[:, :, 1]) > 50 and
                                np.mean(edge_sample[:, :, 0]) < 8 and
                                np.mean(edge_sample[:, :, 2]) < 8
                            )
                            if has_green_artifact:
                                hw_cap.release()
                                cap = None
                            else:
                                hw_cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                                cap = hw_cap
                        else:
                            hw_cap.release()
                            cap = None
            except Exception as e:
                logger.debug(f"Hardware acceleration init failed: {e}")
                cap = None

        if cap is None or not cap.isOpened():
            cap = cv2.VideoCapture(filepath)

        if not cap.isOpened():
            logger.error(f"OpenCV failed to open: {filepath}")
            return False
            
        self.cap = cap
        self.video_path = str(Path(filepath).resolve())
        
        self.width = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        self.height = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        
        fps = self.cap.get(cv2.CAP_PROP_FPS)
        # Handle invalid or 0 FPS
        if fps <= 0 or np.isnan(fps):
            fps = 24.0
        self.fps = fps
        
        total = int(self.cap.get(cv2.CAP_PROP_FRAME_COUNT))
        if total <= 0:
            # Fallback estimation or single frame
            total = 1
        self.total_frames = total
        self.duration_sec = self.total_frames / self.fps
        
        self.current_frame_idx = 0
        self.in_point = None
        self.out_point = None
        self.scene_cuts.clear()
        self.frame_cache.clear()
        
        # Read the first frame
        self.get_frame(0)
        return True

    def close(self):
        """Release video resources."""
        if self.cap is not None:
            self.cap.release()
            self.cap = None
        self.remove_preview_stream()
        self.video_path = None
        self.width = 0
        self.height = 0
        self.fps = 0.0
        self.total_frames = 0
        self.duration_sec = 0.0
        self.current_frame_idx = 0
        self.last_decoded_frame = None
        self.in_point = None
        self.out_point = None
        self.scene_cuts.clear()
        self.frame_cache.clear()

    def get_next_scene_cut(self, current_frame: int) -> Optional[int]:
        """Return next detected scene cut frame index after current_frame."""
        for cut in self.scene_cuts:
            if cut > current_frame:
                return cut
        return None

    def get_prev_scene_cut(self, current_frame: int) -> Optional[int]:
        """Return previous detected scene cut frame index before current_frame."""
        for cut in reversed(self.scene_cuts):
            if cut < current_frame:
                return cut
        return None

    def _put_cache(self, frame_idx: int, frame: np.ndarray):
        """Store frame in LRU cache."""
        with self._cache_lock:
            if frame_idx in self.frame_cache:
                self.frame_cache.move_to_end(frame_idx)
            else:
                limit = self._get_max_cache_size()
                while len(self.frame_cache) >= limit:
                    self.frame_cache.popitem(last=False)
                self.frame_cache[frame_idx] = frame

    def get_frame(self, target_idx: int) -> Optional[np.ndarray]:
        """Fetch frame at target_idx with caching, near-forward grab optimization, and precision positioning."""
        if not self.is_loaded:
            return None
            
        target_idx = max(0, min(target_idx, self.total_frames - 1))
        
        # Check cache first (thread-safe, 0ms latency if pre-rendered)
        with self._cache_lock:
            if target_idx in self.frame_cache:
                self.frame_cache.move_to_end(target_idx)
                self.current_frame_idx = target_idx
                self.last_decoded_frame = self.frame_cache[target_idx]
                return self.last_decoded_frame

        # Check full-video GPU hardware-accelerated preview stream if active!
        if self.has_preview_stream:
            # Fast sequential read
            if target_idx == self.preview_frame_idx + 1:
                ret, frame = self.preview_cap.read()
                if ret and frame is not None:
                    self.preview_frame_idx = target_idx
                    self.current_frame_idx = target_idx
                    self.last_decoded_frame = frame
                    self._put_cache(target_idx, frame)
                    return frame

            # Near-forward skip using grab
            if self.preview_frame_idx < target_idx <= self.preview_frame_idx + 5:
                for _ in range(target_idx - self.preview_frame_idx - 1):
                    if not self.preview_cap.grab():
                        break
                ret, frame = self.preview_cap.read()
                if ret and frame is not None:
                    self.preview_frame_idx = target_idx
                    self.current_frame_idx = target_idx
                    self.last_decoded_frame = frame
                    self._put_cache(target_idx, frame)
                    return frame

            # Accurate seek in preview stream
            self.preview_cap.set(cv2.CAP_PROP_POS_FRAMES, target_idx)
            ret, frame = self.preview_cap.read()
            if ret and frame is not None:
                self.preview_frame_idx = target_idx
                self.current_frame_idx = target_idx
                self.last_decoded_frame = frame
                self._put_cache(target_idx, frame)
                return frame

        # Fast path: If requesting next sequential frame from master video, read directly without seeking!
        if target_idx == self.current_frame_idx + 1:
            ret, frame = self.cap.read()
            if ret and frame is not None:
                self.current_frame_idx = target_idx
                self.last_decoded_frame = frame
                self._put_cache(target_idx, frame)
                return frame

        # Near-forward catch-up path (e.g. wall-clock skipped 1-5 frames due to system scheduling):
        # cap.grab() is ~7x faster than cap.set(POS_FRAMES) because it skips decompression
        if self.current_frame_idx < target_idx <= self.current_frame_idx + 5:
            for _ in range(target_idx - self.current_frame_idx - 1):
                if not self.cap.grab():
                    break
            ret, frame = self.cap.read()
            if ret and frame is not None:
                self.current_frame_idx = target_idx
                self.last_decoded_frame = frame
                self._put_cache(target_idx, frame)
                return frame

        # Backward step window batch caching:
        # Interframe / long-GOP codecs (AV1, H.264/HEVC) seek to the nearest preceding keyframe
        # and sequentially decode forward to the requested frame.
        # When user steps backward, batch-decode a small backward window [target_idx - 8 .. target_idx]
        # and store all decoded frames in frame_cache so all subsequent Left Arrow steps hit RAM in 0ms!
        if target_idx == self.current_frame_idx - 1 or (0 < self.current_frame_idx - target_idx <= 5):
            batch_start = max(0, target_idx - 8)
            self.cap.set(cv2.CAP_PROP_POS_FRAMES, batch_start)
            for f_i in range(batch_start, target_idx + 1):
                ret, frame = self.cap.read()
                if ret and frame is not None:
                    self._put_cache(f_i, frame)
                else:
                    break
            if target_idx in self.frame_cache:
                self.current_frame_idx = target_idx
                self.last_decoded_frame = self.frame_cache[target_idx]
                return self.last_decoded_frame

        # Otherwise, perform accurate seek
        self.cap.set(cv2.CAP_PROP_POS_FRAMES, target_idx)
        ret, frame = self.cap.read()
        if not ret or frame is None:
            # If at the very end or near boundary, try fallback
            if target_idx > 0:
                self.cap.set(cv2.CAP_PROP_POS_FRAMES, target_idx - 1)
                ret, frame = self.cap.read()
        
        if ret and frame is not None:
            self.current_frame_idx = target_idx
            self.last_decoded_frame = frame
            self._put_cache(target_idx, frame)
            return frame
            
        return self.last_decoded_frame

    def step(self, delta_frames: int) -> Optional[np.ndarray]:
        """Step relative number of frames (e.g. +1, -1, +10, -10)."""
        new_idx = self.current_frame_idx + delta_frames
        return self.get_frame(new_idx)

    def save_frame_to_file(self, frame: np.ndarray, output_path: str, format_ext: str = "PNG", quality: int = 95) -> Tuple[bool, str, int]:
        """Save a pre-acquired BGR frame array to disk without touching video engine state."""
        out_file = Path(output_path)
        out_file.parent.mkdir(parents=True, exist_ok=True)
        
        ext = format_ext.lower().strip('.')
        if ext in ("jpg", "jpeg"):
            encode_ext = ".jpg"
            params = [cv2.IMWRITE_JPEG_QUALITY, max(1, min(100, quality))]
        elif ext == "webp":
            encode_ext = ".webp"
            params = [cv2.IMWRITE_WEBP_QUALITY, max(1, min(100, quality))]
        elif ext == "bmp":
            encode_ext = ".bmp"
            params = []
        elif ext in ("tiff", "tif"):
            encode_ext = ".tiff"
            params = []
        else: # PNG default - lossless
            encode_ext = ".png"
            params = [cv2.IMWRITE_PNG_COMPRESSION, 1]

        try:
            success, encoded_img = cv2.imencode(encode_ext, frame, params)
            if not success:
                return False, f"Encoding failed", 0
                
            with open(out_file, "wb") as f:
                f.write(encoded_img.tobytes())
                
            file_size = out_file.stat().st_size
            return True, str(out_file.resolve()), file_size
        except Exception as e:
            logger.error(f"Failed to export frame to {output_path}: {e}")
            return False, str(e), 0

    def export_frame(self, frame_idx: Optional[int], output_path: str, format_ext: str = "PNG", quality: int = 95) -> Tuple[bool, str, int]:
        """
        Export frame at ORIGINAL resolution.
        Returns: (success: bool, saved_filepath: str, file_size_bytes: int)
        """
        if not self.is_loaded:
            return False, "No video loaded", 0
            
        if frame_idx is None:
            frame_idx = self.current_frame_idx
            
        # Use existing in-memory frame if available to avoid desynchronizing decoder position
        frame = None
        if frame_idx == self.current_frame_idx and self.last_decoded_frame is not None:
            frame = self.last_decoded_frame
        elif frame_idx in self.frame_cache:
            frame = self.frame_cache[frame_idx]
        else:
            frame = self.get_frame(frame_idx)

        if frame is None:
            return False, f"Could not read frame {frame_idx}", 0

        return self.save_frame_to_file(frame, output_path, format_ext, quality)

    def get_info(self) -> Dict[str, Any]:
        """Return video metadata dictionary."""
        return {
            "path": self.video_path,
            "filename": Path(self.video_path).name if self.video_path else "",
            "width": self.width,
            "height": self.height,
            "fps": self.fps,
            "total_frames": self.total_frames,
            "duration_sec": self.duration_sec,
            "current_frame": self.current_frame_idx,
            "in_point": self.in_point,
            "out_point": self.out_point
        }
