"""Round 7 — ``PairingStore`` (issue 04: the pairing QR is static)."""

from __future__ import annotations

import json
from pathlib import Path

from pc_agent.network.pairing_store import FILE_NAME, PairingIdentity, PairingStore


def test_first_load_mints_and_persists(tmp_path: Path) -> None:
    store = PairingStore(tmp_path)
    assert store.load() is None

    identity = store.load_or_create()
    assert store.path == tmp_path / FILE_NAME
    assert store.path.is_file()
    assert len(identity.token) >= 40
    data = json.loads(store.path.read_text(encoding="utf-8"))
    assert data["version"] == 1
    assert data["token"] == identity.token
    assert data["device_id"] == identity.device_id
    assert data["created_at"] == identity.created_at


def test_token_is_static_across_instances_on_the_same_profile(tmp_path: Path) -> None:
    """The whole point of issue 04: one scan pairs a device for good."""
    first = PairingStore(tmp_path).load_or_create()
    second = PairingStore(tmp_path).load_or_create()
    assert second.token == first.token
    assert second.device_id == first.device_id


def test_different_profiles_get_different_tokens(tmp_path: Path) -> None:
    a = PairingStore(tmp_path / "a").load_or_create()
    b = PairingStore(tmp_path / "b").load_or_create()
    assert a.token != b.token


def test_rotate_mints_a_new_token_and_persists(tmp_path: Path) -> None:
    store = PairingStore(tmp_path)
    original = store.load_or_create()
    rotated = store.rotate()
    assert rotated.token != original.token
    assert store.load().token == rotated.token


def test_corrupt_file_is_recreated_without_raising(tmp_path: Path) -> None:
    tmp_path.mkdir(parents=True, exist_ok=True)
    (tmp_path / FILE_NAME).write_text("not json", encoding="utf-8")
    identity = PairingStore(tmp_path).load_or_create()
    assert identity.token
    assert json.loads((tmp_path / FILE_NAME).read_text(encoding="utf-8"))["token"] == (
        identity.token
    )


def test_missing_token_key_is_treated_as_corrupt(tmp_path: Path) -> None:
    tmp_path.mkdir(parents=True, exist_ok=True)
    (tmp_path / FILE_NAME).write_text(json.dumps({"device_id": "x"}), encoding="utf-8")
    assert PairingStore(tmp_path).load() is None


def test_remember_qr_payload_is_write_once(tmp_path: Path) -> None:
    store = PairingStore(tmp_path)
    store.load_or_create()
    payload = "slatesync://connect?ip=192.168.1.5&port=50606&token=t"
    updated = store.remember_qr_payload(payload)
    assert updated.qr_payload == payload
    assert store.load().qr_payload == payload
    # Same payload again: no new identity, token unchanged.
    again = store.remember_qr_payload(payload)
    assert again.token == updated.token


def test_identity_round_trips_through_json() -> None:
    identity = PairingIdentity(
        token="tok", device_id="dev", device_name="PC", created_at=123, qr_payload="p"
    )
    restored = PairingIdentity.from_json(identity.to_json())
    assert restored == identity
    assert PairingIdentity.from_json({}) is None
    assert PairingIdentity.from_json("nope") is None
