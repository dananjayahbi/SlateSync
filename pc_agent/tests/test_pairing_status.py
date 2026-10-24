"""Round 7 regression — QR dialog pairing feedback copy (Doc 12 / Doc 16 §5.7).

Reported bug: "when I scan the QR it doesn't catch the device. Also it says
nothing." The dialog now states what it is waiting for, how many tablets have
paired, and warns when the advertised address cannot be reached from another
device. These tests pin the pure copy derivation behind those labels.
"""

from __future__ import annotations

import pytest

from pc_agent.gui import pairing_status


@pytest.mark.parametrize(
    ("address", "expected"),
    [
        ("192.168.1.244", True),
        ("10.0.0.7", True),
        ("172.16.4.9", True),
        ("127.0.0.1", False),
        ("169.254.10.20", False),
        ("0.0.0.0", False),
        ("", False),
        (None, False),
    ],
)
def test_is_reachable_address(address: str | None, expected: bool) -> None:
    assert pairing_status.is_reachable_address(address) is expected


def test_loopback_address_produces_a_warning() -> None:
    warning = pairing_status.reachability_warning("127.0.0.1")
    assert "127.0.0.1" in warning
    assert "same network" in warning


def test_lan_address_has_no_warning() -> None:
    assert pairing_status.reachability_warning("192.168.1.244") == ""
    assert pairing_status.reachability_warning(None) == ""


@pytest.mark.parametrize(
    ("count", "expected"),
    [
        (0, pairing_status.NO_DEVICE_TEXT),
        (-3, pairing_status.NO_DEVICE_TEXT),
        (1, "1 tablet connected."),
        (2, "2 tablets connected."),
    ],
)
def test_device_count_text(count: int, expected: str) -> None:
    assert pairing_status.device_count_text(count) == expected


def test_address_text_formats_host_and_port() -> None:
    assert pairing_status.address_text("192.168.1.244", 50606) == (
        "192.168.1.244:50606"
    )
    assert pairing_status.address_text("192.168.1.244", None) == "192.168.1.244"
    assert pairing_status.address_text(None, 50606) == ""
