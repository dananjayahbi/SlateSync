# Doc 25: Flutter WebSocket Vector Sync Client

## 1. Objective & Scope
Implement the Dart synchronization engine: mDNS discovery of the PC agent, QR/manual pairing, token-authenticated WebSocket connection with a resilient state machine, 16-byte binary live-frame send path with a single per-connection u16 sequence counter shared by all frame types, offline RPC buffering, and a receive path that surfaces Doc 02 envelopes (RPC, export progress, asset file chunks) as a `Stream<SyncEvent>`. This doc **exports** `PairingInfo` and `VectorSyncClient` exactly as frozen in template §5; it **consumes** Doc 05 `WireCodec`/`FrameType`/`ToolId` and mirrors Doc 11 server behaviors (port `50606`, path `/ws`, close code `4001`, QR payload scheme).

## 2. File Ownership
### Creates (implementation subagent writes these paths)
- `mobile_app/lib/network/vector_sync_client.dart`
- `mobile_app/test/vector_sync_client_test.dart`

### Read-only dependencies (imports, each cited as "Doc NN")
- Doc 05 `mobile_app/lib/core/models/canvas_models.dart` — `FrameType`, `ToolId`, `LiveFrame`, `WireCodec.buildFrame`
- Doc 05 pubspec — `web_socket_channel`, `multicast_dns`, `mobile_scanner`, `path_provider`
- Doc 02 `shared_specs/ws_rpc_schema.json` + `shared_specs/binary_stream_frame.json` — envelope/asset-chunk field names, seq rule
- Doc 11 `pc_agent/network/ws_stream_server.py` — server behaviors (read-only): `/ws?token=`, `4001` close, dual binary/JSON routing
- Doc 12 `pc_agent/network/discovery_pairing.py` — mDNS service `_slatesync._tcp.local.`, TXT `{v:"1", token:…}`, QR payload `slatesync://connect?ip=<ipv4>&port=50606&token=<token>`

### Never touches (paths owned by concurrent docs — write-conflict guard)
`pc_agent/**`, `shared_specs/**` (Docs 01–03 own writes), `mobile_app/lib/core/models/canvas_models.dart` (Doc 05), `mobile_app/lib/canvas_engine/**` (Docs 20–23), `mobile_app/lib/features/**` (Docs 24/26/27), `mobile_app/lib/main.dart` (Doc 05 stub; Wave 3.A wires it)

## 3. Contract References
- Template §3: WebSocket port `50606`, path `/ws`, URL `ws://<ipv4>:50606/ws?token=<session_token>`, close code `4001`; mDNS `_slatesync._tcp.local.` name `SlateSync`, TXT `{v:"1", token:<session_token>}`; binary frame 16 bytes LE `"<BBHfff"`; FrameType `0x01–0x04`; ToolId `0x01–0x04`; seq rule u16 per-connection monotonic, receivers drop non-newer frames (mod $2^{16}$ window); asset chunks `data_b64` ≤ `262144` raw with `transfer_id, filename, total_chunks, size_bytes, index, data_b64`
- Doc 02 §4.2 envelope: `id` (uuid-v4), `type`, `action`, `canvas_id`, `payload`, `timestamp`; actions incl. `START_EXPORT`, `CANCEL_EXPORT`, `EXPORT_PROGRESS`, `ASSET_START/CHUNK/DONE`
- Doc 11 behaviors: bad/missing token ⇒ server closes `4001`; text ⇒ JSON envelope; binary ⇒ live frame

## 4. Interface Freeze
**Exported — verbatim from template §5 (this doc owns these):**
```dart
class PairingInfo { final String ipv4; final int port; final String token; }  // Doc 25
class VectorSyncClient {                                          // Doc 25
  Future<void> discover();                                        // mDNS _slatesync._tcp.local. (3 s)
  Future<void> connect(PairingInfo info);                         // ws://ip:50606/ws?token=…
  bool get isConnected;
  void sendLiveFrame(int frameType, int toolId, double f1, double f2, double f3); // via WireCodec
  Future<void> sendRpc(Map<String, dynamic> envelope);            // §4.2 envelope, uuid-v4 id
  Stream<SyncEvent> get events;                                   // EXPORT_PROGRESS, file chunks…
  void flushOfflineQueue();                                       // ring buffer ≤5000 RPC; live frames dropped offline
}
```
**Consumed — Doc 05 (verbatim, template §5):**
```dart
class FrameType { static const livePoint=0x01, liveEnd=0x02, camera=0x03, laser=0x04; }
class ToolId    { static const pen=0x01, highlighter=0x02, eraser=0x03, shapePreview=0x04; }
class WireCodec {
  static ByteData buildFrame({required int frameType, required int toolId,
      required int seq, required double f1, double f2=0, double f3=0}); // 16B LE <BBHfff>
  static LiveFrame decodeFrame(Uint8List bytes);
}
```
**Consumed — Doc 11 server behaviors (read-only contract, no import — Python side):**
- Connect URL `ws://<ipv4>:50606/ws?token=<session_token>`; missing/wrong token ⇒ server closes with code `4001`
- Server routes ≤16-byte binary frames (stale-drop on non-newer seq, mod $2^{16}$) and text JSON envelopes (Doc 02 §4.2)
- Server pushes tablet-bound messages (`EXPORT_PROGRESS`, `ASSET_UPLOAD` chunks) as text envelopes via `broadcast_json`
**Doc-specific API (added):**
```dart
enum SyncState { idle, discovering, connecting, online, backoff, authFailed }
enum SyncEventKind { stateChanged, rpcReceived, progress, fileChunk, fileReceived }
class SyncEvent {
  final SyncEventKind kind; final SyncState? state;
  final Map<String, dynamic>? msg;                 // rpcReceived payload (Doc 02 envelope)
  final String? jobId; final double? percent;      // progress (EXPORT_PROGRESS)
  final String? transferId; final int? index; final Uint8List? data;  // fileChunk
  final String? path;                              // fileReceived (reassembled temp file)
}
class PairingScanner extends StatefulWidget {      // mobile_scanner widget
  const PairingScanner({super.key, required this.onPair});
  final void Function(PairingInfo info) onPair;     // parses slatesync://connect?ip=&port=&token=
}
PairingInfo parsePairingUrl(String raw);           // throws FormatException on invalid input
String uuidV4();                                   // Random.secure() helper — no uuid package
Future<File> writeExportTemp(String transferId, int totalChunks, Map<int, Uint8List> parts);
```

**State machine (transitions emit `StateChanged`):**

| From | Trigger | To | Notes |
|---|---|---|---|
| `idle` | `discover()` | `discovering` | 3 s mDNS timeout ⇒ throw + fallback |
| `discovering` | TXT+A parsed | `connecting` | `PairingInfo(ip, port, token)` |
| `connecting` | WS open ok | `online` | flush offline queue here |
| `connecting`/`online` | error/close ≠ 4001 | `backoff` | 0.5, 1, 2, 4, 8 s, cap 8 s, unlimited retries |
| `backoff` | timer elapses | `connecting` | re-connect with same `PairingInfo` |
| any | close code `4001` | `authFailed` | terminal — re-scan QR required (`auth_failed` state per task spec; camelCase enum for `flutter analyze` lint compliance) |

## 5. Implementation Plan
1. **Discovery** — `discover()`: `MulticastDns` browse `_slatesync._tcp.local.` with **3 s timeout** (throw `TimeoutException`; caller falls back to manual entry). Resolve the service, parse TXT attribute `token`, take the first IPv4 A-record and SRV port from `ServiceInfo`, return `PairingInfo(ipv4, port, token)`.
2. **QR pairing UI** — `PairingScanner(onPair)`: `MobileScanner` onDetect → if frame text matches `slatesync://connect?…` call `onPair(parsePairingUrl(text))` once (debounced). `parsePairingUrl` table: `slatesync://connect?ip=192.168.1.7&port=50606&token=abc` ⇒ valid; missing `ip`/`token`, non-integer `port`, foreign scheme, empty string ⇒ `FormatException`.
   **Manual IP entry fallback screen** — when `discover()` times out or the camera is unavailable, show `ManualPairingScreen` with three fields (IPv4, port defaulting to `50606`, token) → validates IPv4 octets/1–65535 port/non-empty token → builds `PairingInfo` → `connect(...)`. Same entry point also used to re-pair after `authFailed`.
3. **Connection state machine** — `connect(info)` opens `WebSocketChannel.connect('ws://ip:50606/ws?token=…')`; states `idle → discovering → connecting → online`; on drop → `backoff` with delays **0.5, 1, 2, 4, 8 s** (cap 8 s, **unlimited retries**, re-emit `stateChanged` each hop). Close code **4001** ⇒ terminal `authFailed` state (task's `auth_failed`; no retry — user must re-scan the QR or re-enter pairing info).
4. **Send path (live)** — `sendLiveFrame` builds bytes via Doc 05 `WireCodec.buildFrame`. Per-`frameType` u16 counters (`Map<int,int>`); increment `seq = (seq + 1) & 0xFFFF` after each send — **65535 → 0 wrap accepted** (Doc 02 monotonic mod $2^{16}$). Camera (`0x03`) throttled ≤ 60 Hz with drop-if-unsent (latest slot). **Offline: live frames are DROPPED** (never queued).
5. **Send path (RPC)** — `sendRpc` fills `id` (uuid-v4 via `uuidV4()`), `timestamp` (unix seconds) if absent, validates `type/action/canvas_id/payload` per §4.2. Offline ⇒ append to **ring buffer ≤ 5000, FIFO** (5001st evicts oldest). `flushOfflineQueue()` on `online` replays in order, then clears.
6. **Receive path** — text frames parsed as Doc 02 envelopes → `Stream<SyncEvent>` (`StreamController.broadcast`): `rpcReceived{msg}` always; `action == EXPORT_PROGRESS` ⇒ also `progress{jobId, percent}`; `type == ASSET_UPLOAD` route: `ASSET_START` opens an out-of-order buffer keyed `transferId`, `ASSET_CHUNK` stores `parts[index]` (any order), `ASSET_DONE` verifies `totalChunks`/`size_bytes`, concatenates index 0..n-1, writes temp file via `path_provider` ⇒ `fileReceived{path}`; **mismatch ⇒ abort** (drop buffer, no event). `StateChanged` emitted on every transition.
7. **Envelope shape (self-check against Doc 02 §4.2 example)** — `sendRpc` accepts/maps exactly these fields; tests assert them on the fake channel:

   ```json
   { "id": "8f2c…-4…-9…", "type": "ELEMENT_COMMIT", "action": "ADD_STROKE",
     "canvas_id": "canvas-uuid-v4", "payload": { }, "timestamp": 1760760000 }
   ```
   `timestamp` = unix seconds; if the caller omits `id`/`timestamp`, `sendRpc` fills both (uuid-v4 via `uuidV4()`), otherwise caller-supplied values pass through untouched.
8. **Offline matrix** — live frames (`sendLiveFrame`): **dropped** when `!isConnected`; RPC (`sendRpc`): ring-buffered (≤ 5000, FIFO); `flushOfflineQueue()`: replay on first `online`, clear only after all writes are accepted by the sink; `authFailed`: ring retained but **no** auto-flush (requires re-pair).
9. **Camera throttle** — camera frames (`FrameType.camera == 0x03`) are rate-limited client-side to ≤ 60 Hz (one frame / 16 ms): if the previous camera frame is still unsent in a latest-slot buffer, the older slot value is replaced (**drop-if-unsent**, never queued); pen `LIVE_POINT` frames are not throttled.
10. **Discovery details** — `ServiceInfo` parsing: TXT key `token` (bytes → UTF-8), IPv4 = first A-record that is not loopback, port from the SRV record (fallback `50606`); TXT missing `token` or zero A-records ⇒ treat as discovery failure (throw `StateError`, caller shows manual entry).
11. **Tests** — see §6; no widget/network mocks beyond fakes for the channel sink.

## 6. Testing & Acceptance Criteria
- **Envelope assertions** vs Doc 02 example: captured `sendRpc` map has keys `id, type, action, canvas_id, payload, timestamp`; `id` matches uuid-v4 regex `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`.
- **Envelope example fidelity**: `{"id","type","action","canvas_id","payload","timestamp"}` key set equals Doc 02 §4.2 example — no extra/missing top-level keys.
- **Seq wraparound**: drive 65536 `sendLiveFrame` calls; byte-parsed seq ends `65535 → 0 → 1`, all frames 16 bytes; interleaving `camera` and `livePoint` frames shares ONE monotonic counter (strictly increasing across frame types, matching Doc 11's single `last_seq`).
- **Ring eviction**: enqueue 5001 offline RPCs ⇒ buffer length 5000, oldest (seq #1) gone, order preserved.
- **Offline drop rule**: `sendLiveFrame` while disconnected ⇒ zero channel writes; `sendRpc` while disconnected ⇒ buffered, flushed by `flushOfflineQueue()` after reconnect.
- **QR URL parse table**: 1 valid + 4 invalid cases as in step 2; manual-entry builder rejects `999.1.1.1` and port `0`.
- **Chunk reassembly**: feed `ASSET_START` + 8 shuffled `ASSET_CHUNK` events ⇒ temp file byte-equals source; truncated/duplicate-total ⇒ aborted, no `fileReceived`.
- **Backoff ladder**: force 5 consecutive connect failures ⇒ recorded retry delays are `0.5, 1, 2, 4, 8` and subsequent delays stay `8` (cap); close `4001` ⇒ single transition to `authFailed`, no further retries.
- **State events**: every transition emits one `stateChanged` event with the new `SyncState`.
- `flutter analyze` clean; connection test uses a fake `StreamChannel` — no real sockets.

## 7. Parallel Execution Notes
- **Wave 1.B** (Session 1, Subagent 6 per `overview.md` §6; template matrix row 25 → 1.B). Blocked only by the Wave 1.A barrier (Doc 05 `WireCodec` + pubspec deps must exist).
- Seq-rule note (reconciled): ONE per-connection u16 counter shared by all frame types — template §3, Doc 02 and Doc 11's single `last_seq` gate all lock this. The client increments it once per frame sent, so interleaved camera/live frames remain strictly increasing and Doc 11's mod-2^16 newer-than gate accepts every frame.
- Zero file overlap with sibling 1.B docs (20/21/22/23 own `canvas_engine/`; 06–12 own `pc_agent/`). Exports (`PairingInfo`, `VectorSyncClient`, `SyncEvent`, `PairingScanner`) are consumed later by Docs 24/26/27 and Wave 3.A without editing this file.
- **Never touches:** `pc_agent/**`, `shared_specs/**`, `mobile_app/lib/core/**` (Doc 05), `mobile_app/lib/canvas_engine/**` (Docs 20–23), `mobile_app/lib/features/**` (Docs 24/26/27), `mobile_app/lib/main.dart`.

## 8. Round-7 Amendment — Persistent Pairing & Silent Reconnect (NORMATIVE)

The PC now keeps a **static** pairing token (`pc_agent/network/pairing_store.py`,
Doc 12 §8), so one QR scan must stay valid forever. The tablet therefore remembers
its last successful pairing and dials it again on launch.

### 8.1 `network/pairing_credentials_store.dart` (new)
```dart
class PairingCredentials {                       // immutable value object
  PairingCredentials({required String host, required int port,
                      required String token, String? deviceName});
  factory PairingCredentials.fromPairingInfo(PairingInfo info, {String? deviceName});
  factory PairingCredentials.fromJson(Map<String, dynamic> json);   // FormatException if bad
  Map<String, dynamic> toJson();                  // {version, host, port, token, device_name}
  PairingInfo toPairingInfo();
}

class PairingCredentialsStore {
  PairingCredentialsStore({String? filePath});    // null ⇒ path_provider app-support
  static const String fileName = 'slatesync_pairing.json';
  Future<PairingCredentials?> load();             // null ⇒ none / corrupt / unreadable
  Future<void> save(PairingCredentials credentials);
  Future<void> clear();
}
```
Same storage mechanism as `DeviceIdentity` (`features/sync/hub_sync.dart`) — no new
package dependency. Reads/writes never throw; the token is masked in `toString()`.

### 8.2 `features/pairing/pairing_session_controller.dart` (new)
`PairingSessionController({required VectorSyncClient client, PairingCredentialsStore?
store, String? deviceName, Duration attemptTimeout = 8s})` watches the Doc 25
`events` stream:
* `autoConnect() -> Future<bool>` — loads the saved pairing and connects; returns
  `true` once `SyncState.online`. A `SyncState.authFailed` (close `4001`, i.e. the PC
  rotated its token) **forgets** the credentials and returns `false`; any other failure
  keeps them (PC off / different network). Never throws, bounded by `attemptTimeout`.
* save-on-online — every transition to `SyncState.online` persists
  `client.pairing` (so QR scan, manual entry, mDNS discovery and the auto-connect all
  become the remembered pairing); duplicate saves are skipped.
* `forget()`, `dispose()`, and the `kPairingAutoConnectFailedNotice` /
  `kPairingAuthFailedNotice` copy used by the UI.

### 8.3 Shell wiring (`main.dart`)
`SlateSyncApp` gains three optional seams: `credentialsStore`, `deviceName` and
`autoConnect` (default `true`). On start it runs `_restorePairing()`: nothing saved ⇒
the home gallery stays (existing "Connect" entry point); saved but unreachable ⇒
`PairingScreen(notice: …)` is pushed with the failure copy. The gallery remains usable
offline and the app never hangs on a dead pairing. `PairingScreen` gains an optional
`notice` string (key `pairing-auto-connect-notice`) rendered above the pairing modes.

### 8.4 Device identity on open (`features/sync/canvas_sync_bridge.dart`)
`announceOpen` now also sends `payload.device_id` / `payload.device_name` from the
persisted `DeviceIdentity`, so the PC hub can attribute an `OPEN_CANVAS` to a device in
its roster (Doc 02 §11.1/§11.2). The §8.2 `payload.canvas` body and every existing key
are unchanged; the identity keys are omitted when no identity file exists.

### 8.5 Tests (`test/pairing_credentials_store_test.dart`)
JSON round-trip and validation (legacy `ipv4` key tolerated), store save/load/clear
against an injected path, corrupt/unwritable files, controller auto-connect
success/timeout/throw/auth-failure, save-on-online, the `PairingScreen` notice, and
three shell-level auto-connect widget tests. `test/sync_canvas_bridge_test.dart` asserts
the additive identity keys.

## 9. Round-7 Amendment — Visible Pairing Outcomes (NORMATIVE)

Fixes the reported regression "when I scan the QR it doesn't catch the device. Also it
says nothing." The shell told the user nothing because the scan path popped the screen
before the handshake had any chance to fail.

### 9.1 Root cause
`_PairingScreenState._onPaired` called `client.connect(info)` fire-and-forget and
popped immediately. A timeout, a closed socket or a `4001` rejection therefore looked
exactly like success: back on the gallery with no message and no connection.

### 9.2 `features/pairing/pairing_attempt_controller.dart` (new)
`PairingAttemptController({client, timeout = 12 s})`:
* `start(PairingInfo)` — subscribes to `client.events` **before** dialling (a fast
  `online` is never missed), calls `connect`, and settles on the first terminal state.
* `ValueNotifier<PairingAttemptStatus> status` — `idle | connecting | online |
  authFailed | unreachable`.
* `ValueNotifier<String?> message` — `kPairingConnectingNotice`, `kPairingRejectedNotice`
  or `kPairingTimeoutNotice(info)` (names the `ip:port` that did not answer).
* After the timeout it **keeps listening**: the Doc 25 backoff ladder may still reach
  `online`, which clears the failure (`unreachable → online`). A late `authFailed`
  replaces the timeout notice.
* `cancel()` (user pressed Cancel) and `dispose()`; `start` is ignored while another
  attempt is `connecting`.

### 9.3 `features/pairing/pairing_progress_card.dart` (new)
`PairingProgressCard(busy, message, onCancel, onRetry)` — key `pairing-progress`, a
spinner (`pairing-progress-spinner`) while busy plus Cancel, otherwise an error icon
plus "Try again" (`pairing-progress-retry`).

### 9.4 `PairingScreen` behaviour
* Scan: `_showScanner` turns off (the camera stops re-decoding the same code) and the
  attempt starts; the screen **stays open** until the outcome is known.
* `online` ⇒ the screen pops (key `pairing_screen` disappears).
* `unreachable` / `authFailed` ⇒ stays open with the progress card and a retry.
* Manual entry pops only its own route, so its result is reported on the same card;
  `online` then unwinds the pairing screen too.
* Auto-discover: when mDNS resolved an address but the socket is not up yet, the same
  card reports the handshake instead of a silent pop.

### 9.5 Android manifest
`android/app/src/main/AndroidManifest.xml` now declares `INTERNET`,
`ACCESS_NETWORK_STATE` and `CAMERA` explicitly and sets
`android:usesCleartextTraffic="true"` — Doc 11/25 dial a plaintext `ws://` LAN URL, and
the permission previously arrived only as a side effect of a plugin manifest merge.

### 9.6 Tests
`test/pairing_attempt_controller_test.dart` (online / rejected / timeout-with-address /
throwing `connect` / late `online` after timeout / late `authFailed` / cancel /
concurrent start), plus `test/pairing_flow_test.dart`
(`unreachable PC keeps the screen and explains the failure`,
`rejected token is reported instead of popping`).
