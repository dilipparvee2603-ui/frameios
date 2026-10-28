import os
import json
import logging
from pathlib import Path

logger = logging.getLogger(__name__)

DEFAULT_CONFIG = {
    "default_output_dir": "",
    "use_default_output_dir": True,
    "use_video_folder": False,
    "export_format": "PNG",  # PNG, JPG, WEBP
    "jpeg_quality": 95,
    "naming_pattern": "{video_name}_frame_{frame:06d}",
    "recent_files": [],
    "step_large_frames": 10,
    "auto_open_folder": False,
    "copy_to_clipboard_on_export": False,
    "settings_expanded": False,
    "theme": "dark"
}

def get_config_dir() -> Path:
    """Return standard Windows AppData directory or local fallback."""
    appdata = os.environ.get("APPDATA")
    if appdata:
        config_dir = Path(appdata) / "FrameExporter"
    else:
        config_dir = Path.home() / ".frame_exporter"
    
    try:
        config_dir.mkdir(parents=True, exist_ok=True)
        return config_dir
    except Exception as e:
        logger.warning(f"Failed to create config dir {config_dir}: {e}. Using current directory.")
        return Path(".")

def get_config_file_path() -> Path:
    return get_config_dir() / "settings.json"

class ConfigManager:
    """Singleton manager for user settings and preferences."""
    _instance = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super(ConfigManager, cls).__new__(cls)
            cls._instance._load()
        return cls._instance

    def _load(self):
        self.data = dict(DEFAULT_CONFIG)
        self.config_path = get_config_file_path()
        if self.config_path.exists():
            try:
                with open(self.config_path, "r", encoding="utf-8") as f:
                    saved = json.load(f)
                    self.data.update(saved)
            except Exception as e:
                logger.error(f"Error loading config file {self.config_path}: {e}")

    def save(self):
        try:
            with open(self.config_path, "w", encoding="utf-8") as f:
                json.dump(self.data, f, indent=4)
        except Exception as e:
            logger.error(f"Error saving config file {self.config_path}: {e}")

    def get(self, key, default=None):
        return self.data.get(key, default if default is not None else DEFAULT_CONFIG.get(key))

    def set(self, key, value):
        self.data[key] = value
        self.save()

    def add_recent_file(self, filepath: str):
        if not filepath:
            return
        recents = [f for f in self.data.get("recent_files", []) if f != filepath]
        recents.insert(0, filepath)
        self.data["recent_files"] = recents[:10]
        self.save()
