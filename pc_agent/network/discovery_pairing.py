"""Doc 12 — mDNS discovery & QR pairing service.

Binding spec: ``docs/micro/12_pc_mdns_qr_pairing_service.md`` + template §3/§4.
Mints the single session token enforced by Doc 11 (lazily, through the
injected ``token_provider``), announces ``_slatesync._tcp.local.`` via
``zeroconf`` with TXT ``{v:"1", token:<session_token>}``, and renders the
fallback pairing QR at ``<appdata_dir>/pairing_qr.png`` whose payload yields
the Doc 25 connect URL ``ws://<ipv4>:50606/ws?token=<session_token>``.

Round 7 — the token is no longer minted per process: it is loaded from (or
created once in) ``<appdata_dir>/pairing.json`` by :class:`PairingStore`, so
the QR payload is **static** across restarts. A device that paired once keeps
handshaking with the token it saved. The QR PNG is only re-rendered when the
payload actually changes (new IP / port / rotated token).
"""

from __future__ import annotations

import logging
import socket
from pathlib import Path

import qrcode
from zeroconf import ServiceInfo, Zeroconf

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import PAIRING_INFO, EventBus
from pc_agent.network.pairing_store import PairingIdentity, PairingStore

logger = logging.getLogger(__name__)

_QR_FILENAME = "pairing_qr.png"


def _pairing_payload(ip: str, port: int, token: str) -> str:
    """Frozen QR payload (template §4): query order fixed to ip, port, token."""
    return f"slatesync://connect?ip={ip}&port={port}&token={token}"


class DiscoveryPairing:
    """mDNS + QR pairing (template §4 freeze — signatures frozen)."""

    # Module-level pure function also reachable instance-style for convenience.
    _pairing_payload = staticmethod(_pairing_payload)

    def __init__(self, bus: EventBus, config: AppConfig) -> None:
        self._bus = bus
        self._config = config
        # Round 7: persistent identity — the token survives restarts, so the
        # QR is a one-time thing instead of a per-launch secret.
        self._store = PairingStore(config.appdata_dir)
        self._identity: PairingIdentity = self._store.load_or_create()
        self._zc: Zeroconf | None = None
        self._info: ServiceInfo | None = None

    @property
    def session_token(self) -> str:
        return self._identity.token

    @property
    def identity(self) -> PairingIdentity:
        """Persisted identity (token + device id/name + creation time)."""
        return self._identity

    def rotate_token(self) -> str:
        """Settings → "Reset pairing": new token, old scan codes stop working.

        The running mDNS record is stopped so the next ``start()`` advertises
        the freshly minted token; the QR is re-rendered on that start.
        """
        previous = self._identity
        if self._zc is not None:  # keep mDNS in step with the new token
            self.stop()
        self._identity = self._store.rotate()
        logger.info(
            "pairing token rotated (device_id %s -> %s)",
            previous.device_id,
            self._identity.device_id,
        )
        return self._identity.token

    def start(self) -> None:
        """Register mDNS, write the QR, then emit ``PAIRING_INFO`` exactly once.

        Register/QR failures are logged and re-raised (no half-start, and no
        ``PAIRING_INFO`` pointing at a missing file). Idempotent while running.
        """
        if self._zc is not None:
            logger.warning("DiscoveryPairing.start() ignored: already started")
            return
        ipv4 = self._lan_ipv4()
        info = ServiceInfo(
            type_=self._config.mdns_service_type,
            name=f"{self._config.mdns_service_name}.{self._config.mdns_service_type}",
            port=self._config.ws_port,
            addresses=[socket.inet_aton(ipv4)],
            properties={"v": "1", "token": self._identity.token},
        )
        zc = Zeroconf()
        try:
            zc.register_service(info)
        except Exception:
            logger.exception("mDNS registration of %s failed", info.name)
            zc.close()
            raise
        self._zc, self._info = zc, info
        try:
            qr_png_path = self._render_qr(ipv4)
        except Exception:
            logger.exception("QR render failed; rolling back mDNS registration")
            self.stop()
            raise
        self._bus.emit(
            PAIRING_INFO,
            ipv4=ipv4,
            port=self._config.ws_port,
            token=self._identity.token,
            qr_png_path=str(qr_png_path),
            device_id=self._identity.device_id,
            device_name=self._identity.device_name,
        )

    def stop(self) -> None:
        """Unregister + close zeroconf; idempotent, emits nothing."""
        zc, info = self._zc, self._info
        if zc is None:
            return
        try:
            if info is not None:
                zc.unregister_service(info)
        except Exception:
            logger.exception("mDNS unregister failed")
        try:
            zc.close()
        except Exception:
            logger.exception("zeroconf close failed")
        self._zc = None
        self._info = None

    def _render_qr(self, ipv4: str) -> Path:
        """Write the QR PNG — only when its payload changed (static pairing).

        The image is derived from (ip, port, token); with a persisted token the
        payload is byte-identical between launches, so the recorded payload in
        ``pairing.json`` lets a restart reuse the existing file without
        re-encoding anything.
        """
        path = self._config.appdata_dir / _QR_FILENAME
        payload = _pairing_payload(ipv4, self._config.ws_port, self._identity.token)
        if payload == self._identity.qr_payload and path.is_file():
            return path
        path.parent.mkdir(parents=True, exist_ok=True)  # clean profile, first run
        image = qrcode.make(payload)
        image.save(str(path))
        self._store.remember_qr_payload(payload)
        self._identity = PairingIdentity(
            token=self._identity.token,
            device_id=self._identity.device_id,
            device_name=self._identity.device_name,
            created_at=self._identity.created_at,
            qr_payload=payload,
        )
        return path

    def _lan_ipv4(self) -> str:
        """Non-loopback LAN IPv4: UDP probe → hostname scan → 127.0.0.1.

        Each fallback is logged (Doc 12 §4).
        """
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.connect(("8.8.8.8", 80))  # sends no packet; picks route + local IP
            ip: str | None = probe.getsockname()[0]
        except OSError as exc:
            logger.warning("UDP IPv4 probe failed (%s); trying hostname scan", exc)
            ip = None
        finally:
            probe.close()
        if ip is not None and not ip.startswith("127."):
            logger.info("LAN IPv4 via UDP probe: %s", ip)
            return ip
        if ip is not None:
            logger.warning("UDP probe returned loopback %s; trying hostname scan", ip)
        try:
            for entry in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
                candidate = entry[4][0]
                if not candidate.startswith("127."):
                    logger.info("LAN IPv4 via hostname scan: %s", candidate)
                    return candidate
        except OSError as exc:
            logger.warning("hostname IPv4 scan failed (%s)", exc)
        logger.warning("no non-loopback IPv4 found; pairing usable on this machine only")
        return "127.0.0.1"
