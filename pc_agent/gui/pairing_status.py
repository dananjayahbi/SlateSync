"""Pairing status copy for the PC agent QR dialog (Doc 12 / Doc 16 §5.7).

The reported symptom was "when I scan the QR it doesn't catch the device. Also
it says nothing." Two halves to that: the QR encoded an unreachable address
(see :mod:`pc_agent.network.lan_address`) and the dialog gave no feedback while
it waited. This module owns the pure text derivation so the widget layer stays
a thin renderer and the copy is unit-testable.
"""

from __future__ import annotations

#: Shown until ``PAIRING_INFO`` arrives.
WAITING_TEXT = "Preparing pairing information…"

#: Shown when the QR is ready and no tablet has connected yet.
NO_DEVICE_TEXT = "Waiting for a tablet to scan this code…"

#: Advisory shown under the address line.
HINT_TEXT = "Both devices must be on the same Wi-Fi or LAN."

#: Address prefixes that a tablet on the same network usually cannot reach.
_UNREACHABLE_PREFIXES = ("127.", "169.254.", "0.")


def device_count_text(devices: int) -> str:
    """``devices`` from ``DEVICES_UPDATED``/``CANVAS_LIST_UPDATED`` → copy."""
    if devices <= 0:
        return NO_DEVICE_TEXT
    if devices == 1:
        return "1 tablet connected."
    return f"{devices} tablets connected."


def address_text(ipv4: str | None, port: int | None) -> str:
    """``192.168.1.244:50606`` — the address the QR advertises."""
    if not ipv4:
        return ""
    if port is None:
        return str(ipv4)
    return f"{ipv4}:{port}"


def is_reachable_address(ipv4: str | None) -> bool:
    """Cheap sanity check on the advertised address.

    Loopback / link-local / wildcard means the QR is only usable from this
    machine (``_lan_ipv4``'s documented last resort), so the dialog warns
    instead of pretending the pairing will work over Wi-Fi.
    """
    if not ipv4:
        return False
    return not ipv4.startswith(_UNREACHABLE_PREFIXES)


def reachability_warning(ipv4: str | None) -> str:
    """Warning line for an address a second device cannot dial (``""`` if fine)."""
    if not ipv4 or is_reachable_address(ipv4):
        return ""
    return (
        "This PC has no network address a tablet can reach "
        f"({ipv4}). Connect both devices to the same network and restart "
        "the agent."
    )
