"""Doc 12 tests — ``docs/micro/12_pc_mdns_qr_pairing_service.md`` §6.

Hermetic by construction: ``Zeroconf`` is always patched (no multicast stack
needed), ``_lan_ipv4`` is either patched or unit-probed with mocked sockets,
and the QR lands in a pytest ``tmp_path`` appdata directory. Token-mismatch
``4001`` enforcement is asserted in Doc 11's tests through this
``session_token``.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any
from unittest.mock import patch

import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import PAIRING_INFO, EventBus
from pc_agent.network.discovery_pairing import DiscoveryPairing, _pairing_payload
from pc_agent.network.lan_address import AdapterAddress

_PNG_MAGIC = b"\x89PNG"


@pytest.fixture()
def zc_cls() -> Any:
    with patch("pc_agent.network.discovery_pairing.Zeroconf") as mocked:
        yield mocked


@pytest.fixture()
def lan_ip() -> Any:
    with patch.object(DiscoveryPairing, "_lan_ipv4", return_value="192.168.1.5"):
        yield


@pytest.fixture()
def pairing_factory(tmp_path: Path) -> Any:
    instances: list[DiscoveryPairing] = []

    def _factory(appdata: Path | None = None) -> tuple[DiscoveryPairing, AppConfig, list[dict]]:
        config = AppConfig(appdata_dir=appdata or (tmp_path / "SlateSync"))
        bus = EventBus()
        events: list[dict] = []
        bus.on(PAIRING_INFO, lambda **payload: events.append(payload))
        pairing = DiscoveryPairing(bus, config)
        instances.append(pairing)
        return pairing, config, events

    yield _factory
    for pairing in instances:
        pairing.stop()  # frees any zeroconf handle a failing test left behind


# -- mDNS record -------------------------------------------------------------


def test_mdns_service_record_fields(
    pairing_factory: Any, zc_cls: Any, lan_ip: Any
) -> None:
    pairing, config, _ = pairing_factory()
    pairing.start()
    zc = zc_cls.return_value
    assert zc.register_service.call_count == 1
    info = zc.register_service.call_args.args[0]
    assert info.type == "_slatesync._tcp.local."
    assert info.name == "SlateSync._slatesync._tcp.local."
    assert info.port == config.ws_port == 50606
    txt = {key.decode(): value.decode() for key, value in info.properties.items()}
    assert txt == {"v": "1", "token": pairing.session_token}
    assert info.parsed_addresses() == ["192.168.1.5"]


def test_stop_unregisters_closes_and_is_idempotent(
    pairing_factory: Any, zc_cls: Any, lan_ip: Any
) -> None:
    pairing, _, events = pairing_factory()
    pairing.start()
    zc = zc_cls.return_value
    registered = zc.register_service.call_args.args[0]
    assert len(events) == 1

    pairing.stop()
    assert zc.unregister_service.call_count == 1
    assert zc.unregister_service.call_args.args[0] is registered
    assert zc.close.call_count == 1
    pairing.stop()  # idempotent
    assert zc.unregister_service.call_count == 1
    assert zc.close.call_count == 1
    assert len(events) == 1  # stop() emits nothing


def test_stop_without_start_is_noop(pairing_factory: Any, zc_cls: Any) -> None:
    pairing, _, events = pairing_factory()
    pairing.stop()
    zc_cls.assert_not_called()
    assert events == []


# -- token -------------------------------------------------------------------


def test_session_token_stable_urlsafe_and_per_instance(
    pairing_factory: Any, zc_cls: Any, lan_ip: Any, tmp_path: Path
) -> None:
    pairing, _, _ = pairing_factory()
    tokens = [pairing.session_token for _ in range(5)]
    assert len(set(tokens)) == 1
    assert re.fullmatch(r"[A-Za-z0-9_-]+", tokens[0])

    pairing.start()  # restart in the same instance keeps the token
    pairing.stop()
    pairing.start()
    assert pairing.session_token == tokens[0]

    # Round 7: the token is persisted in appdata, so a fresh instance on the
    # same profile reuses it (the QR is now a static, one-time pairing code).
    restarted, _, _ = pairing_factory()
    assert restarted.session_token == tokens[0]

    # A different profile (other appdata dir) mints its own token.
    other, _, _ = pairing_factory(appdata=tmp_path / "other" / "SlateSync")
    assert other.session_token != tokens[0]


# -- QR ----------------------------------------------------------------------


def test_pairing_payload_is_canonical() -> None:
    assert _pairing_payload("192.168.1.5", 50606, "abc_DEF-123") == (
        "slatesync://connect?ip=192.168.1.5&port=50606&token=abc_DEF-123"
    )
    assert DiscoveryPairing._pairing_payload("10.0.0.7", 50606, "tok") == (
        "slatesync://connect?ip=10.0.0.7&port=50606&token=tok"
    )


def test_qr_png_written_and_pairing_info_emitted(
    pairing_factory: Any, zc_cls: Any, lan_ip: Any
) -> None:
    pairing, config, events = pairing_factory()
    pairing.start()
    assert len(events) == 1
    emitted = events[0]
    assert emitted["ipv4"] == "192.168.1.5"
    assert emitted["port"] == config.ws_port == 50606
    assert emitted["token"] == pairing.session_token
    qr_path = Path(emitted["qr_png_path"])
    assert qr_path == config.appdata_dir / "pairing_qr.png"
    assert qr_path.parent.is_dir()
    assert qr_path.read_bytes()[:4] == _PNG_MAGIC


def test_qr_renders_frozen_payload(pairing_factory: Any, zc_cls: Any, lan_ip: Any) -> None:
    pairing, config, _ = pairing_factory()
    with patch("pc_agent.network.discovery_pairing.qrcode.make") as make:
        pairing.start()
    make.assert_called_once_with(
        "slatesync://connect?ip=192.168.1.5"
        f"&port={config.ws_port}&token={pairing.session_token}"
    )


def test_start_creates_appdata_dir_on_clean_profile(
    pairing_factory: Any, zc_cls: Any, lan_ip: Any, tmp_path: Path
) -> None:
    target = tmp_path / "fresh" / "SlateSync"
    assert not target.exists()
    pairing, _, _ = pairing_factory(appdata=target)
    pairing.start()
    assert (target / "pairing_qr.png").is_file()


def test_restart_keeps_qr_payload_stable(
    pairing_factory: Any, zc_cls: Any, lan_ip: Any
) -> None:
    """The pairing QR is a static one-time artifact (round 7).

    A restart on the same profile reuses the persisted token, so the payload
    stays valid for devices that already stored the credentials, and the PNG
    is not needlessly re-encoded.
    """
    first, config, first_events = pairing_factory()
    first.start()
    qr_path = config.appdata_dir / "pairing_qr.png"
    first_bytes = qr_path.read_bytes()
    first.stop()

    second, _, second_events = pairing_factory()  # same default appdata path
    with patch("pc_agent.network.discovery_pairing.qrcode.make") as make:
        second.start()
    assert second.session_token == first.session_token
    assert qr_path.read_bytes() == first_bytes  # payload unchanged → no rewrite
    make.assert_not_called()
    assert len(second_events) == 1
    assert second_events[0]["token"] == second.session_token
    assert second_events[0]["token"] == first_events[0]["token"]


def test_rotate_token_mints_new_token_and_rewrites_qr(
    pairing_factory: Any, zc_cls: Any, lan_ip: Any
) -> None:
    """Settings → Reset pairing invalidates previously paired devices."""
    pairing, config, _ = pairing_factory()
    pairing.start()
    qr_path = config.appdata_dir / "pairing_qr.png"
    old_bytes = qr_path.read_bytes()
    old_token = pairing.session_token
    pairing.stop()

    new_token = pairing.rotate_token()
    assert new_token != old_token
    assert pairing.session_token == new_token
    pairing.start()
    assert qr_path.read_bytes() != old_bytes  # rewritten for the new token


def test_rotate_token_while_running_readvertises_immediately(
    pairing_factory: Any, zc_cls: Any, lan_ip: Any
) -> None:
    """Reset pairing must not leave the agent alive but unadvertised.

    Regression: the old implementation stopped mDNS and never restarted it, so
    after "Reset pairing" no tablet could discover or scan the agent at all.
    """
    pairing, _, events = pairing_factory()
    pairing.start()
    zc = zc_cls.return_value
    assert zc.register_service.call_count == 1

    new_token = pairing.rotate_token()

    assert zc.unregister_service.call_count == 1  # old record removed
    assert zc.close.call_count == 1
    assert zc.register_service.call_count == 2  # re-advertised straight away
    assert events[-1]["token"] == new_token  # dialog re-renders the new QR
    assert len(events) == 2
    pairing.stop()


def test_port_consistency_across_config_mdns_qr(
    pairing_factory: Any, zc_cls: Any, lan_ip: Any
) -> None:
    pairing, config, events = pairing_factory()
    pairing.start()
    info = zc_cls.return_value.register_service.call_args.args[0]
    assert info.port == config.ws_port == events[0]["port"] == 50606
    payload = DiscoveryPairing._pairing_payload("192.168.1.5", config.ws_port, "t")
    assert payload == "slatesync://connect?ip=192.168.1.5&port=50606&token=t"


# -- failure containment -----------------------------------------------------


def test_qr_failure_propagates_before_pairing_info(
    pairing_factory: Any, zc_cls: Any, lan_ip: Any
) -> None:
    pairing, _, events = pairing_factory()
    with patch(
        "pc_agent.network.discovery_pairing.qrcode.make", side_effect=OSError("disk full")
    ):
        with pytest.raises(OSError, match="disk full"):
            pairing.start()
    zc = zc_cls.return_value
    assert zc.register_service.call_count == 1
    assert zc.unregister_service.call_count == 1  # registration rolled back
    assert zc.close.call_count == 1
    assert events == []  # no PAIRING_INFO pointing at a missing file

    pairing.stop()  # after the failed start: no extra unregister/close calls
    assert zc.unregister_service.call_count == 1
    assert zc.close.call_count == 1


# -- IPv4 selection ----------------------------------------------------------


@pytest.fixture()
def no_adapters() -> Any:
    """Report no adapter metadata so the legacy probe→scan ladder is used."""
    with patch(
        "pc_agent.network.lan_address.enumerate_adapters", return_value=[]
    ) as mocked:
        yield mocked


def test_lan_ipv4_prefers_udp_probe(pairing_factory: Any, no_adapters: Any) -> None:
    pairing, _, _ = pairing_factory()
    with (
        patch("pc_agent.network.lan_address.socket.socket") as sock_cls,
        patch("pc_agent.network.discovery_pairing.socket.getaddrinfo") as gai,
    ):
        sock_cls.return_value.getsockname.return_value = ("192.168.7.4", 55555)
        assert pairing._lan_ipv4() == "192.168.7.4"
        sock_cls.return_value.connect.assert_called_once_with(("8.8.8.8", 80))
        gai.assert_not_called()


def test_lan_ipv4_rejects_loopback_then_scans_hostname(
    pairing_factory: Any, no_adapters: Any
) -> None:
    pairing, _, _ = pairing_factory()
    with (
        patch("pc_agent.network.lan_address.socket.socket") as sock_cls,
        patch("pc_agent.network.discovery_pairing.socket.getaddrinfo") as gai,
    ):
        sock_cls.return_value.getsockname.return_value = ("127.0.0.1", 0)
        gai.return_value = [
            ("AF_INET", "SOCK_DGRAM", "", "", ("127.0.0.1", 0)),
            ("AF_INET", "SOCK_DGRAM", "", "", ("10.20.30.40", 0)),
        ]
        assert pairing._lan_ipv4() == "10.20.30.40"


def test_lan_ipv4_last_resort_is_loopback(
    pairing_factory: Any, no_adapters: Any
) -> None:
    pairing, _, _ = pairing_factory()
    with (
        patch("pc_agent.network.lan_address.socket.socket") as sock_cls,
        patch("pc_agent.network.discovery_pairing.socket.getaddrinfo") as gai,
    ):
        sock_cls.return_value.getsockname.side_effect = OSError("no route")
        gai.return_value = [("AF_INET", "SOCK_DGRAM", "", "", ("127.0.0.1", 0))]
        assert pairing._lan_ipv4() == "127.0.0.1"
        gai.side_effect = OSError("resolver down")  # scan failure lands here too
        assert pairing._lan_ipv4() == "127.0.0.1"


def test_lan_ipv4_replaces_vpn_candidate_with_real_lan(
    pairing_factory: Any,
) -> None:
    """Regression: a VPN/TUN default route must not reach the pairing QR.

    The reported bug — "when I scan the QR it doesn't catch the device" — was
    the code encoding a TUN address (172.19.0.1, no gateway) that no tablet can
    route to.
    """
    pairing, _, _ = pairing_factory()
    adapters = [
        AdapterAddress("172.19.0.1", gateway=None, description="sing-tun Tunnel #2"),
        AdapterAddress(
            "192.168.56.1", gateway=None, description="VirtualBox Host-Only"
        ),
        AdapterAddress(
            "192.168.1.244",
            gateway="192.168.1.1",
            description="Realtek PCIe GbE Family Controller",
        ),
    ]
    with (
        patch("pc_agent.network.lan_address.enumerate_adapters", return_value=adapters),
        patch("pc_agent.network.lan_address.socket.socket") as sock_cls,
    ):
        sock_cls.return_value.getsockname.return_value = ("172.19.0.1", 5555)
        assert pairing._lan_ipv4() == "192.168.1.244"
