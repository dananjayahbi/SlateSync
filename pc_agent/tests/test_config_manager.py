"""Tests for AppConfig / ConfigManager (Doc 04 §6)."""

import json
import os
from pathlib import Path

from pc_agent.core.config_manager import AppConfig, ConfigManager


def test_first_run_creates_config_json(tmp_path: Path) -> None:
    ConfigManager(root_dir=tmp_path)
    config_file = tmp_path / "config.json"
    assert config_file.is_file()
    data = json.loads(config_file.read_text(encoding="utf-8"))
    assert data["ws_port"] == 50606
    assert data["mdns_service_type"] == "_slatesync._tcp.local."
    assert data["mdns_service_name"] == "SlateSync"
    assert data["autosave_interval_s"] == 10.0
    assert data["log_level"] == "INFO"
    assert data["appdata_dir"] == str(tmp_path)
    assert data["assets_dir"] == str(tmp_path / "assets")
    assert data["export_dir"] == str(tmp_path / "exports")


def test_master_constant_defaults() -> None:
    config = AppConfig()
    assert config.ws_port == 50606
    assert config.mdns_service_type == "_slatesync._tcp.local."
    assert config.mdns_service_name == "SlateSync"
    assert config.autosave_interval_s == 10.0
    assert config.log_level == "INFO"


def test_default_root_is_appdata_slate_sync() -> None:
    manager = ConfigManager()
    expected = Path(os.environ["APPDATA"]) / "SlateSync"
    assert manager.config.appdata_dir == expected
    assert (expected / "config.json").is_file()


def test_save_load_roundtrip_preserves_every_field(tmp_path: Path) -> None:
    custom = {
        "ws_port": 50607,
        "mdns_service_type": "_custom._tcp.local.",
        "mdns_service_name": "CustomSync",
        "autosave_interval_s": 2.5,
        "shader_dir": str(tmp_path / "shaders"),
        "assets_dir": str(tmp_path / "custom_assets"),
        "export_dir": str(tmp_path / "custom_exports"),
        "appdata_dir": str(tmp_path / "custom_root"),
        "log_level": "DEBUG",
    }
    (tmp_path / "config.json").write_text(json.dumps(custom), encoding="utf-8")

    manager = ConfigManager(root_dir=tmp_path)
    loaded = manager.config
    assert loaded == AppConfig(
        ws_port=50607,
        mdns_service_type="_custom._tcp.local.",
        mdns_service_name="CustomSync",
        autosave_interval_s=2.5,
        shader_dir=tmp_path / "shaders",
        assets_dir=tmp_path / "custom_assets",
        export_dir=tmp_path / "custom_exports",
        appdata_dir=tmp_path / "custom_root",
        log_level="DEBUG",
    )

    manager.save()
    reloaded = ConfigManager(root_dir=tmp_path).config
    assert reloaded == loaded
    # every field survives the JSON roundtrip
    for field_name, expected in custom.items():
        actual = getattr(reloaded, field_name)
        if field_name.endswith("_dir"):
            assert actual == Path(expected)
        else:
            assert actual == expected


def test_corrupted_json_falls_back_to_defaults(tmp_path: Path) -> None:
    (tmp_path / "config.json").write_text("{not valid json", encoding="utf-8")
    manager = ConfigManager(root_dir=tmp_path)  # must not raise
    assert manager.config.ws_port == 50606
    assert manager.config.log_level == "INFO"
    assert manager.config.autosave_interval_s == 10.0
    assert manager.config.appdata_dir == tmp_path
    # the corrupted file is rewritten with valid defaults
    data = json.loads((tmp_path / "config.json").read_text(encoding="utf-8"))
    assert data["ws_port"] == 50606


def test_wrong_typed_values_fall_back_to_defaults(tmp_path: Path) -> None:
    (tmp_path / "config.json").write_text(
        json.dumps({"ws_port": "not-an-int", "log_level": 42}), encoding="utf-8"
    )
    manager = ConfigManager(root_dir=tmp_path)  # must not raise
    assert manager.config.ws_port == 50606
    assert manager.config.log_level == "INFO"


def test_shader_dir_points_at_pc_agent_viewport_shaders(tmp_path: Path) -> None:
    manager = ConfigManager(root_dir=tmp_path)
    expected = Path(__file__).resolve().parents[1] / "viewport" / "shaders"
    assert manager.config.shader_dir == expected
