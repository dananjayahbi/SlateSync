# Doc 11: WebSocket Stream Server

## 1. Objective & Scope
* Async WebSocket server on port `50606`, path `/ws` (the `websockets` library), running its own asyncio loop inside a **daemon thread** — the dual-path gateway between the tablet and the PC `EventBus`.
* **Binary path:** 16-byte frames unpacked zero-copy from a `memoryview` via `unpack_live_frame` → stale-seq drop (mod $2^{16}$) → `CAMERA_DELTA` (frame_type `0x03`) or `LIVE_FRAME`.
* **Text path:** §4.2 JSON envelope validation → `RPC_MESSAGE` (feeds Docs 09, 10, 15). Also emits `CONNECTION_STATE` and provides thread-safe `broadcast_json(msg, exclude=None)` for PC-originated pushes (Doc 15, Doc 12 handshake data via Doc 16) and for the **live mutation relay** (Doc 02 §10.2): after local dispatch, incoming `ELEMENT_COMMIT` (incl. `CLEAR_CANVAS`) and `ARTBOARD_RESIZE` envelopes are re-broadcast to every **other** connection — the sender is excluded.
* Auth: token from the injected `token_provider` callable (wired to `DiscoveryPairing.session_token`, Doc 12); missing/mismatched token → close code `4001`, no events.
* Envelope fan-out only: the server never interprets `payload` (`OPEN_CANVAS`/`ASSET_*`/`UPGRADE_SIZE` keys belong to Docs 10/09/15) — it validates the §4.2 shell and forwards. Ordering: a single `async for` per connection preserves frame order (no task spawned per message).

## 2. File Ownership
### Creates (implementation subagent writes these paths)
* `pc_agent/network/__init__.py`
* `pc_agent/network/ws_stream_server.py`
* `pc_agent/tests/test_ws_stream_server.py`
* `pc_agent/tests/test_wave1_mirror_pipeline.py`

### Read-only dependencies (imports, each cited as "Doc NN")
* `pc_agent/core/events.py` (`EventBus`, event constants) and `pc_agent/core/config_manager.py` (`AppConfig`) — Doc 04
* `pc_agent/core/protocol.py` — `LiveFrame`, `FRAME_CAMERA`, `unpack_live_frame` (mirrors Doc 02; import, never re-declare) — Doc 04
* `token_provider` returns `DiscoveryPairing.session_token` (Doc 12) — passed in as a callable, not imported
* `websockets` library (requirements, Doc 04); stdlib `asyncio`, `threading`, `json`, `struct`, `logging`, `urllib.parse`

### Never touches (paths owned by concurrent docs — write-conflict guard)
* `pc_agent/network/discovery_pairing.py`, `pc_agent/tests/test_discovery_pairing.py` (Doc 12)
* `pc_agent/engine/*` (Docs 09/10); `pc_agent/core/*`, `pc_agent/main.py` (Doc 04); `pc_agent/viewport/*` (Docs 06/07/08); `shared_specs/*` (Docs 01–03); `mobile_app/*` (Docs 05, 20–27)

## 3. Contract References
* `overview.md` §4.1 (16-byte `<BBHfff` frame), §4.2 (envelope, token URL, `4001`), §5 Doc 11 entry, §6 Wave 1.B.
* `_micro_doc_template.md` §3 (port `50606`, path `/ws`, FrameType/ToolId, seq rule, RPC types/actions), §4 (`WsStreamServer` freeze verbatim below; `EventBus`/`LiveFrame` from Doc 04; event matrix + threading model), §6 ownership matrix.
* Emits consumed by: Doc 06 (`LIVE_FRAME`, `CAMERA_DELTA`), Docs 09/10/15 (`RPC_MESSAGE`), Doc 16 (`CONNECTION_STATE`). Seq stale-drop rule is enforced **here** and again in Doc 06 `submit_live_frame`.
* Pairing context (Doc 12): the announced TXT/port and QR payload both point at this server’s connect URL `ws://<ipv4>:50606/ws?token=<session_token>` (template §3) — Doc 11 is the sole enforcement point.

## 4. Interface Freeze
**Verbatim from template §4 — `WsStreamServer` (the `broadcast_json` line carries the Doc 02 §10.2 round-6 `exclude` amendment; rest unchanged, do not modify):**

```python
class WsStreamServer:                                   # Doc 11
    def __init__(self, bus: EventBus, config: AppConfig,
                 token_provider: Callable[[], str],
                 host: str = "0.0.0.0") -> None: ...
    def start(self) -> None: ...                         # daemon thread + own asyncio loop
    def stop(self) -> None: ...
    @property
    def port(self) -> int: ...
    def broadcast_json(self, msg: dict, exclude=None) -> None: ...  # thread-safe push to all clients; Doc 02 §10.2 additive `exclude` = connection skipped by identity (`is`); one-arg callers unchanged
# binary  → unpack_live_frame → emit("CAMERA_DELTA") if 0x03 else emit("LIVE_FRAME", frame=...)
# text    → json envelope      → emit("RPC_MESSAGE", msg=...)
# emits CONNECTION_STATE(connected: bool, peer: str | None)
# bad/missing token → close code 4001
```

**Doc-specific behavior (frozen):**

```python
# connection handler (per client):
#   1. path gate: request.path must be "/ws" (query allowed) — otherwise close, emit nothing
#   2. token gate: parse "?token=" from request.path; missing or != token_provider()
#        → close code 4001 BEFORE any event (token read lazily per connection)
#   3. accept → emit("CONNECTION_STATE", connected=True, peer="<host>:<port>"); track client set
#   4. disconnect/finally → emit("CONNECTION_STATE", connected=False, peer=None); discard client
# binary frame: memoryview(message) zero-copy → len==16 exactly else drop+log
#   unpack_live_frame → seq gate → emit("CAMERA_DELTA", frame=f) if f.frame_type==0x03
#                                   else emit("LIVE_FRAME", frame=f)
# seq gate (u16, per-connection): first frame accepted; newer iff 0 < ((seq - last) % 65536) < 32768;
#   stale/duplicate dropped silently; last_seq updated only on accepted frames (all frame types)
# text frame: json.loads → require keys {id, type, action, canvas_id} else drop+log
#   → emit("RPC_MESSAGE", msg=<dict>)   (payload key contract for OPEN_CANVAS/ASSET/UPGRADE lives with Docs 09/10)
#   → live mutation relay (Doc 02 §10.2): AFTER the emit, if msg.type in {ELEMENT_COMMIT, ARTBOARD_RESIZE}
#        → broadcast_json(msg, exclude=<sending connection>) — every OTHER client receives it, sender gets no
#          echo; non-mutation types (CANVAS_LIFECYCLE, ASSET_UPLOAD, EXPORT_JOB) are never relayed.
#          CLEAR_CANVAS travels as type ELEMENT_COMMIT, so it is relayed alongside the other element commits.
# any per-message exception → logging.getLogger("slatesync.ws") + continue (connection survives one bad frame)
# broadcast_json(msg, exclude=None): json.dumps → asyncio.run_coroutine_threadsafe(_send_all, self._loop) — never blocks,
#   best-effort per client (dead clients dropped, failures logged); callable from ANY thread (Tk, executor);
#   `exclude` (Doc 02 §10.2, round-6 additive) skips ONE connection by identity (`is`) so a relayed mutation
#   never echoes to its sender — existing single-argument callers are unchanged
# port property: actual bound port (config.ws_port=50606 in prod; tests bind ephemeral port via
#   dataclasses.replace(config, ws_port=0))
# wiring (Wave 3.A, main.py): WsStreamServer(bus, config, token_provider=lambda: pairing.session_token)
# stop(): close server, stop loop, join thread ≤5 s — idempotent
```

* Envelope shell check (§4.2): `id` (uuid-v4 string), `type` ∈ the five §3 types, `action` ∈ the **20-action** `RPC_ACTIONS` set (Doc 02 §8.1/§9.1/§10.1 — 14 → 17 → 19 → 20 with `CLEAR_CANVAS`), `canvas_id` string — everything else, including `payload`, passes through untouched.
* `type`/`action` pairs are **not** filtered here beyond that shared membership check: Docs 09/10/15 each select their own subset from the same `RPC_MESSAGE` fan-out; the relay (§10.2) keys only on `type`, never on `payload`.
* Seq gating applies to binary frames only; text frames ignore seq entirely, and per-connection `last_seq` resets to `None` on every reconnect (state never shared between connections).
* Oversized or non-UTF8 text: log + drop that message only — connection stays open and remains in `self._clients`.
* `broadcast_json` with zero clients is a cheap no-op; called before `start()` logs a warning and drops the message (never raises into a GUI thread).

## 5. Implementation Plan
Component map (illustrative signatures):

```python
def _run(self) -> None: ...                            # thread target: new loop → serve() → ready.set() → run_forever()
async def _handler(self, ws) -> None: ...              # path gate → token gate → async-for dispatch → finally: state event
async def _send_all(self, payload: str, exclude=None) -> None: ...  # snapshot clients, skip `exclude` by identity, discard dead sockets, never raise
def _seq_accept(self, last: int | None, seq: int) -> bool: ...   # mod 2^16 newer-than check
```

1. **Lifecycle.** `start()` spawns `threading.Thread(daemon=True, name="ws-stream-server")` running a fresh asyncio loop: `asyncio.run(self._serve())` binds `serve(handler, host, bound_port)` (library async `serve` API pinned by Doc 04), records real port, signals `threading.Event`, `run_forever()`.
2. **Auth + path gate.** In the handler: exact `/ws` path check, `urllib.parse.urlsplit(request.path).query` → `parse_qs` token, compare to `token_provider()`; mismatch/missing → `await ws.close(code=4001)` and return (no events); else emit `CONNECTION_STATE(connected=True, peer=...)` and add to `self._clients`.
3. **Binary path.** `async for message in ws`: bytes → `memoryview` → length check (16) → `unpack_live_frame` (struct `<BBHfff`, no copy) → seq gate → emit `CAMERA_DELTA`/`LIVE_FRAME` with `frame=<LiveFrame>`.
4. **Seq tracker.** Per-connection `last_seq: int | None`; accept first frame; accept iff `0 < ((seq - last_seq) % 65536) < 32768` (handles u16 wrap 65535→1); update only on acceptance; drop silently.
5. **Text path.** `json.loads` inside try/except; validate required envelope keys `{id, type, action, canvas_id}` from §4.2 against the 20-action `RPC_ACTIONS`/5-type enums; emit `RPC_MESSAGE(msg=msg)`; malformed JSON or missing keys → warn + continue. **Round-6 relay (Doc 02 §10.2):** immediately AFTER the emit, if `msg["type"] in {"ELEMENT_COMMIT", "ARTBOARD_RESIZE"}` (so `CLEAR_CANVAS` included) → `broadcast_json(msg, exclude=<sender connection>)`; `CANVAS_LIFECYCLE`/`ASSET_UPLOAD`/`EXPORT_JOB` are never relayed. Receiving endpoints apply the rule from Doc 02 §10.2/§10.1 (PC always; devices only for their open document).
6. **`broadcast_json(msg, exclude=None)`.** Serialize once, `asyncio.run_coroutine_threadsafe(self._send_all(payload, exclude), self._loop)` (fire-and-forget, futures observed only for logging); `_send_all` iterates a snapshot of `self._clients`, skips the `exclude` connection by identity (`is`), discarding closed sockets on error. Existing one-argument callers behave exactly as before.
7. **Connection state.** `finally:` block per connection emits `CONNECTION_STATE(connected=False, peer=None)` exactly once and removes the client — GUI badge (Doc 16) stays consistent even on abrupt drops.
8. **Graceful `stop()`.** Schedule server close via `run_coroutine_threadsafe(...).result(timeout=...)`, then `loop.call_soon_threadsafe(loop.stop)`, join thread ≤5 s; safe to call twice.
9. **Reconnect independence.** Every connection gets fresh `last_seq`, client-set membership, and events — a tablet reconnect replays Doc 25’s offline RPC queue onto a clean pipeline with no stale-seq interference.
10. **No payload interpretation.** Dispatch is `emit`-only: this module never imports `engine/*` (Docs 09/10) and never inspects `payload` keys — all key contracts belong to the emitting/subscribing docs.

## 6. Testing & Acceptance Criteria (`test_ws_stream_server.py`, `test_wave1_mirror_pipeline.py`)
* **Auth:** valid token → `CONNECTION_STATE(True)`; missing or wrong token → close code `4001`, zero bus events; non-`/ws` path → closed, zero events.
* **Dual path routing:** 16-byte `FRAME_LIVE_POINT` → `LIVE_FRAME` with exact fields; `FRAME_CAMERA (0x03)` → `CAMERA_DELTA`; 15-byte payload dropped without crash; valid JSON → `RPC_MESSAGE` dict equality; invalid JSON logged, connection stays open.
* **Seq rule:** reordered seq dropped, duplicates dropped, wrap `65535→1` accepted, per-connection isolation (client B unaffected by client A’s seq).
* **Thread safety:** `broadcast_json` called from a foreign (non-loop) thread reaches all clients; one dead client doesn’t block others.
* **Mirror pipeline (`test_wave1_mirror_pipeline.py`):** `pack_live_frame` → send → bus → Doc-06-style latest-slot subscriber: fields identical, ordering preserved by seq, camera frames routed to their own handler (no latency gate — that belongs to Doc 28).
* **Seq table (unit):** `_seq_accept(None, any)` accept; `(100,101)` accept; `(100,100)` drop; `(100,99)` drop; `(65535,1)` accept (wrap); `(100,32868)` drop (half-window).
* **Lifecycle:** `start()` twice / `stop()` twice are safe; `port` equals the actually bound port; `stop()` joins the daemon thread ≤5 s (no leaked threads across the test suite).
* **`CONNECTION_STATE` exactly-once:** a client vanishing without a close frame still emits one `(False, None)`; a valid connect never emits `(False, …)` first.
* **Envelope fidelity:** `OPEN_CANVAS` / `UPGRADE_SIZE` / `ASSET_CHUNK` envelopes sent by a Doc-25-style client reach `RPC_MESSAGE` subscribers (Docs 10/09/15) with `type/action/payload` unchanged; an envelope with an action outside the 20-action set is dropped at shell validation.
* **Live mutation relay (Doc 02 §10.2):** with devices A + B (+ GUI) connected, an `ELEMENT_COMMIT` (incl. `CLEAR_CANVAS`) or `ARTBOARD_RESIZE` envelope from A reaches B and the GUI with `type/action/payload/canvas_id` byte-identical AFTER `RPC_MESSAGE` fires, and never comes back to A; `CANVAS_LIFECYCLE`/`ASSET_UPLOAD`/`EXPORT_JOB` messages are not relayed; `broadcast_json(msg)` (no `exclude`) still reaches every client.
* **Fan-out:** `broadcast_json` called from a foreign thread reaches N concurrent clients (GUI + tablet); a client that closed mid-broadcast is discarded without raising.
* **Token liveness:** `token_provider` is invoked per connection attempt — swapping its target later affects only new connections; established ones stay open (documented v1 behavior).

## 7. Parallel Execution Notes
* **Wave 1.B** — Session 1, Subagent 3 (“PC WebSocket & Discovery”) executes Doc 11 + Doc 12; all Batch-3 docs (09/10/11/12) are Wave 1.B per template §6.
* Zero overlap confirmed: Creates (`network/__init__.py`, `network/ws_stream_server.py`, both listed tests) are exclusive to Doc 11 — Doc 12 owns `discovery_pairing.py` + its test; Docs 09/10 own `engine/*`; Docs 06/07 own `viewport/*`.
* **Never touches:** Doc 12’s `discovery_pairing.py`/test, `pc_agent/engine/*` (Docs 09/10), `pc_agent/core/*` (Doc 04), `pc_agent/viewport/*`, `shared_specs/*`, `pc_agent/main.py`, `mobile_app/*` — Doc 12’s token arrives only through the injected `token_provider`.
* Intra-batch contracts (all authored in this batch): server emits exactly the envelopes Docs 09/10/15 subscribe to; Doc 12 supplies `session_token` behind `token_provider`; Docs 09/10 never import `network/*`.

---

## 10. Round-8 Amendment — Canvas Deletion Propagation (NORMATIVE)

Deleting a canvas on a tablet used to leave it on the PC forever: `CANVAS_LIST` merge is
union-by-id with LWW, so an absent row simply kept the hub copy. The frozen action enum has no
`CANVAS_DELETE` and none may be added.

`CanvasSyncManager` therefore treats a device's `CANVAS_LIST` as a **snapshot of what that device
still holds**:

1. `_track_device_deletions(device_id, ids)` records the id set per device; the FIRST list from a
   device only establishes a baseline, so a freshly connected tablet cannot wipe the hub.
2. `previous_ids − current_ids` are tombstones: `_forget_canvas` drops them from `_local_rows`,
   `_device_rows`, the pending-pull queue, `LocalCanvasIndex` (row + archive),
   `DocumentStore.forget` (open document + uploaded assets), and clears the mirror selection when it
   pointed at the deleted canvas.
3. Tombstoned ids are excluded from `_merged()` and from `_plan_pulls()`, so neither a stale hub row
   nor a retrying device can resurrect them.
4. The hub then broadcasts the merged list as usual, which removes the canvas from every other
   tablet.

State added is in-process only (`_device_known_ids`, `_deleted_ids`) — the wire contract is
unchanged. Acceptance: `pc_agent/tests/test_canvas_sync_hub.py` (deletion, no-resurrection,
no-re-pull, mirror clearing, fresh-device safety).