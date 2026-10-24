"""Frozen configuration contracts (Doc 04): ``AppConfig`` + ``ConfigManager``."""

from __future__ import annotations

import json
import logging
import os
from dataclasses import asdict, dataclass, field, fields
from pathlib import Path

logger = logging.getLogger(__name__)

_PC_AGENT_DIR = Path(__file__).resolve().parent.parent

_PATH_FIELDS = frozenset({"shader_dir", "assets_dir", "export_dir", "appdata_dir"})


def _default_shader_dir() -> Path:
    """``<repo>/pc_agent/viewport/shaders`` (Docs 06/07/08 populate it)."""
    return _PC_AGENT_DIR / "viewport" / "shaders"


def _default_appdata_dir() -> Path:
    """``%APPDATA%/SlateSync`` — ConfigManager's default root (Doc 04 §4)."""
    return Path(os.environ.get("APPDATA", str(Path.home()))) / "SlateSync"


def default_export_dir() -> Path:
    """User-facing export destination: the OS Downloads folder.

    Exports are deliverables the user shares/sends, so they land where every
    browser and app already puts downloads instead of a hidden appdata
    subfolder. Settings → Export folder overrides it per install.
    """
    return Path.home() / "Downloads"


@dataclass
class AppConfig:
    ws_port: int = 50606
    mdns_service_type: str = "_slatesync._tcp.local."
    mdns_service_name: str = "SlateSync"
    autosave_interval_s: float = 10.0
    # Template §4 declares the four Path fields without defaults; a dataclass
    # cannot place non-default fields after defaulted ones, so they get
    # default_factories that reproduce the template's documented targets.
    shader_dir: Path = field(default_factory=_default_shader_dir)
    assets_dir: Path = field(default_factory=lambda: _default_appdata_dir() / "assets")
    #: Export destination. Defaults to the OS Downloads folder (Settings →
    #: Export folder overrides it); see :func:`default_export_dir`.
    export_dir: Path = field(default_factory=default_export_dir)
    appdata_dir: Path = field(default_factory=_default_appdata_dir)
    log_level: str = "INFO"


class ConfigManager:
    """Loads on init and persists ``<root>/config.json`` (Doc 04 §4)."""

    def __init__(self, root_dir: Path | None = None) -> None:
        if root_dir is None:
            root_dir = _default_appdata_dir()
        self._root_dir = Path(root_dir)
        self._config = self._defaults()
        self.load()

    @property
    def config(self) -> AppConfig:
        return self._config

    @property
    def _config_path(self) -> Path:
        return self._root_dir / "config.json"

    def _defaults(self) -> AppConfig:
        return AppConfig(
            assets_dir=self._root_dir / "assets",
            export_dir=default_export_dir(),
            appdata_dir=self._root_dir,
        )

    # ------------------------------------------------------------------
    # Runtime settings (round 7 — Settings panel)
    # ------------------------------------------------------------------
    def update(self, **changes: object) -> AppConfig:
        """Apply + persist field overrides; returns the new config.

        ``AppConfig`` is mutable on purpose: the Settings panel changes
        ``export_dir`` while the coordinator holds the same instance, so the
        next export job writes to the freshly picked folder without a restart.
        Unknown keys or invalid values raise ``ValueError``/``TypeError``
        before anything is persisted.
        """
        config = self._config
        for key, value in changes.items():
            if not hasattr(config, key):
                raise ValueError(f"unknown config field: {key}")
            coerced = self._coerce(key, value)
            try:
                setattr(config, key, coerced)
            except (TypeError, ValueError) as exc:  # pragma: no cover - defensive
                raise ValueError(f"cannot set {key}: {exc}") from exc
        self._write()
        return config

    def set_export_dir(self, path: str | Path) -> Path:
        """Persist the export folder; created on demand by the coordinator."""
        target = Path(path).expanduser()
        self.update(export_dir=target)
        return target

    def load(self) -> None:
        """Read ``<root>/config.json``; missing/invalid falls back to defaults.

        Never raises: absent or corrupted files are (re)written with defaults.
        """
        path = self._config_path
        try:
            raw = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            self._config = self._defaults()
            self._write()
            return
        except OSError as exc:
            logger.warning("Cannot read %s (%s); using defaults", path, exc)
            self._config = self._defaults()
            return
        try:
            self._config = self._from_json(raw)
        except (TypeError, ValueError) as exc:
            logger.warning("Invalid config %s (%s); using defaults", path, exc)
            self._config = self._defaults()
            self._write()

    def save(self) -> None:
        """Write ``<root>/config.json`` as indented JSON, creating parent dirs."""
        path = self._config_path
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            name: str(value) if isinstance(value, Path) else value
            for name, value in asdict(self._config).items()
        }
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    def _write(self) -> None:
        try:
            self.save()
        except OSError as exc:
            logger.warning("Cannot persist %s (%s)", self._config_path, exc)

    def _from_json(self, raw: str) -> AppConfig:
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise TypeError("config root must be a JSON object")
        known = {f.name for f in fields(AppConfig)}
        merged = asdict(self._defaults())
        for key, value in data.items():
            if key in known:
                merged[key] = self._coerce(key, value)
        return AppConfig(**merged)

    @staticmethod
    def _coerce(key: str, value: object) -> object:
        if key in _PATH_FIELDS:
            # Round 7: runtime setters (Settings → export folder) pass ``Path``
            # objects, while config.json only ever holds strings.
            if isinstance(value, Path):
                return value
            if not isinstance(value, str):
                raise ValueError(f"{key} must be a path string")
            return Path(value)
        if key == "ws_port":
            if isinstance(value, bool) or not isinstance(value, int):
                raise ValueError("ws_port must be an integer")
            return value
        if key == "autosave_interval_s":
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise ValueError("autosave_interval_s must be a number")
            return float(value)
        if not isinstance(value, str):
            raise ValueError(f"{key} must be a string")
        return value
