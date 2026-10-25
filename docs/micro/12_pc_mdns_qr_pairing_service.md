# Doc 12: mDNS Discovery & QR Pairing Service

## 1. Objective & Scope
* Broadcasts `_slatesync._tcp.local.` (instance `SlateSync`, TXT `{v:"1", token:<session_token>}`) via `zeroconf` so the tablet finds the PC with zero configuration, and renders a pairing QR whose payload carries LAN IPv4, port `50606`, and the session token for the Doc 25 scanner.
* `session_token` is the single token authority: Doc 11 reads it lazily through `token_provider`, so a bad/missing token closes with code `4001`.
* Emits `PAIRING_INFO(ipv4, port, token, qr_png_path)` consumed by Doc 16’s QR dialog. Token is stable for the process lifetime (v1: rotation requires restart of both peers).
* The QR is the fallback path when mDNS multicast is filtered (guest Wi-Fi / AP isolation): scanning still yields ip/port/token, so discovery and pairing are independent routes to the same Doc 11 handshake.
* `start()` runs on the Tk main thread (called by `main.py`/Doc 16) and `EventBus.emit` is synchronous there — Doc 16’s `PAIRING_INFO` handler must marshal widget work with `after(0, ...)` per the template threading model.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
* `pc_agent/network/discovery_pairing.py`
* `pc_agent/tests/test_discovery_pairing.py`

### Read-only dependencies (imports, each cited as "Doc NN")
* `pc_agent/core/events.py` (`EventBus`) and `pc_agent/core/config_manager.py` (`AppConfig`) — Doc 04
* `config.ws_port` / `mdns_service_type` / `mdns_service_name` / `appdata_dir` (Doc 04) — the same constants Doc 11 binds (`50606`)
* `zeroconf`, `qrcode` (requirements, Doc 04); stdlib `secrets`, `socket`, `pathlib`
* Consumers of its outputs: Doc 11 (`token_provider`), Doc 16 (`PAIRING_INFO`), Doc 25 (mDNS TXT + QR payload) — cited, never imported

### Never touches (paths owned by concurrent docs — write-conflict guard)
* `pc_agent/network/ws_stream_server.py`, `pc_agent/network/__init__.py`, `pc_agent/tests/test_ws_stream_server.py`, `pc_agent/tests/test_wave1_mirror_pipeline.py` (Doc 11)
* `pc_agent/engine/*` (Docs 09/10); `pc_agent/core/*`, `pc_agent/main.py` (Doc 04); `pc_agent/viewport/*` (Docs 06/07/08); `shared_specs/*` (Docs 01–03); `mobile_app/*` (Docs 05, 20–27)

## 3. Contract References
* `overview.md` §4.2 (token-authenticated connect URL), §5 Doc 12 entry, §6 Wave 1.B.
* `_micro_doc_template.md` §3 (mDNS service `_slatesync._tcp.local.`, name `SlateSync`, TXT `{v:"1", token:<session_token>}`, port `50606`), §4 (`DiscoveryPairing` freeze + `PAIRING_INFO` + QR payload verbatim below; `EventBus`/`AppConfig` from Doc 04; event matrix), §6 ownership matrix.
* Intra-batch chain: this token flows Doc 12 → Doc 11 `token_provider` → close `4001` on mismatch; Doc 16 renders `PAIRING_INFO.qr_png_path`; Doc 25 parses the `slatesync://connect?...` payload and dials Doc 11.
* All numbers (`50606`, `_slatesync._tcp.local.`, `SlateSync`, TXT `{v:"1", token:<session_token>}`) are copied from template §3 / `config` fields — never re-derived or hardcoded locally.

## 4. Interface Freeze
**Verbatim from template §4 — `DiscoveryPairing`, do not modify:**

```python
class DiscoveryPairing:                                 # Doc 12
    def __init__(self, bus: EventBus, config: AppConfig) -> None: ...
    def start(self) -> None: ...                         # zeroconf register + QR render
    def stop(self) -> None: ...
    @property
    def session_token(self) -> str: ...
# emits PAIRING_INFO(ipv4: str, port: int, token: str, qr_png_path: str)
# QR payload: slatesync://connect?ip=<ipv4>&port=50606&token=<token>
```

**Doc-specific behavior (frozen):**

```python
# session_token: secrets.token_urlsafe(32) generated once in __init__ — property returns the SAME
#   string for the object's lifetime (Doc 11 may call it on every connection attempt)
# start():
#   ipv4  = self._lan_ipv4()          # UDP-connect trick, non-loopback; fallback getaddrinfo(hostname);
#                                     # last resort "127.0.0.1" + warning log
#   info  = ServiceInfo(type=config.mdns_service_type,          # "_slatesync._tcp.local."
#            name="SlateSync._slatesync._tcp.local.",           # config.mdns_service_name + type
#            port=config.ws_port,                               # 50606
#            addresses=[inet_aton(ipv4)],
#            properties={"v": "1", "token": self._token})       # TXT {v:"1", token:<session_token>}
#   zeroconf.register_service(info)
#   qr_png_path = config.appdata_dir/"pairing_qr.png"           # dir mkdir(parents=True, exist_ok=True)
#   qrcode payload = _pairing_payload(ipv4, config.ws_port, self._token)
#   emit("PAIRING_INFO", ipv4=ipv4, port=config.ws_port, token=self._token, qr_png_path=str(path))
# stop(): zeroconf.unregister_service(info); zeroconf.close() — idempotent, emits nothing
# _pairing_payload(ip, port, token) -> str == f"slatesync://connect?ip={ip}&port={port}&token={token}"
# wiring (Wave 3.A, main.py): WsStreamServer(bus, config, token_provider=lambda: pairing.session_token)
```

**`ServiceInfo` fields (frozen):**

| field | value |
|---|---|
| `type` | `_slatesync._tcp.local.` (`config.mdns_service_type`) |
| `name` | `SlateSync._slatesync._tcp.local.` (`config.mdns_service_name` + type) |
| `port` | `50606` (`config.ws_port` — the port Doc 11 binds) |
| `addresses` | `[inet_aton(<lan IPv4>)]` (exactly one A record) |
| `properties` | `{v: "1", token: <session_token>}` (TXT, exact strings) |

* `_lan_ipv4()` resolution order (each fallback logged):
  1. UDP-connect probe → primary LAN IPv4 (`connect()` on a datagram socket sends no packet).
  2. `getaddrinfo(gethostname())` scan → first non-loopback `AF_INET` address.
  3. Literal `127.0.0.1` + `warning` — pairing then only usable from this machine.
* The QR PNG is rewritten on every `start()` at the same `appdata_dir` path; Doc 16 must re-read `PAIRING_INFO.qr_png_path` after each emit (file may have changed).
* Payload query-parameter order is fixed `ip`, `port`, `token` — Doc 25 parses by key, but tests assert the exact canonical string.
* Both TXT `port` and QR `port` come from `config.ws_port` (never a literal) so replaced-config tests stay honest; mDNS TTL/renewal is left to zeroconf defaults — v1 never re-emits `PAIRING_INFO` spontaneously (exactly one emit per successful `start()`).

## 5. Implementation Plan
1. **Token minting.** `__init__` stores `bus/config`, generates `self._token = secrets.token_urlsafe(32)`, `self._zc: Zeroconf | None = None`, `self._info: ServiceInfo | None = None`; `session_token` property returns `self._token`.
2. **IPv4 selection.** `_lan_ipv4()`: `socket(AF_INET, SOCK_DGRAM)` + `connect(("8.8.8.8", 80))` (sends nothing) → `getsockname()[0]`; reject `127.*` via `getaddrinfo(gethostname())` scan; final fallback `127.0.0.1` with a logged warning.
3. **mDNS register.** Build `ServiceInfo` exactly per §4 (type/name/port/TXT) and `zc.register_service(info)`; failures logged and re-raised so `start()` never half-succeeds silently.
4. **QR render.** `qrcode` with the frozen payload → `make_image(...).save(qr_png_path)` (PNG); helper `_pairing_payload` is a pure function so tests assert the exact string, including port `50606`.
5. **Emit `PAIRING_INFO`.** After QR file write succeeds: `bus.emit("PAIRING_INFO", ipv4=..., port=config.ws_port, token=self._token, qr_png_path=str(path))` — Doc 16 reads the file path, no QR state kept elsewhere.
6. **`stop()`.** Unregister service + close zeroconf; set handles to `None`; double-`stop()` and `stop()` without `start()` are no-ops.
7. **Doc 11 hand-off contract.** Token lookup must stay lazy (`lambda: pairing.session_token`) — pairing may be constructed after/before the server; both orders work because the token exists from `__init__` and never changes at runtime.
8. **Tablet contract (Doc 25).** mDNS browse of `_slatesync._tcp.local.` yields TXT `{v, token}`; QR scan yields `ip/port/token`; both must match before dialing `ws://<ip>:50606/ws?token=<token>` — mismatch is answered by Doc 11’s `4001`.
9. **Failure containment.** `register_service` failure logs + raises from `start()` (no half-start, no `PAIRING_INFO` without a written QR file); tests always patch `Zeroconf`, so the suite needs no working multicast stack.

**Pairing sequence (frozen end-to-end order):**

1. PC: `DiscoveryPairing.__init__` mints the token; `WsStreamServer(..., token_provider=lambda: pairing.session_token)` — either construction order works (token exists from `__init__`).
2. PC: `start()` registers mDNS, writes the QR, then emits `PAIRING_INFO`.
3. Tablet: Doc 25 browses `_slatesync._tcp.local.` for `3 s` **or** scans the QR → reads `{ip, port, token}`.
4. Tablet: dials `ws://<ip>:50606/ws?token=<token>` → Doc 11 validates → `CONNECTION_STATE(connected=True, ...)`.
5. Restart: a new PC process mints a new token ⇒ the old tablet token gets `4001` until re-paired (re-scan QR or re-browse mDNS).

## 6. Testing & Acceptance Criteria (`pc_agent/tests/test_discovery_pairing.py`)
* **mDNS record:** with `zeroconf.Zeroconf` mocked/patched, `start()` registers exactly one `ServiceInfo` with type `_slatesync._tcp.local.`, name `SlateSync._slatesync._tcp.local.`, port `50606`, and TXT properties `{v: "1", token: <session_token>}`.
* **Token stability:** repeated `session_token` reads return one value; a `DiscoveryPairing` restarted (`stop()`+`start()`) in the same instance keeps the token (fresh instance ⇒ new token).
* **QR payload:** `_pairing_payload` equals `slatesync://connect?ip=<ipv4>&port=50606&token=<token>` verbatim; PNG file exists at `qr_png_path` (starts with PNG magic `89 50 4E 47`) under `config.appdata_dir`.
* **`PAIRING_INFO`:** emitted once per `start()` with all four fields matching the registered service + file; `stop()` emits nothing and unregisters (mock assertion), idempotent on repeat.
* **IPv4 selection:** loopback results from the socket path are rejected (mocked `getsockname` → `127.0.0.1` falls through to hostname scan/fallback). Token-mismatch close `4001` is asserted in Doc 11’s tests using this `session_token`.
* **No half-start:** a QR write failure propagates from `start()` before any `PAIRING_INFO` emit (never an event pointing at a missing file).
* **Stop discipline:** `stop()` without `start()` and double-`stop()` are no-ops — no unregister calls on a closed `Zeroconf` (asserted on the mock).
* **Fresh profile:** `start()` creates `config.appdata_dir` when absent (first run on a clean Windows profile) before writing `pairing_qr.png`.
* **Restart overwrite:** a fresh instance’s `start()` rewrites `pairing_qr.png` and emits a *different* token in `PAIRING_INFO` (old QR/`4001` behavior covered cross-doc).
* **Port consistency:** `PAIRING_INFO.port == ServiceInfo.port == config.ws_port == 50606` under the default `AppConfig`.
* **Token charset:** `session_token` contains only URL-safe characters (`[A-Za-z0-9_-]`), so it embeds into TXT, QR, and connect URL without percent-encoding.
* **Cross-doc:** Doc 11 rejects any token ≠ `session_token` — verified with a real `DiscoveryPairing` feeding `token_provider` in Doc 11’s auth test.

## 7. Parallel Execution Notes
* **Wave 1.B** — Session 1, Subagent 3 (“PC WebSocket & Discovery”) executes Doc 11 + Doc 12; all Batch-3 docs (09/10/11/12) are Wave 1.B per template §6.
* Zero overlap confirmed: Creates (`network/discovery_pairing.py`, `tests/test_discovery_pairing.py`) are exclusive to Doc 12 — `network/__init__.py`, `ws_stream_server.py` and their tests belong to Doc 11; `engine/*` to Docs 09/10; `viewport/*` to Docs 06/07.
* **Never touches:** Doc 11’s `ws_stream_server.py`/`network/__init__.py`/tests (coupling is only via the injected `token_provider` callable), `pc_agent/engine/*`, `pc_agent/core/*` (Doc 04), `pc_agent/viewport/*`, `shared_specs/*`, `pc_agent/main.py`, `mobile_app/*`.
* Intra-batch contracts (all authored in this batch): Doc 12 mints the token Doc 11 enforces (`4001`); Doc 11 binds port `50606` announced by this TXT/port record; Docs 09/10 are transport-agnostic and never import `network/*`.

## 8. Round-7 Amendment — Static, One-Time Pairing Code (NORMATIVE)

Round 7 changes **only where the token comes from**. Registration, the QR payload,
`PAIRING_INFO` and the `4001` enforcement in Doc 11 are unchanged.

### 8.1 Persistent identity (`network/pairing_store.py`)
* `PairingIdentity(token, device_id, device_name, created_at, qr_payload)` is stored in
  `<appdata_dir>/pairing.json` as
  `{version: 1, token, device_id, device_name, created_at, qr_payload}`.
* `PairingStore(appdata_dir)` → `.load()` / `.load_or_create()` / `.save()` /
  `.rotate()` / `.remember_qr_payload(payload)`; writes are atomic
  (`pairing.json.tmp` → `os.replace`) and reads never raise (a corrupt file is
  re-created).
* Consequence: the token is minted **once per install**. Restarting the app keeps the
  same `session_token`, the same TXT record and the same QR payload, so a tablet that
  paired once keeps handshaking with the credentials it saved (Doc 25) — no re-scan.

### 8.2 QR is written once
`_render_qr(ipv4)` compares the derived payload with the persisted `qr_payload`; when
they match and `pairing_qr.png` exists, nothing is re-encoded. A changed LAN address
(new IP) or a rotated token is the only thing that rewrites the image.

### 8.3 Rotation (Settings → Reset pairing)
`DiscoveryPairing.rotate_token() -> str` stops mDNS (if running), mints a new token
through `store.rotate()`, and returns it; the next `start()` advertises and renders the
new code. Previously paired tablets then fail the Doc 11 handshake with `4001` and must
scan again — the only way to invalidate a pairing.

### 8.4 `PAIRING_INFO` (additive keys)
`PAIRING_INFO` still emits `ipv4, port, token, qr_png_path`, plus the install identity
`device_id` and `device_name` so the tablet can display/label the PC it paired with.
Handlers must keep tolerating unknown keys.

### 8.5 Tests (`tests/test_discovery_pairing.py`, `tests/test_pairing_store.py`)
Persisted token reused across instances sharing `appdata_dir`; different profiles get
different tokens; a restart reuses the PNG byte-for-byte (no `qrcode.make` call);
`rotate_token()` changes the token and forces a rewrite; corrupt/missing files are
re-created without raising.

## 9. Round-7 Amendment — Reachable LAN Address (NORMATIVE)

Fixes the reported regression "when I scan the QR it doesn't catch the device and
says nothing". The pairing record advertised an unreachable address.

### 9.1 Root cause
`_lan_ipv4()` used `connect(("8.8.8.8", 80))` and took whatever the **default route**
produced. On a machine with a VPN / TUN / hypervisor adapter that is the virtual
adapter (observed: `172.19.0.1` on `sing-tun Tunnel #2`, gateway `0.0.0.0`). The QR
therefore encoded an address no tablet on the Wi-Fi LAN can route to, the WebSocket
dial timed out, and nothing was reported.

### 9.2 `network/lan_address.py` (new module)
* `AdapterAddress(address, gateway, description)` with `has_gateway`,
  `looks_virtual`, `is_private`, `awkward` (`looks_virtual or not has_gateway`).
* `score()` / `rank()` — real adapters outrank virtual ones; loopback is always last.
* `enumerate_adapters()` — Windows `GetAdaptersInfo` via `ctypes` (no new dependency);
  returns `[]` off Windows or on any enumeration error, so startup never fails.
* `choose_lan_ipv4(probe, scan, adapters=None)` — runs the documented probe → hostname
  scan → loopback ladder, then **replaces** the candidate when it belongs to an
  `awkward` adapter **and** a real adapter exists. Unknown addresses are kept verbatim,
  so mocked single-interface environments are unaffected.

### 9.3 Contract
`DiscoveryPairing._lan_ipv4()` delegates to `choose_lan_ipv4`; `_scan_hostname_ipv4()`
is the hostname fallback. The chosen address feeds the mDNS `A` record, the QR payload
and `PAIRING_INFO.ipv4` unchanged in shape.

### 9.4 Rotation also restarts mDNS
`rotate_token()` used to `stop()` mDNS and never start again — after "Reset pairing" the
agent was alive but unadvertised and the dialog kept showing the dead QR. When the
service was running it is now stopped, re-minted **and started again**, which re-emits
`PAIRING_INFO` so an open dialog re-renders the new code immediately.

### 9.5 Dialog feedback (`gui/pairing_status.py`)
Scanning used to "say nothing". The QR dialog now carries a hint line and a live status
line: `WAITING_TEXT` before `PAIRING_INFO`, `NO_DEVICE_TEXT`, `"1 tablet connected."` /
`"N tablets connected."` from `DEVICES_UPDATED`, and `reachability_warning(ipv4)` when
the advertised address is loopback / link-local / wildcard.

### 9.6 Tests
`tests/test_lan_address.py` (scoring, ranking, replacement of a TUN candidate, unknown
address preserved, loopback scan fallback, platform shims), `tests/test_pairing_status.py`
(copy derivation) and `tests/test_discovery_pairing.py`
(`test_lan_ipv4_replaces_vpn_candidate_with_real_lan`,
`test_rotate_token_while_running_readvertises_immediately`).
