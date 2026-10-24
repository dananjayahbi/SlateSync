"""Reachable LAN IPv4 selection for pairing (Doc 12 extension).

The pairing QR and the mDNS ``A`` record must advertise an address a tablet on
the same Wi-Fi can actually reach. A plain ``connect(("8.8.8.8", 80))`` probe
only reports the interface the *default route* picks, which on a developer
machine is frequently a VPN / TUN / Hyper-V adapter (``172.19.0.1`` with no
gateway here). The QR then encodes an address that the tablet can never route
to: it scans, the socket times out, and nothing happens.

This module ranks the machine's adapters and prefers the real LAN one:

1. enumerate adapters (Windows ``GetAdaptersInfo``; empty elsewhere),
2. score them (has a gateway ✓, private range ✓, virtual adapter ✗),
3. validate whatever the UDP probe / hostname scan produced — a candidate that
   lives on a virtual or gateway-less adapter is replaced by the best real one.

When no adapter metadata is available the legacy probe → scan → loopback chain
is preserved unchanged, so the behaviour is identical on non-Windows hosts and
inside sandboxes that block adapter enumeration.
"""

from __future__ import annotations

import ipaddress
import logging
import socket
import sys
from collections.abc import Callable
from dataclasses import dataclass

logger = logging.getLogger(__name__)

_LOOPBACK = "127.0.0.1"

#: Adapter descriptions that never serve a tablet: VPN/TUN/WSL/hypervisor
#: virtual switches, tunnel drivers and Wi-Fi Direct pseudo adapters.
_VIRTUAL_HINTS = (
    "virtual",
    "hyper-v",
    "vmware",
    "virtualbox",
    "tap-",
    "tap ",
    "tun",
    "vpn",
    "wsl",
    "docker",
    "tailscale",
    "zerotier",
    "nekoray",
    "wireguard",
    "openvpn",
    "sing-tun",
    "pseudo",
    "loopback",
    "bluetooth",
    "wi-fi direct",
)

_GATEWAY_NONE = {"0.0.0.0", "255.255.255.255", ""}


@dataclass(frozen=True)
class AdapterAddress:
    """One IPv4 address bound to a network adapter."""

    address: str
    gateway: str | None = None
    description: str = ""

    @property
    def is_loopback(self) -> bool:
        return self.address.startswith("127.")

    @property
    def is_private(self) -> bool:
        try:
            return ipaddress.IPv4Address(self.address).is_private
        except ValueError:
            return False

    @property
    def has_gateway(self) -> bool:
        return bool(self.gateway) and str(self.gateway) not in _GATEWAY_NONE

    @property
    def looks_virtual(self) -> bool:
        lowered = self.description.lower()
        return any(hint in lowered for hint in _VIRTUAL_HINTS)

    @property
    def awkward(self) -> bool:
        """True when this address is a poor choice for the pairing QR."""
        return self.looks_virtual or not self.has_gateway


def score(adapter: AdapterAddress) -> int:
    """Ranking weight — higher is more likely to be reachable from a tablet."""
    if adapter.is_loopback:
        return -1000
    value = 0
    if adapter.has_gateway:
        value += 100
    if adapter.looks_virtual:
        value -= 200
    if adapter.is_private:
        value += 20
    if adapter.address.startswith("192.168."):
        value += 10
    elif adapter.address.startswith("10."):
        value += 6
    elif adapter.address.startswith("172."):
        value += 2
    return value


def rank(adapters: list[AdapterAddress]) -> list[AdapterAddress]:
    """Adapters best-first (stable for equal scores)."""
    return sorted(adapters, key=score, reverse=True)


def enumerate_adapters() -> list[AdapterAddress]:
    """IPv4 addresses of this machine's adapters (``[]`` when unavailable)."""
    if sys.platform != "win32":
        return []
    try:
        return _windows_adapters()
    except Exception:  # pragma: no cover - defensive: never block startup
        logger.debug("adapter enumeration failed", exc_info=True)
        return []


def choose_lan_ipv4(
    probe: Callable[[], str | None],
    scan: Callable[[], str | None],
    adapters: list[AdapterAddress] | None = None,
) -> str:
    """Pick the address the pairing QR / mDNS record should advertise.

    ``probe`` is the UDP default-route probe, ``scan`` the hostname fallback.
    The candidate either reports is only overridden when it is provably bound
    to an unsuitable adapter *and* a better real one exists — so mocked
    single-interface environments keep their existing answer.
    """
    candidates = enumerate_adapters() if adapters is None else list(adapters)
    best = next((item for item in rank(candidates) if not item.awkward), None)

    probed = probe()
    if probed and not probed.startswith("127."):
        candidate = probed
    else:
        candidate = scan() or probed or _LOOPBACK

    for adapter in candidates:
        if adapter.address != candidate:
            continue
        if adapter.awkward and best is not None:
            logger.warning(
                "pairing address %s belongs to %r (no usable LAN route); "
                "using %s instead",
                candidate,
                adapter.description or "unknown adapter",
                best.address,
            )
            return best.address
        return candidate
    return candidate


# ---------------------------------------------------------------------------
# Windows adapter enumeration (iphlpapi, no extra dependency)
# ---------------------------------------------------------------------------


def _windows_adapters() -> list[AdapterAddress]:
    import ctypes
    from ctypes import wintypes

    class _IpAddrString(ctypes.Structure):
        pass

    _IpAddrString._fields_ = [
        ("Next", ctypes.POINTER(_IpAddrString)),
        ("IpAddress", ctypes.c_char * 16),
        ("IpMask", ctypes.c_char * 16),
        ("Context", wintypes.DWORD),
    ]

    class _AdapterInfo(ctypes.Structure):
        pass

    _AdapterInfo._fields_ = [
        ("Next", ctypes.POINTER(_AdapterInfo)),
        ("ComboIndex", wintypes.DWORD),
        ("AdapterName", ctypes.c_char * 260),
        ("Description", ctypes.c_char * 132),
        ("AddressLength", wintypes.UINT),
        ("Address", ctypes.c_ubyte * 8),
        ("Index", wintypes.DWORD),
        ("Type", wintypes.UINT),
        ("DhcpEnabled", wintypes.UINT),
        ("CurrentIpAddress", ctypes.POINTER(_IpAddrString)),
        ("IpAddressList", _IpAddrString),
        ("GatewayList", _IpAddrString),
        ("DhcpServer", _IpAddrString),
        ("HaveWins", wintypes.BOOL),
        ("PrimaryWinsServer", _IpAddrString),
        ("SecondaryWinsServer", _IpAddrString),
        ("LeaseObtained", ctypes.c_long),
        ("LeaseExpires", ctypes.c_long),
    ]

    iphlpapi = ctypes.WinDLL("iphlpapi")
    size = wintypes.ULONG(15_000)
    iphlpapi.GetAdaptersInfo(None, ctypes.byref(size))  # ERROR_BUFFER_OVERFLOW
    buffer = ctypes.create_string_buffer(size.value)
    if iphlpapi.GetAdaptersInfo(
        ctypes.cast(buffer, ctypes.POINTER(_AdapterInfo)), ctypes.byref(size)
    ) != 0:
        return []

    found: list[AdapterAddress] = []
    node = ctypes.cast(buffer, ctypes.POINTER(_AdapterInfo))
    while node:
        info = node.contents
        description = info.Description.decode("ascii", "replace")

        addresses: list[str] = []
        entry = ctypes.pointer(info.IpAddressList)
        while entry:
            addresses.append(entry.contents.IpAddress.decode("ascii", "replace"))
            entry = entry.contents.Next

        gateways: list[str] = []
        entry = ctypes.pointer(info.GatewayList)
        while entry:
            gateways.append(entry.contents.IpAddress.decode("ascii", "replace"))
            entry = entry.contents.Next

        gateway = next((gw for gw in gateways if gw not in _GATEWAY_NONE), None)
        for address in addresses:
            if address in _GATEWAY_NONE:
                continue
            found.append(
                AdapterAddress(
                    address=address, gateway=gateway, description=description
                )
            )
        node = info.Next
    return found


def probe_default_route_ipv4() -> str | None:
    """IP the OS would use for outbound traffic (``None`` on failure)."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("8.8.8.8", 80))  # sends no packet; picks route + local IP
        return probe.getsockname()[0]
    except OSError as exc:
        logger.warning("UDP IPv4 probe failed (%s)", exc)
        return None
    finally:
        probe.close()
