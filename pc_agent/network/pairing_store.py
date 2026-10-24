"""Persistent pairing identity — the one-time QR token (Doc 12 extension).

The pairing token used to be minted in memory on every launch, so the QR code
changed on each restart and a previously paired tablet could never reconnect
without re-scanning. ``PairingStore`` stores the identity in
``<appdata_dir>/pairing.json``::

    {
      "version": 1,
      "token": "<43-char urlsafe>",
      "device_id": "<hub uuid>",
      "device_name": "DESKTOP-XXXX",
      "created_at": 1760760000
    }

The token is created exactly once per install (atomic
``pairing.json.tmp`` → ``os.replace``) and reused forever after, so the QR
image is static: one scan pairs a device for good, and the tablet handshakes
with the saved token on every later launch.

Reads never raise: an unreadable file is logged and re-created with a new
token rather than blocking startup.
"""

from __future__ import annotations

import json
import logging
import os
import platform
import secrets
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)

FILE_NAME = "pairing.json"
_VERSION = 1
_TOKEN_BYTES = 32  # secrets.token_urlsafe(32) -> 43 chars, matches the old mint


@dataclass(frozen=True)
class PairingIdentity:
    """Stable pairing identity of this PC install (token never rotates)."""

    token: str
    device_id: str
    device_name: str
    created_at: int
    #: Hash-free copy of the last QR payload written to disk. Persisting it
    #: lets a restarted app skip re-encoding an identical PNG, so pairing_qr.png
    #: is genuinely written once per LAN/token change instead of per launch.
    qr_payload: str = ""

    def to_json(self) -> dict:
        return {
            "version": _VERSION,
            "token": self.token,
            "device_id": self.device_id,
            "device_name": self.device_name,
            "created_at": self.created_at,
            "qr_payload": self.qr_payload,
        }

    @classmethod
    def from_json(cls, data: object) -> "PairingIdentity | None":
        if not isinstance(data, dict):
            return None
        token = data.get("token")
        if not isinstance(token, str) or not token:
            return None
        device_id = data.get("device_id")
        created_at = data.get("created_at")
        device_name = data.get("device_name")
        qr_payload = data.get("qr_payload")
        return cls(
            token=token,
            device_id=(
                device_id if isinstance(device_id, str) and device_id
                else str(uuid.uuid4())
            ),
            device_name=(
                device_name
                if isinstance(device_name, str) and device_name
                else platform.node() or "SlateSync PC"
            ),
            created_at=created_at if isinstance(created_at, int) else int(time.time()),
            qr_payload=qr_payload if isinstance(qr_payload, str) else "",
        )


class PairingStore:
    """Load-or-create ``<appdata_dir>/pairing.json`` (see module doc)."""

    def __init__(self, appdata_dir: Path | str) -> None:
        self._dir = Path(appdata_dir)

    @property
    def path(self) -> Path:
        return self._dir / FILE_NAME

    def load(self) -> PairingIdentity | None:
        """Stored identity, or ``None`` when absent/corrupt (never raises)."""
        try:
            raw = self.path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return None
        except OSError as exc:
            logger.warning("cannot read %s (%s)", self.path, exc)
            return None
        try:
            return PairingIdentity.from_json(json.loads(raw))
        except (TypeError, ValueError) as exc:
            logger.warning("invalid pairing identity %s (%s); re-creating", self.path, exc)
            return None

    def load_or_create(self) -> PairingIdentity:
        """The persisted identity, minting + saving one on first run.

        This is what makes the QR code static: after the first launch the
        token is reused for every subsequent start of the app.
        """
        existing = self.load()
        if existing is not None:
            return existing
        identity = self._mint()
        self.save(identity)
        return identity

    def save(self, identity: PairingIdentity) -> None:
        """Atomic write (``.tmp`` → ``os.replace``); failures are logged."""
        target = self.path
        tmp = target.with_suffix(target.suffix + ".tmp")
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            tmp.write_text(
                json.dumps(identity.to_json(), indent=2) + "\n", encoding="utf-8"
            )
            os.replace(tmp, target)
        except OSError:
            logger.warning("cannot persist pairing identity to %s", target, exc_info=True)
            try:
                tmp.unlink(missing_ok=True)
            except OSError:
                pass

    def rotate(self) -> PairingIdentity:
        """Mint a fresh token (Settings → "Reset pairing"); the old one dies."""
        identity = self._mint()
        self.save(identity)
        return identity

    def remember_qr_payload(self, payload: str) -> PairingIdentity:
        """Record the payload already rendered to ``pairing_qr.png``.

        Keeps the PNG write-once: a later launch with the same token/ip/port
        sees the payload match and skips re-encoding entirely.
        """
        current = self.load()
        if current is None or current.qr_payload == payload:
            return current if current is not None else self.load_or_create()
        updated = PairingIdentity(
            token=current.token,
            device_id=current.device_id,
            device_name=current.device_name,
            created_at=current.created_at,
            qr_payload=payload,
        )
        self.save(updated)
        return updated

    @staticmethod
    def _mint() -> PairingIdentity:
        return PairingIdentity(
            token=secrets.token_urlsafe(_TOKEN_BYTES),
            device_id=str(uuid.uuid4()),
            device_name=platform.node() or "SlateSync PC",
            created_at=int(time.time()),
        )
