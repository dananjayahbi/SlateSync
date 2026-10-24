"""Round 7 — ``DeviceRoster`` (issues 03/04/07: devices + mirrored canvas)."""

from __future__ import annotations

from pc_agent.core.events import DEVICES_UPDATED, MIRROR_CHANGED, EventBus
from pc_agent.network.device_roster import DeviceRoster


class _Recorder:
    def __init__(self, bus: EventBus) -> None:
        self.devices: list[dict] = []
        self.mirror: list[dict] = []
        bus.on(DEVICES_UPDATED, lambda **payload: self.devices.append(payload))
        bus.on(MIRROR_CHANGED, lambda **payload: self.mirror.append(payload))


def _roster() -> tuple[DeviceRoster, _Recorder]:
    bus = EventBus()
    return DeviceRoster(bus), _Recorder(bus)


def test_attach_detach_tracks_connected_devices() -> None:
    roster, _ = _roster()
    roster.attach("c1", "10.0.0.5:1111")
    roster.attach("c2", "10.0.0.6:2222")
    assert roster.count == 2
    assert roster.connection_for_canvas("anything") is None
    session = roster.get("c1")
    assert session is not None and session.peer == "10.0.0.5:1111"

    roster.detach("c1")
    assert roster.count == 1
    roster.detach("c1")  # second detach is a no-op
    assert roster.count == 1
    assert roster.get("c1") is None


def test_first_open_becomes_the_mirror_and_others_do_not_steal_it() -> None:
    roster, rec = _roster()
    roster.attach("c1", "a:1")
    roster.attach("c2", "b:2")

    assert roster.note_open("c1", "cv-1", "Alpha") is True
    assert roster.mirrored_canvas_id == "cv-1"
    assert roster.mirrored_title() == "Alpha"

    # Issue 07: the second device opening a different canvas must NOT switch.
    assert roster.note_open("c2", "cv-2", "Beta") is False
    assert roster.mirrored_canvas_id == "cv-1"

    roster.emit_mirror()
    assert rec.mirror == [{"canvas_id": "cv-1", "title": "Alpha", "connection_id": "c1"}]


def test_mirror_survives_its_owner_disconnecting() -> None:
    """The mirror is a canvas: a dropped tablet must not blank the PC view."""
    roster, _ = _roster()
    roster.attach("c1")
    roster.note_open("c1", "cv-1", "Alpha")
    assert roster.mirrored_canvas_id == "cv-1"

    roster.detach("c1")
    assert roster.mirrored_canvas_id == "cv-1"
    assert roster.select_mirror(None) is True  # the user can still clear it
    assert roster.mirrored_canvas_id is None


def test_note_open_adopts_the_connection_of_an_already_mirrored_canvas() -> None:
    """The local OPEN_CANVAS handler selects first; RPC_ORIGIN names the sender."""
    roster, _ = _roster()
    roster.attach("c1")
    assert roster.note_open(None, "cv-1", "Alpha") is True
    assert roster.note_open("c1", "cv-1", "Alpha") is False
    roster.emit_mirror()
    # Source adopted, so the session row is attributed to the right device.
    assert roster.roster()[0]["open_canvas_id"] == "cv-1"


def test_select_mirror_switches_and_emits() -> None:
    roster, rec = _roster()
    roster.attach("c1")
    roster.attach("c2")
    roster.note_open("c1", "cv-1", "Alpha")
    roster.note_open("c2", "cv-2", "Beta")

    assert roster.select_mirror("cv-2", "Beta") is True
    assert roster.mirrored_canvas_id == "cv-2"
    assert roster.select_mirror("cv-2", "Beta") is False  # unchanged

    roster.emit_mirror()
    assert rec.mirror[-1] == {
        "canvas_id": "cv-2",
        "title": "Beta",
        "connection_id": "c2",
    }

    assert roster.select_mirror(None) is True
    assert roster.mirrored_canvas_id is None


def test_roster_rows_carry_the_frozen_shape_and_mirrored_flag() -> None:
    roster, rec = _roster()
    roster.attach("c1", "a:1")
    roster.identify("c1", device_id="dev-1", name="Pixel Tablet")
    roster.note_open("c1", "cv-1", "Alpha")
    roster.attach("c2", "b:2")
    roster.note_open("c2", "cv-2", "Beta")

    roster.emit_devices()
    payload = rec.devices[-1]
    assert payload["count"] == 2
    assert payload["mirrored_canvas_id"] == "cv-1"
    rows = payload["devices"]
    assert [row["connection_id"] for row in rows] == ["c1", "c2"]
    assert set(rows[0]) == {
        "connection_id", "device_id", "name", "peer",
        "open_canvas_id", "open_canvas_title", "mirrored", "last_seen",
    }
    assert rows[0]["name"] == "Pixel Tablet"
    assert rows[0]["mirrored"] is True
    assert rows[1]["mirrored"] is False


def test_label_falls_back_name_device_id_peer_connection() -> None:
    roster, _ = _roster()
    session = roster.attach("c1", "a:1")
    assert session.label == "a:1"
    roster.identify("c1", device_id="dev-1")
    assert roster.get("c1").label == "dev-1"
    roster.identify("c1", name="Tablet")
    assert roster.get("c1").label == "Tablet"


def test_identify_and_touch_ignore_unknown_connections() -> None:
    roster, _ = _roster()
    roster.identify("missing", device_id="x", name="y")  # no raise
    roster.touch("missing")
    roster.touch(None)
    assert roster.count == 0
    assert roster.get(None) is None
