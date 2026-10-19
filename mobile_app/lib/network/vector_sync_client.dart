/// SlateSync WebSocket vector sync client (Doc 25).
///
/// Exports the frozen `PairingInfo` / `VectorSyncClient` interface of
/// `_micro_doc_template.md` §5 plus the Doc 25 doc-specific API
/// (`SyncState`, `SyncEvent`, `PairingScanner`, `parsePairingUrl`,
/// `uuidV4`, `writeExportTemp`).
///
/// Consumes Doc 05 `WireCodec`/`FrameType`/`ToolId` for the 16-byte binary
/// send path and mirrors Doc 11 server behaviors (port 50606, path `/ws`,
/// close code 4001) with a single per-connection u16 seq counter shared by
/// all frame types (template §3, Doc 02 seq rule).
///
/// All network I/O flows through the injectable [SyncChannel] /
/// [SyncDiscoverer] abstractions so tests never touch real sockets or mDNS.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/models/canvas_models.dart';

// ---------------------------------------------------------------------------
// Master constants (template §3 — copy exactly)
// ---------------------------------------------------------------------------

/// WebSocket port (template §3).
const int kSyncWsPort = 50606;

/// WebSocket path (template §3); URL `ws://<ipv4>:50606/ws?token=<token>`.
const String kSyncWsPath = '/ws';

/// mDNS service type advertised by the PC agent (Doc 12).
const String kMdnsServiceType = '_slatesync._tcp.local.';

/// Close code the server uses for a bad/missing token (Doc 11).
const int kAuthFailedCloseCode = 4001;

/// Offline RPC ring buffer capacity (Doc 25 §8 — FIFO, 5001st evicts oldest).
const int kOfflineRingCapacity = 5000;

/// Raw byte cap per asset chunk before base64 (template §3 / Doc 02).
const int kAssetChunkRawCapBytes = 262144;

/// mDNS browse timeout: on expiry `discover()` throws and the caller falls
/// back to manual entry / QR (Doc 25 §5 step 1).
const Duration kDiscoveryTimeout = Duration(seconds: 3);

/// QR payload scheme (`slatesync://connect?ip=&port=&token=` — Doc 12).
const String kPairingScheme = 'slatesync';

// ---------------------------------------------------------------------------
// Frozen data types (template §5 / Doc 25 §4)
// ---------------------------------------------------------------------------

/// Pairing result: PC agent IPv4, WebSocket port and session token.
class PairingInfo {
  const PairingInfo({
    required this.ipv4,
    required this.port,
    required this.token,
  });

  final String ipv4;
  final int port;
  final String token;

  @override
  bool operator ==(Object other) =>
      other is PairingInfo &&
      other.ipv4 == ipv4 &&
      other.port == port &&
      other.token == token;

  @override
  int get hashCode => Object.hash(ipv4, port, token);

  /// Token is masked so session secrets never reach logs.
  @override
  String toString() => 'PairingInfo(ipv4: $ipv4, port: $port, token: ***)';
}

/// Connection state machine states (Doc 25 §4).
enum SyncState { idle, discovering, connecting, online, backoff, authFailed }

/// `Stream<SyncEvent>` event kinds (Doc 25 §4).
enum SyncEventKind { stateChanged, rpcReceived, progress, fileChunk, fileReceived }

/// Event surfaced by [VectorSyncClient.events].
class SyncEvent {
  const SyncEvent({
    required this.kind,
    this.state,
    this.msg,
    this.jobId,
    this.percent,
    this.transferId,
    this.index,
    this.data,
    this.path,
  });

  final SyncEventKind kind;

  /// New state when [kind] is [SyncEventKind.stateChanged].
  final SyncState? state;

  /// Doc 02 envelope when [kind] is [SyncEventKind.rpcReceived].
  final Map<String, dynamic>? msg;

  /// `job_id` when [kind] is [SyncEventKind.progress] (EXPORT_PROGRESS).
  final String? jobId;
  final double? percent;

  /// Transfer correlation for fileChunk / fileReceived events.
  final String? transferId;
  final int? index;
  final Uint8List? data;

  /// Reassembled temp file path when [kind] is [SyncEventKind.fileReceived].
  final String? path;
}

// ---------------------------------------------------------------------------
// Transport abstraction (testability — Doc 25 §6: fake channel, no real
// sockets or mDNS in tests)
// ---------------------------------------------------------------------------

/// Minimal duplex channel the client drives; the production implementation
/// wraps `package:web_socket_channel`, tests inject a fake.
abstract class SyncChannel {
  /// Completes when the WebSocket handshake succeeds; errors on refusal.
  Future<void> get ready;

  /// Incoming frames: `String` (JSON envelope) or `Uint8List` (binary).
  Stream<dynamic> get stream;

  int? get closeCode;
  String? get closeReason;

  /// Enqueues an outgoing frame; throws if the sink is already closed.
  void add(Object? data);

  Future<void> close([int? closeCode, String? closeReason]);
}

/// Production [SyncChannel] backed by `WebSocketChannel`.
class WebSocketSyncChannel implements SyncChannel {
  WebSocketSyncChannel(this._inner);

  final WebSocketChannel _inner;

  @override
  Future<void> get ready => _inner.ready;

  @override
  Stream<dynamic> get stream => _inner.stream;

  @override
  int? get closeCode => _inner.closeCode;

  @override
  String? get closeReason => _inner.closeReason;

  @override
  void add(Object? data) => _inner.sink.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    try {
      await _inner.sink.close(closeCode, closeReason);
    } catch (_) {
      // cleanup path — a half-open socket may refuse close; ignore
    }
  }
}

/// Opens a channel for a `ws://…` URL.
typedef SyncConnector = SyncChannel Function(Uri url);

/// mDNS discovery step; receives [kDiscoveryTimeout].
typedef SyncDiscoverer = Future<PairingInfo> Function(Duration timeout);

/// Backoff schedule hook; `attempt` is the zero-based failed-attempt index.
typedef BackoffDelayFn = Duration Function(int attempt);

// ---------------------------------------------------------------------------
// Helpers (Doc 25 §4 — no uuid package)
// ---------------------------------------------------------------------------

/// Random uuid-v4 (`xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`) via
/// [Random.secure]; no external dependency (template §5 note).
String uuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10xx
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

bool _isIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    if (!RegExp(r'^\d{1,3}$').hasMatch(part)) return false;
    if (int.parse(part) > 255) return false;
  }
  return true;
}

/// Validates manual-entry fields and builds a [PairingInfo] (Doc 25 §5
/// step 2). Throws [FormatException] on `999.1.1.1`, port `0`/`>65535`,
/// or an empty token.
PairingInfo buildPairingInfo({
  required String ipv4,
  required int port,
  required String token,
}) {
  if (!_isIpv4(ipv4)) throw FormatException('invalid IPv4 address: $ipv4');
  if (port < 1 || port > 65535) throw FormatException('port out of range: $port');
  if (token.isEmpty) throw const FormatException('empty session token');
  return PairingInfo(ipv4: ipv4, port: port, token: token);
}

/// Parses the Doc 12 QR payload `slatesync://connect?ip=&port=&token=`.
///
/// Table (Doc 25 §5 step 2): valid URL ⇒ [PairingInfo]; missing `ip` or
/// `token`, non-integer/out-of-range `port`, foreign scheme, or an empty
/// string ⇒ [FormatException].
PairingInfo parsePairingUrl(String raw) {
  if (raw.isEmpty) throw const FormatException('empty pairing payload');
  final uri = Uri.parse(raw);
  if (uri.scheme != kPairingScheme) {
    throw FormatException('unsupported scheme: ${uri.scheme}');
  }
  if (uri.host != 'connect') {
    throw FormatException('unsupported pairing target: ${uri.host}');
  }
  final ip = uri.queryParameters['ip'];
  final portRaw = uri.queryParameters['port'];
  final token = uri.queryParameters['token'];
  if (ip == null || ip.isEmpty) throw const FormatException('missing ip');
  if (token == null || token.isEmpty) throw const FormatException('missing token');
  if (portRaw == null || portRaw.isEmpty) throw const FormatException('missing port');
  final port = int.tryParse(portRaw);
  if (port == null) throw FormatException('non-integer port: $portRaw');
  return buildPairingInfo(ipv4: ip, port: port, token: token);
}

/// Concatenates reassembled chunks `0..totalChunks-1` into a temp file
/// via [getTemporaryDirectory] (Doc 25 §4).
///
/// Throws [StateError] if any index is missing (abort ⇒ no event).
Future<File> writeExportTemp(
  String transferId,
  int totalChunks,
  Map<int, Uint8List> parts,
) async {
  if (totalChunks < 0) {
    throw ArgumentError.value(totalChunks, 'totalChunks', 'must be >= 0');
  }
  final dir = await getTemporaryDirectory();
  await dir.create(recursive: true);
  final safeId = transferId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final file = File(
    '${dir.path}${Platform.pathSeparator}slatesync_$safeId.bin',
  );
  final raf = await file.open(mode: FileMode.write);
  try {
    for (var i = 0; i < totalChunks; i++) {
      final part = parts[i];
      if (part == null) {
        throw StateError('missing chunk $i for transfer "$transferId"');
      }
      await raf.writeFrom(part);
    }
  } finally {
    await raf.close();
  }
  return file;
}

// ---------------------------------------------------------------------------
// mDNS discovery (Doc 25 §5 steps 1 + 10)
// ---------------------------------------------------------------------------

String? _extractTxtToken(String text) =>
    RegExp(r'token=([^\x00-\x20,;]+)').firstMatch(text)?.group(1);

/// Default [SyncDiscoverer]: PTR → TXT → SRV → A browse of
/// [kMdnsServiceType] with the given timeout per lookup.
///
/// TXT missing `token` or zero non-loopback A-records ⇒ [StateError];
/// no records within [timeout] ⇒ [TimeoutException] (Doc 25 §5 step 10).
Future<PairingInfo> _mdnsDiscover(Duration timeout) async {
  final client = MDnsClient();
  await client.start();
  try {
    final ptrs = await client
        .lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer(kMdnsServiceType),
          timeout: timeout,
        )
        .toList();
    if (ptrs.isEmpty) {
      throw TimeoutException('SlateSync mDNS service not found', timeout);
    }
    final instanceName = ptrs.first.domainName;

    final txts = await client
        .lookup<TxtResourceRecord>(
          ResourceRecordQuery.text(instanceName),
          timeout: timeout,
        )
        .toList();
    if (txts.isEmpty) {
      throw TimeoutException('SlateSync TXT record not found', timeout);
    }
    final token = _extractTxtToken(txts.first.text);
    if (token == null || token.isEmpty) {
      throw StateError('SlateSync TXT record carries no token');
    }

    final srvs = await client
        .lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(instanceName),
          timeout: timeout,
        )
        .toList();
    if (srvs.isEmpty) {
      throw TimeoutException('SlateSync SRV record not found', timeout);
    }
    final srv = srvs.first;

    final addrs = await client
        .lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(srv.target),
          timeout: timeout,
        )
        .toList();
    String? ipv4;
    for (final record in addrs) {
      final address = record.address;
      if (address.type == InternetAddressType.IPv4 && !address.isLoopback) {
        ipv4 = address.address;
        break;
      }
    }
    if (ipv4 == null) {
      throw StateError('SlateSync service exposes no non-loopback IPv4');
    }
    return PairingInfo(
      ipv4: ipv4,
      port: srv.port > 0 ? srv.port : kSyncWsPort,
      token: token,
    );
  } finally {
    client.stop();
  }
}

// ---------------------------------------------------------------------------
// VectorSyncClient (template §5 freeze)
// ---------------------------------------------------------------------------

class _IncomingTransfer {
  _IncomingTransfer({required this.totalChunks, required this.sizeBytes});

  final int totalChunks;
  final int sizeBytes;
  final Map<int, Uint8List> parts = <int, Uint8List>{};
}

class VectorSyncClient {
  VectorSyncClient({
    SyncConnector? connector,
    SyncDiscoverer? discoverer,
    BackoffDelayFn? backoffDelay,
  }) : _connector = connector ?? _connectWebSocket,
       _discoverer = discoverer ?? _mdnsDiscover,
       _backoffDelay = backoffDelay ?? defaultBackoffDelay;

  /// Doc 25 §5 step 3 retry ladder: 0.5, 1, 2, 4, 8 s (capped at 8 s,
  /// unlimited retries).
  static const List<Duration> backoffLadder = <Duration>[
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];

  /// Pure backoff schedule: index `0..4` yields the ladder, `>=5` stays 8 s.
  static Duration defaultBackoffDelay(int attempt) =>
      (attempt >= 0 && attempt < backoffLadder.length)
          ? backoffLadder[attempt]
          : backoffLadder.last;

  static SyncChannel _connectWebSocket(Uri url) =>
      WebSocketSyncChannel(WebSocketChannel.connect(url));

  final SyncConnector _connector;
  final SyncDiscoverer _discoverer;
  final BackoffDelayFn _backoffDelay;
  final StreamController<SyncEvent> _events =
      StreamController<SyncEvent>.broadcast();
  final List<Map<String, dynamic>> _offlineQueue = <Map<String, dynamic>>[];
  final Map<String, _IncomingTransfer> _transfers =
      <String, _IncomingTransfer>{};
  final Stopwatch _cameraClock = Stopwatch()..start();

  SyncState _state = SyncState.idle;
  PairingInfo? _pairing;
  SyncChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  Timer? _backoffTimer;
  Timer? _cameraTimer;
  (int, double, double, double)? _pendingCamera;
  int _retry = 0;
  int _attemptSeq = 0;
  int _seq = 0; // ONE u16 counter shared by ALL frame types (template §3)
  int? _lastCameraMs;
  bool _disposed = false;

  /// Current connection state (diagnostics; transitions surface on [events]).
  SyncState get state => _state;

  /// Pairing used for the current/reconnect attempts.
  PairingInfo? get pairing => _pairing;

  /// Number of buffered offline RPCs (ring capacity [kOfflineRingCapacity]).
  int get offlineQueueLength => _offlineQueue.length;

  bool get isConnected => _state == SyncState.online;

  Stream<SyncEvent> get events => _events.stream;

  // -- discovery -----------------------------------------------------------

  /// mDNS browse of [kMdnsServiceType] with [kDiscoveryTimeout]; on success
  /// transitions `discovering → connecting → online` (auto-[connect]s), on
  /// timeout/failure throws and falls back to `idle` (Doc 25 §5 step 1).
  Future<void> discover() async {
    if (_disposed) return;
    _setState(SyncState.discovering);
    try {
      final info =
          await _discoverer(kDiscoveryTimeout).timeout(kDiscoveryTimeout);
      if (_disposed || _state != SyncState.discovering) return;
      await connect(info);
    } catch (_) {
      if (_state == SyncState.discovering) _setState(SyncState.idle);
      rethrow;
    }
  }

  // -- connection ----------------------------------------------------------

  /// Opens `ws://<ipv4>:<port>/ws?token=<token>` (Doc 11 URL). Failures
  /// schedule backoff retries instead of throwing; a close with code 4001
  /// lands in [SyncState.authFailed] (terminal, re-pair required).
  Future<void> connect(PairingInfo info) async {
    if (_disposed) return;
    _pairing = info;
    _retry = 0;
    _backoffTimer?.cancel();
    _backoffTimer = null;
    await _openAttempt();
  }

  Future<void> _openAttempt() async {
    final info = _pairing;
    if (_disposed || info == null) return;
    _cleanupChannel();
    final attempt = ++_attemptSeq;
    _setState(SyncState.connecting);
    final uri = Uri(
      scheme: 'ws',
      host: info.ipv4,
      port: info.port,
      path: kSyncWsPath,
      queryParameters: <String, String>{'token': info.token},
    );
    final SyncChannel channel;
    try {
      channel = _connector(uri);
    } catch (_) {
      _scheduleBackoff();
      return;
    }
    _channel = channel;
    _channelSub = channel.stream.listen(
      _handleText,
      onError: (Object _) {
        if (attempt != _attemptSeq || _disposed) return;
        _routeDrop(channel.closeCode);
      },
      onDone: () {
        if (attempt != _attemptSeq || _disposed) return;
        _routeDrop(channel.closeCode);
      },
      cancelOnError: true,
    );
    try {
      await channel.ready;
    } catch (_) {
      if (attempt == _attemptSeq && !_disposed) {
        _cleanupChannel();
        _scheduleBackoff();
      }
      return;
    }
    if (_disposed || attempt != _attemptSeq) return;
    if (_state != SyncState.connecting) return; // drop raced ahead of ready
    _retry = 0;
    _setState(SyncState.online);
    flushOfflineQueue();
  }

  void _routeDrop(int? closeCode) {
    _cleanupChannel();
    if (_disposed) return;
    if (closeCode == kAuthFailedCloseCode) {
      _backoffTimer?.cancel();
      _backoffTimer = null;
      _setState(SyncState.authFailed);
      return;
    }
    _scheduleBackoff();
  }

  void _scheduleBackoff() {
    if (_disposed || _state == SyncState.authFailed) return;
    if (_backoffTimer?.isActive ?? false) return;
    if (_pairing == null) return;
    final delay = _backoffDelay(_retry);
    _retry += 1;
    _setState(SyncState.backoff);
    _backoffTimer = Timer(delay, () {
      _backoffTimer = null;
      if (_disposed || _state != SyncState.backoff) return;
      unawaited(_openAttempt());
    });
  }

  void _cleanupChannel() {
    _channelSub?.cancel();
    _channelSub = null;
    final old = _channel;
    _channel = null;
    if (old != null) unawaited(old.close());
  }

  // -- send path: live frames (Doc 25 §5 steps 4 + 9) ----------------------

  /// 16-byte binary frame via Doc 05 `WireCodec`. Dropped immediately when
  /// offline (never queued); camera frames are throttled to ≤60 Hz with a
  /// latest-slot drop-if-unsent buffer.
  void sendLiveFrame(
    int frameType,
    int toolId,
    double f1,
    double f2,
    double f3,
  ) {
    if (_disposed || !isConnected) return; // offline ⇒ drop (Doc 25 §8)
    if (frameType == FrameType.camera) {
      _sendCameraThrottled(toolId, f1, f2, f3);
    } else {
      _writeFrame(frameType: frameType, toolId: toolId, f1: f1, f2: f2, f3: f3);
    }
  }

  void _writeFrame({
    required int frameType,
    required int toolId,
    required double f1,
    required double f2,
    required double f3,
  }) {
    final channel = _channel;
    if (channel == null || !isConnected) return;
    final bytes = WireCodec.buildFrame(
      frameType: frameType,
      toolId: toolId,
      seq: _seq,
      f1: f1,
      f2: f2,
      f3: f3,
    );
    try {
      channel.add(bytes.buffer.asUint8List());
    } catch (_) {
      return; // sink already closed — drop; recovery via onDone/backoff
    }
    _seq = (_seq + 1) & 0xFFFF; // 65535 → 0 wrap accepted (Doc 02)
  }

  void _sendCameraThrottled(int toolId, double f1, double f2, double f3) {
    final last = _lastCameraMs;
    final now = _cameraClock.elapsedMilliseconds;
    if (last == null || now - last >= 16) {
      _lastCameraMs = now;
      _writeFrame(
        frameType: FrameType.camera,
        toolId: toolId,
        f1: f1,
        f2: f2,
        f3: f3,
      );
      return;
    }
    // Latest slot: replaces any still-unsent frame (drop-if-unsent).
    _pendingCamera = (toolId, f1, f2, f3);
    _cameraTimer ??= Timer(
      Duration(milliseconds: 16 - (now - last)),
      _flushPendingCamera,
    );
  }

  void _flushPendingCamera() {
    _cameraTimer = null;
    final pending = _pendingCamera;
    _pendingCamera = null;
    if (pending == null || _disposed || !isConnected) return;
    _lastCameraMs = _cameraClock.elapsedMilliseconds;
    _writeFrame(
      frameType: FrameType.camera,
      toolId: pending.$1,
      f1: pending.$2,
      f2: pending.$3,
      f3: pending.$4,
    );
  }

  // -- send path: RPC (Doc 25 §5 steps 5 + 8) ------------------------------

  /// Sends a Doc 02 §4.2 envelope. Fills absent `id` (uuid-v4) and
  /// `timestamp` (unix seconds); validates `type/action/canvas_id/payload`
  /// presence. Offline ⇒ ring-buffered (≤[kOfflineRingCapacity], FIFO).
  Future<void> sendRpc(Map<String, dynamic> envelope) async {
    if (_disposed) return;
    for (final field in const <String>['type', 'action', 'canvas_id', 'payload']) {
      if (!envelope.containsKey(field)) {
        throw FormatException('missing envelope field: $field');
      }
    }
    final out = Map<String, dynamic>.from(envelope);
    out.putIfAbsent('id', uuidV4);
    out.putIfAbsent(
      'timestamp',
      () => DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
    );
    final channel = _channel;
    if (isConnected && channel != null) {
      try {
        channel.add(jsonEncode(out));
        return;
      } catch (_) {
        // fall through to the ring buffer
      }
    }
    _offlineQueue.add(out);
    if (_offlineQueue.length > kOfflineRingCapacity) {
      _offlineQueue.removeAt(0); // 5001st evicts the oldest (FIFO)
    }
  }

  /// Replays the offline ring in order on the current online connection and
  /// clears each entry only after its write is accepted by the sink.
  void flushOfflineQueue() {
    if (!isConnected || _offlineQueue.isEmpty) return;
    final channel = _channel;
    if (channel == null) return;
    while (_offlineQueue.isNotEmpty) {
      try {
        channel.add(jsonEncode(_offlineQueue.first));
      } catch (_) {
        return; // sink refused — remaining entries wait for the next flush
      }
      _offlineQueue.removeAt(0);
    }
  }

  // -- receive path (Doc 25 §5 step 6) -------------------------------------

  void _emit(SyncEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _setState(SyncState next) {
    if (next == _state || _events.isClosed) return;
    _state = next;
    _emit(SyncEvent(kind: SyncEventKind.stateChanged, state: next));
  }

  void _handleText(dynamic data) {
    if (_disposed || data is! String) return;
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final Map<String, dynamic> msg;
    try {
      msg = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    _emit(SyncEvent(kind: SyncEventKind.rpcReceived, msg: msg));
    final action = msg['action'];
    final type = msg['type'];
    final rawPayload = msg['payload'];
    final payload = rawPayload is Map
        ? Map<String, dynamic>.from(rawPayload)
        : <String, dynamic>{};
    if (action == 'EXPORT_PROGRESS') {
      _emit(
        SyncEvent(
          kind: SyncEventKind.progress,
          jobId: payload['job_id'] is String
              ? payload['job_id'] as String
              : null,
          percent: (payload['percent'] as num?)?.toDouble(),
        ),
      );
    }
    if (type == 'ASSET_UPLOAD' && action is String) {
      unawaited(_handleAsset(action, payload));
    }
  }

  Future<void> _handleAsset(
    String action,
    Map<String, dynamic> payload,
  ) async {
    final transferIdRaw = payload['transfer_id'];
    if (transferIdRaw is! String || transferIdRaw.isEmpty) return;
    final transferId = transferIdRaw;

    if (action == 'ASSET_START') {
      final total = payload['total_chunks'];
      final size = payload['size_bytes'];
      if (total is! int || total < 0 || size is! int || size < 0) return;
      _transfers[transferId] = _IncomingTransfer(
        totalChunks: total,
        sizeBytes: size,
      );
      return;
    }

    if (action == 'ASSET_CHUNK') {
      final transfer = _transfers[transferId];
      if (transfer == null) return; // no START ⇒ chunk discarded
      final index = payload['index'];
      final dataB64 = payload['data_b64'];
      if (index is! int ||
          index < 0 ||
          index >= transfer.totalChunks ||
          dataB64 is! String) {
        _transfers.remove(transferId);
        return;
      }
      Uint8List bytes;
      try {
        bytes = base64Decode(dataB64);
      } catch (_) {
        _transfers.remove(transferId);
        return;
      }
      if (bytes.length > kAssetChunkRawCapBytes) {
        _transfers.remove(transferId); // template §3 cap
        return;
      }
      transfer.parts[index] = bytes; // out-of-order OK (any index)
      _emit(
        SyncEvent(
          kind: SyncEventKind.fileChunk,
          transferId: transferId,
          index: index,
          data: bytes,
        ),
      );
      return;
    }

    if (action == 'ASSET_DONE') {
      final transfer = _transfers.remove(transferId);
      if (transfer == null) return;
      // Verify total_chunks + size_bytes; any mismatch aborts silently
      // (drop buffer, no event — Doc 25 §5 step 6).
      if (transfer.parts.length != transfer.totalChunks) return;
      for (var i = 0; i < transfer.totalChunks; i++) {
        if (!transfer.parts.containsKey(i)) return;
      }
      final mergedSize = transfer.parts.values.fold<int>(
        0,
        (sum, part) => sum + part.length,
      );
      if (mergedSize != transfer.sizeBytes) return;
      try {
        final file = await writeExportTemp(
          transferId,
          transfer.totalChunks,
          transfer.parts,
        );
        _emit(
          SyncEvent(
            kind: SyncEventKind.fileReceived,
            transferId: transferId,
            path: file.path,
          ),
        );
      } catch (_) {
        return; // abort — partial data discarded
      }
    }
  }

  /// Tears down the client: timers, channel, subscriptions and the event
  /// stream. The offline ring is retained but unusable afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _backoffTimer?.cancel();
    _backoffTimer = null;
    _cameraTimer?.cancel();
    _cameraTimer = null;
    _pendingCamera = null;
    await _channelSub?.cancel();
    _channelSub = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) await channel.close();
    if (!_events.isClosed) await _events.close();
  }
}

// ---------------------------------------------------------------------------
// Pairing UI (Doc 25 §5 step 2 — scoped here per file-ownership rules)
// ---------------------------------------------------------------------------

/// QR scanner: pairs on the first valid `slatesync://connect?…` payload
/// (debounced to a single [onPair] call); unparseable codes are skipped.
///
/// Camera startup failures (permission denied, no camera) are reported
/// through [onCameraError] one frame after they occur so host screens can
/// swap in a manual-entry fallback (Issue 03).
class PairingScanner extends StatefulWidget {
  const PairingScanner({
    super.key,
    required this.onPair,
    this.onCameraError,
  });

  final void Function(PairingInfo info) onPair;

  /// Optional camera-failure hook (Doc 25 §5 step 2 fallback): receives the
  /// [MobileScannerErrorCode] from `MobileScanner.errorBuilder`. Invoked
  /// post-frame, so listeners may call `setState` safely.
  final void Function(MobileScannerErrorCode code)? onCameraError;

  @override
  State<PairingScanner> createState() => _PairingScannerState();
}

class _PairingScannerState extends State<PairingScanner> {
  bool _paired = false;

  PairingInfo? _tryParse(String raw) {
    try {
      return parsePairingUrl(raw);
    } on FormatException {
      return null;
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_paired) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || !raw.startsWith('$kPairingScheme:')) continue;
      final info = _tryParse(raw);
      if (info == null) continue;
      _paired = true;
      widget.onPair(info);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final void Function(MobileScannerErrorCode)? onError = widget.onCameraError;
    return MobileScanner(
      onDetect: _onDetect,
      errorBuilder: onError == null
          ? null
          : (BuildContext context, MobileScannerException error) {
              // Defer past the current build so the host may setState.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  onError(error.errorCode);
                }
              });
              return const SizedBox.shrink();
            },
    );
  }
}

/// Manual IPv4/port/token entry fallback shown when `discover()` times out,
/// the camera is unavailable, or after `authFailed` (Doc 25 §5 step 2).
class ManualPairingScreen extends StatefulWidget {
  const ManualPairingScreen({
    super.key,
    required this.onConnect,
    this.title = 'Pair with SlateSync',
  });

  final void Function(PairingInfo info) onConnect;
  final String title;

  @override
  State<ManualPairingScreen> createState() => _ManualPairingScreenState();
}

class _ManualPairingScreenState extends State<ManualPairingScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController =
      TextEditingController(text: '$kSyncWsPort');
  final TextEditingController _tokenController = TextEditingController();

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  String? _validateIpv4(String? value) =>
      _isIpv4((value ?? '').trim()) ? null : 'Enter a valid IPv4 address';

  String? _validatePort(String? value) {
    final port = int.tryParse((value ?? '').trim());
    if (port == null || port < 1 || port > 65535) {
      return 'Port must be 1–65535';
    }
    return null;
  }

  String? _validateToken(String? value) =>
      (value ?? '').trim().isEmpty ? 'Session token is required' : null;

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    widget.onConnect(
      buildPairingInfo(
        ipv4: _ipController.text.trim(),
        port: int.parse(_portController.text.trim()),
        token: _tokenController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextFormField(
                controller: _ipController,
                decoration: const InputDecoration(labelText: 'PC IPv4 address'),
                keyboardType: TextInputType.number,
                validator: _validateIpv4,
              ),
              TextFormField(
                controller: _portController,
                decoration: const InputDecoration(labelText: 'Port'),
                keyboardType: TextInputType.number,
                validator: _validatePort,
              ),
              TextFormField(
                controller: _tokenController,
                decoration: const InputDecoration(labelText: 'Session token'),
                validator: _validateToken,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _submit,
                child: const Text('Connect'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
