"""Round 7 — PC Settings panel (issues 03/04/05/07)."""

from __future__ import annotations

import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

import customtkinter as ctk
import pytest

from pc_agent.gui.settings_panel import SettingsPanel


def _make_root() -> ctk.CTk:
    last_error: Exception | None = None
    for _ in range(3):
        try:
            root = ctk.CTk()
            break
        except Exception as exc:  # pragma: no cover - display dependent
            last_error = exc
            time.sleep(0.2)
    else:  # pragma: no cover - display dependent
        pytest.skip(f"Tk unavailable: {last_error}")
    root.withdraw()
    return root


def _pump_until(condition: Callable[[], bool], timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.01)
    return condition()


def _row(
    connection_id: str = "c1",
    *,
    name: str = "Tablet",
    canvas: str | None = "cv-1",
    mirrored: bool = False,
) -> dict:
    return {
        "connection_id": connection_id,
        "device_id": f"dev-{connection_id}",
        "name": name,
        "peer": "10.0.0.5:1111",
        "open_canvas_id": canvas,
        "open_canvas_title": "Alpha" if canvas else None,
        "mirrored": mirrored,
        "last_seen": 1760760000,
    }


@pytest.fixture()
def root() -> Any:
    widget = _make_root()
    try:
        yield widget
    finally:
        try:
            widget.destroy()
        except Exception:
            pass


def test_empty_state_explains_how_to_pair(root: Any) -> None:
    panel = SettingsPanel(root)
    assert panel.device_rows == []
    assert panel._empty_label is not None
    assert panel._empty_label.winfo_manager() == "pack"
    assert "scan the pairing QR" in str(panel._empty_label.cget("text"))
    panel.close()


def test_rows_render_and_empty_hint_hides(root: Any) -> None:
    panel = SettingsPanel(root)
    panel.refresh_devices([_row("c1"), _row("c2", name="Phone", canvas=None)])
    assert len(panel.device_rows) == 2
    assert panel._empty_label.winfo_manager() == ""
    labels = [
        child for child in panel._devices_frame.winfo_children()
    ]
    assert len(labels) == 2
    panel.close()


def test_mirrored_row_preselects_its_canvas(root: Any) -> None:
    panel = SettingsPanel(root)
    panel.refresh_devices(
        [_row("c1", mirrored=True), _row("c2", canvas="cv-2")], "cv-1"
    )
    assert panel.mirrored_selection == "cv-1"
    panel.close()


def test_selecting_a_row_invokes_the_mirror_callback(root: Any) -> None:
    picked: list[str | None] = []
    panel = SettingsPanel(root, select_mirror=picked.append)
    panel.refresh_devices([_row("c1"), _row("c2", canvas="cv-2")], "cv-1")

    panel.select_mirror("cv-2")
    assert picked == ["cv-2"]
    assert panel.mirrored_selection == "cv-2"
    panel.close()


def test_mirror_callback_failure_is_contained(root: Any) -> None:
    def boom(_value: str | None) -> None:
        raise RuntimeError("hub down")

    panel = SettingsPanel(root, select_mirror=boom)
    panel.refresh_devices([_row("c1")], "cv-1")
    panel.select_mirror("cv-1")  # must not raise into the Tk callback
    panel.close()


def test_export_folder_is_persisted_and_displayed(root: Any, tmp_path: Path) -> None:
    saved: list[Path] = []
    panel = SettingsPanel(root, set_export_dir=saved.append, export_dir=tmp_path)
    assert str(tmp_path) in str(panel._export_label.cget("text"))

    target = tmp_path / "exports"
    assert panel.set_export_dir(target) == target
    assert saved == [target]
    assert str(target) in str(panel._export_label.cget("text"))
    panel.close()


def test_choose_export_dir_uses_the_folder_picker(
    root: Any, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    saved: list[Path] = []
    panel = SettingsPanel(root, set_export_dir=saved.append, export_dir=tmp_path)
    target = tmp_path / "picked"
    monkeypatch.setattr(
        "pc_agent.gui.settings_panel.filedialog.askdirectory",
        lambda **kwargs: str(target),
    )
    assert panel.choose_export_dir() == target
    assert saved == [target]
    panel.close()


def test_choose_export_dir_cancelled_changes_nothing(
    root: Any, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    saved: list[Path] = []
    panel = SettingsPanel(root, set_export_dir=saved.append, export_dir=tmp_path)
    monkeypatch.setattr(
        "pc_agent.gui.settings_panel.filedialog.askdirectory", lambda **kwargs: ""
    )
    assert panel.choose_export_dir() is None
    assert saved == []
    panel.close()


def test_reset_pairing_invokes_the_rotation(root: Any) -> None:
    calls: list[int] = []
    panel = SettingsPanel(root, rotate_pairing=lambda: calls.append(1))
    panel._reset_btn.invoke()
    assert calls == [1]
    panel.close()


def test_close_invokes_the_close_callback_once(root: Any) -> None:
    closed: list[int] = []
    panel = SettingsPanel(root, on_close=lambda: closed.append(1))
    panel.close()
    assert closed == [1]
    assert not panel.exists()


def test_rows_without_a_canvas_disable_their_radio(root: Any) -> None:
    panel = SettingsPanel(root)
    panel.refresh_devices([_row("c1", canvas=None)], None)
    assert panel.mirrored_selection is None
    assert _pump_until(lambda: True)  # plumbing stays responsive
    panel.close()
