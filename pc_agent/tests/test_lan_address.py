"""Round 7 regression — reachable LAN address selection (Doc 12 §4).

Reported bug: after the round-7 pairing work, scanning the PC QR code "didn't
catch the device and said nothing". The pairing QR (and the mDNS ``A`` record)
was encoding the address of the *default route*, which on a machine with a VPN
/ TUN / hypervisor adapter is that virtual adapter (``172.19.0.1``, no
gateway). A tablet on the Wi-Fi LAN can never route there, so the WebSocket
dial timed out and the UI had nothing to say.

These tests pin the selection rules without touching real adapters: the
injected probe/scan pair stands in for the OS and ``AdapterAddress`` lists
describe the machine.
"""

from __future__ import annotations

from unittest.mock import patch

from pc_agent.network import lan_address
from pc_agent.network.lan_address import (
    AdapterAddress,
    choose_lan_ipv4,
    enumerate_adapters,
    probe_default_route_ipv4,
    rank,
    score,
)

# -- scoring / ranking -------------------------------------------------------


def test_real_lan_adapter_outranks_virtual_ones() -> None:
    real = AdapterAddress("192.168.1.244", "192.168.1.1", "Realtek PCIe GbE")
    tun = AdapterAddress("172.19.0.1", None, "sing-tun Tunnel #2")
    hyperv = AdapterAddress("172.17.80.1", None, "Hyper-V Virtual Ethernet Adapter")
    virtualbox = AdapterAddress("192.168.56.1", None, "VirtualBox Host-Only Ethernet")

    assert score(real) > score(virtualbox) > score(hyperv)
    assert score(real) > score(tun)
    assert rank([tun, virtualbox, hyperv, real])[0] is real


def test_loopback_never_wins_ranking() -> None:
    loopback = AdapterAddress("127.0.0.1", "127.0.0.1", "Loopback")
    tun = AdapterAddress("172.19.0.1", None, "sing-tun Tunnel #2")
    assert score(loopback) < score(tun)
    assert rank([loopback, tun])[0] is tun


def test_gateway_less_192_168_is_still_beatable() -> None:
    """A host-only adapter is 'awkward' even inside a home 192.168 range."""
    host_only = AdapterAddress("192.168.56.1", None, "VirtualBox Host-Only")
    wifi = AdapterAddress("192.168.1.50", "192.168.1.1", "Intel Wi-Fi")
    assert host_only.awkward
    assert not wifi.awkward
    assert choose_lan_ipv4(lambda: "192.168.56.1", lambda: None, [
        host_only,
        wifi,
    ]) == "192.168.1.50"


# -- choose_lan_ipv4 ---------------------------------------------------------


def test_probe_answer_is_kept_when_it_is_usable() -> None:
    adapters = [
        AdapterAddress("192.168.1.244", "192.168.1.1", "Realtek PCIe GbE"),
        AdapterAddress("172.19.0.1", None, "sing-tun Tunnel #2"),
    ]
    assert choose_lan_ipv4(lambda: "192.168.1.244", lambda: None, adapters) == (
        "192.168.1.244"
    )


def test_vpn_answer_is_replaced_by_the_real_lan_adapter() -> None:
    adapters = [
        AdapterAddress("172.19.0.1", None, "sing-tun Tunnel #2"),
        AdapterAddress("192.168.1.244", "192.168.1.1", "Realtek PCIe GbE"),
    ]
    assert choose_lan_ipv4(lambda: "172.19.0.1", lambda: None, adapters) == (
        "192.168.1.244"
    )


def test_unknown_probe_address_is_kept_verbatim() -> None:
    """An address we have no adapter metadata for must not be second-guessed."""
    adapters = [AdapterAddress("192.168.1.244", "192.168.1.1", "Realtek PCIe GbE")]
    assert choose_lan_ipv4(lambda: "10.11.12.13", lambda: None, adapters) == (
        "10.11.12.13"
    )


def test_loopback_probe_falls_back_to_hostname_scan() -> None:
    assert choose_lan_ipv4(lambda: "127.0.0.1", lambda: "10.20.30.40", []) == (
        "10.20.30.40"
    )


def test_only_virtual_adapters_keeps_the_original_candidate() -> None:
    """No better option ⇒ keep the probe answer (behaviour unchanged)."""
    adapters = [AdapterAddress("172.19.0.1", None, "sing-tun Tunnel #2")]
    assert choose_lan_ipv4(lambda: "172.19.0.1", lambda: None, adapters) == (
        "172.19.0.1"
    )


def test_no_candidates_at_all_yields_loopback() -> None:
    assert choose_lan_ipv4(lambda: None, lambda: None, []) == "127.0.0.1"


# -- platform shims ----------------------------------------------------------


def test_enumerate_adapters_is_empty_off_windows() -> None:
    with patch.object(lan_address.sys, "platform", "linux"):
        assert enumerate_adapters() == []


def test_enumerate_adapters_swallows_platform_errors() -> None:
    with (
        patch.object(lan_address.sys, "platform", "win32"),
        patch.object(lan_address, "_windows_adapters", side_effect=RuntimeError("no")),
    ):
        assert enumerate_adapters() == []


def test_probe_default_route_reads_the_socket() -> None:
    with patch("pc_agent.network.lan_address.socket.socket") as sock_cls:
        sock_cls.return_value.getsockname.return_value = ("192.168.1.244", 5555)
        assert probe_default_route_ipv4() == "192.168.1.244"
        sock_cls.return_value.connect.assert_called_once_with(("8.8.8.8", 80))


def test_probe_default_route_returns_none_on_oserror() -> None:
    with patch("pc_agent.network.lan_address.socket.socket") as sock_cls:
        sock_cls.return_value.connect.side_effect = OSError("no route")
        assert probe_default_route_ipv4() is None


def test_windows_adapters_swallows_enumeration_failure() -> None:
    """`_windows_adapters` failures are logged, never raised (startup safety)."""
    with (
        patch.object(lan_address.sys, "platform", "win32"),
        patch.object(lan_address, "_windows_adapters", side_effect=OSError("no iphlpapi")),
    ):
        assert enumerate_adapters() == []
