#!/usr/bin/env python3
"""Doc 28 §4 — latency_probe: end-to-end stylus→handler latency harness.

Boots an in-process stack without touching product source: a real ``EventBus``
(Doc 04) with an instance-level spy wrapping ``emit`` to stamp ``t_emit``, a
``LIVE_FRAME`` handler stamping ``t_handler`` against a FIFO of client
``t_send`` stamps, and a real ``websockets`` sync client streaming
``pack_live_frame`` LIVE_POINT frames at ``--rate``.

Gates (template §3 E2E gates row): p95(end-to-end) ≤ 8 ms AND transport mean
≤ 4 ms (LAN portion). Exit 0 iff both hold, 1 otherwise (connect/token
failure = 1); usage errors (missing token file, bad args) exit 2.
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import json
import math
import os
import sys
import time
from pathlib import Path
from urllib.parse import quote

_REPO_ROOT = Path(__file__).resolve().parents[1]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from websockets.sync.client import connect  # noqa: E402

from pc_agent.core.config_manager import AppConfig  # noqa: E402
from pc_agent.core.events import LIVE_FRAME, EventBus  # noqa: E402
from pc_agent.core.protocol import (  # noqa: E402
    FRAME_LIVE_POINT,
    TOOL_PEN,
    LiveFrame,
    pack_live_frame,
)
from pc_agent.network.ws_stream_server import WsStreamServer  # noqa: E402

#: Template §3 E2E gates: stylus→PC-GL p95 budget and LAN-portion budget.
P95_GATE_MS = 8.0
TRANSPORT_GATE_MS = 4.0
#: Doc 12 token file consulted when --token is absent (Doc 28 §4).
_TOKEN_FILE = Path(os.environ.get("APPDATA", str(Path.home()))) / "SlateSync" / "session_token.txt"
#: Post-send drain budget for the final in-flight frames.
_DRAIN_TIMEOUT_S = 10.0


def now_ns() -> int:
    """System-wide monotonic QPC clock (Doc 28 §5 step 1)."""
    return time.perf_counter_ns()


def _positive_int(raw: str) -> int:
    value = int(raw)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return value


def _positive_float(raw: str) -> float:
    value = float(raw)
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError("must be a positive finite number")
    return value


def nearest_rank(sorted_ns: list[int], q: float) -> float:
    """Nearest-rank percentile (ms) over a pre-sorted nanosecond sample."""
    rank = max(1, math.ceil(q * len(sorted_ns)))
    return sorted_ns[rank - 1] / 1e6


def resolve_token(args: argparse.Namespace, parser: argparse.ArgumentParser) -> str:
    """--token > Doc 12 session_token.txt > usage error (Doc 28 §4)."""
    if args.token:
        return args.token
    try:
        token = _TOKEN_FILE.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        parser.error(f"--token not given and {_TOKEN_FILE} is missing (usage error)")
    except OSError as exc:
        parser.error(f"--token not given and {_TOKEN_FILE} unreadable: {exc} (usage error)")
    if not token:
        parser.error(f"--token not given and {_TOKEN_FILE} is empty (usage error)")
    return token


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="latency_probe.py",
        description=(
            "Doc 28 §4 end-to-end latency probe "
            "(in-process bus spy + WsStreamServer + synthetic client)."
        ),
    )
    parser.add_argument("--host", default="127.0.0.1", help="bind/connect host (default 127.0.0.1)")
    parser.add_argument("--port", type=int, default=50606, help="WebSocket port (default 50606)")
    parser.add_argument(
        "--frames", type=_positive_int, default=5000, help="frames to send (default 5000)"
    )
    parser.add_argument(
        "--rate", type=_positive_float, default=60.0, help="send rate Hz (default 60)"
    )
    parser.add_argument(
        "--token",
        default=None,
        help="session token (default: %%APPDATA%%/SlateSync/session_token.txt)",
    )
    parser.add_argument(
        "--json", dest="json_out", default=None, metavar="OUT", help="write metrics JSON to OUT"
    )
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535:
        parser.error("--port must be in 1..65535")
    token = resolve_token(args, parser)

    config = AppConfig()
    if args.port != config.ws_port:
        config = dataclasses.replace(config, ws_port=args.port)

    bus = EventBus()
    pending: collections.deque[int] = collections.deque()  # t_send stamps, FIFO (seq-ordered)
    e2e_ns: list[int] = []
    transport_ns: list[int] = []
    dispatch_ns: list[int] = []
    stamp = {"t_emit": 0, "handled": 0}

    original_emit = bus.emit

    def spy_emit(event: str, **payload) -> None:  # instance-level spy (Doc 28 §4)
        if event == LIVE_FRAME:
            stamp["t_emit"] = now_ns()
        original_emit(event, **payload)

    def on_live_frame(frame=None, **_payload) -> None:
        t_handler = now_ns()
        stamp["handled"] += 1
        if not pending:
            return  # FIFO skew (dropped frame) — surfaced via handled != sent
        t_send = pending.popleft()
        t_emit = stamp["t_emit"]
        e2e_ns.append(t_handler - t_send)
        transport_ns.append(t_emit - t_send)
        dispatch_ns.append(t_handler - t_emit)

    bus.on(LIVE_FRAME, on_live_frame)
    bus.emit = spy_emit  # shadows the bound method for this instance only

    server = WsStreamServer(bus, config, token_provider=lambda: token, host=args.host)
    try:
        server.start()
    except Exception as exc:
        print(f"server start failed: {exc}", file=sys.stderr)
        return 1

    sent = 0
    try:
        url = f"ws://{args.host}:{server.port}/ws?token={quote(token, safe='')}"
        try:
            with connect(url, open_timeout=10.0, close_timeout=5.0) as ws:
                interval_ns = 1e9 / args.rate
                t0 = now_ns()
                for seq in range(args.frames):
                    target_ns = t0 + seq * interval_ns
                    while True:  # jitter-free perf_counter schedule (Doc 28 §5 step 3)
                        remaining_ns = target_ns - now_ns()
                        if remaining_ns <= 0:
                            break
                        time.sleep(remaining_ns / 1e9)
                    frame = LiveFrame(
                        FRAME_LIVE_POINT,
                        TOOL_PEN,
                        seq & 0xFFFF,
                        float(seq % 1000),
                        float(seq % 800),
                        0.5,
                    )
                    pending.append(now_ns())  # append before send: handler can never outrun it
                    ws.send(pack_live_frame(frame))
                    sent += 1
                deadline = time.monotonic() + _DRAIN_TIMEOUT_S
                while stamp["handled"] < args.frames and time.monotonic() < deadline:
                    time.sleep(0.05)
        except Exception as exc:
            print(f"connect/token/send failure: {exc}", file=sys.stderr)
            return 1
    finally:
        server.stop()

    handled = stamp["handled"]
    shortfall = handled != sent or len(e2e_ns) != handled or not e2e_ns

    p50 = p95 = max_ms = transport_mean = dispatch_mean_us = 0.0
    if e2e_ns:
        e2e_sorted = sorted(e2e_ns)
        p50 = nearest_rank(e2e_sorted, 0.50)
        p95 = nearest_rank(e2e_sorted, 0.95)
        max_ms = e2e_sorted[-1] / 1e6
        transport_mean = (sum(transport_ns) / len(transport_ns)) / 1e6
        dispatch_mean_us = (sum(dispatch_ns) / len(dispatch_ns)) / 1e3

    p95_ok = (not shortfall) and p95 <= P95_GATE_MS
    transport_ok = (not shortfall) and transport_mean <= TRANSPORT_GATE_MS
    ok = p95_ok and transport_ok
    result = "PASS" if ok else "FAIL"

    endpoint = f"ws://{args.host}:{server.port}/ws"
    print(
        f"endpoint: {endpoint} frames sent/handled {sent}/{handled} "
        f"({args.frames} @ {args.rate:g} Hz)"
    )
    print("p50 ms | p95 ms | max ms | transport mean ms | dispatch µs | PASS/FAIL")
    print(
        f"{p50:6.3f} | {p95:6.3f} | {max_ms:6.3f} | {transport_mean:17.3f} | "
        f"{dispatch_mean_us:11.1f} | {result}"
    )
    print(f"gate p95 <= {P95_GATE_MS:g} ms             : {'PASS' if p95_ok else 'FAIL'}")
    transport_label = f"gate transport mean <= {TRANSPORT_GATE_MS:g} ms"
    print(f"{transport_label:<38}: {'PASS' if transport_ok else 'FAIL'}")
    if shortfall:
        print(
            f"frame shortfall: sent={sent} handled={handled} measured={len(e2e_ns)}",
            file=sys.stderr,
        )

    if args.json_out:
        out = Path(args.json_out)
        out.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "frames": len(e2e_ns),
            "p50_ms": round(p50, 3),
            "p95_ms": round(p95, 3),
            "max_ms": round(max_ms, 3),
            "transport_mean_ms": round(transport_mean, 3),
            "result": result,
        }
        out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
