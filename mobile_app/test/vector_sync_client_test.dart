/// Doc 25 §6 acceptance suite for [VectorSyncClient]:
///  * envelope fidelity vs Doc 02 §4.2 example (key set + uuid-v4 id)
///  * single shared u16 seq counter: 65535 → 0 wrap + camera/livePoint
///    interleaving monotonicity (mirrors Doc 11 `last_seq` gate)
///  * offline ring eviction at the 5001st RPC; live frames dropped offline
///  * QR/manual pairing URL parse table (valid + invalid cases)
///  * ASSET_CHUNK out-of-order reassembly from shuffled chunks; aborts on
///    truncated / duplicate-index transfers (no `fileReceived`)
///  * state machine: idle→connecting→online, backoff ladder 0.5/1/2/4/8 s,
///    4001 → authFailed (terminal), `stateChanged` per transition
///
/// All I/O runs through injected fakes — no real sockets, mDNS or camera.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class FakeSyncChannel implements SyncChannel {
  final StreamController<dynamic> _controller = StreamController<dynamic>();
  final List<Object?> sent = <Object?>[];
  final Completer<void> readyCompleter = Completer<void>();
  int? _closeCode;
  bool _closed = false;

  @override
  Future<void> get ready => readyCompleter.future;

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => null;

  @override
  void add(Object? data) {
    if (_closed || _controller.isClosed) {
      throw StateError('sink closed');
    }
    sent.add(data);
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    _closeCode ??= closeCode;
    _closed = true;
    if (!_controller.isClosed) await _controller.close();
  }

  void completeReady() {
    if (!readyCompleter.isCompleted) readyCompleter.complete();
  }

  void failReady() {
    if (!readyCompleter.isCompleted) {
      readyCompleter.completeError(StateError('connection refused'));
    }
  }

  void serverSendText(String text) {
    if (!_controller.isClosed) _controller.add(text);
  }

  void serverClose(int code) {
    _closeCode = code;
    _closed = true;
    if (!_controller.isClosed) _controller.close();
  }
}

class FakeNet {
  FakeNet({this.failConnects = false});

  final bool failConnects;
  final List<Uri> urls = <Uri>[];
  final List<FakeSyncChannel> channels = <FakeSyncChannel>[];

  int get connectCount => urls.length;

  SyncChannel connect(Uri url) {
    urls.add(url);
    final channel = FakeSyncChannel();
    channels.add(channel);
    scheduleMicrotask(() {
      if (failConnects) {
        channel.failReady();
      } else {
        channel.completeReady();
      }
    });
    return channel;
  }
}

class Harness {
  Harness({
    bool failConnects = false,
    SyncDiscoverer? discoverer,
    BackoffDelayFn? backoffDelay,
  }) : net = FakeNet(failConnects: failConnects) {
    client = VectorSyncClient(
      connector: net.connect,
      discoverer: discoverer,
      backoffDelay: backoffDelay,
    );
    subscription = client.events.listen(events.add);
  }

  final FakeNet net;
  final List<SyncEvent> events = <SyncEvent>[];
  late final VectorSyncClient client;
  late final StreamSubscription<SyncEvent> subscription;

  List<SyncState> get states => events
      .where((e) => e.kind == SyncEventKind.stateChanged)
      .map((e) => e.state!)
      .toList();

  Future<void> dispose() async {
    await subscription.cancel();
    await client.dispose();
  }
}

const PairingInfo testPairing = PairingInfo(
  ipv4: '192.168.1.7',
  port: 50606,
  token: 'abc',
);

final RegExp uuidV4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String description = 'condition',
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      throw StateError('timed out waiting for $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// Minimal §4.2 envelope (id/timestamp omitted — client must fill both).
Map<String, dynamic> rpcEnvelope({required int n}) => <String, dynamic>{
      'type': 'ELEMENT_COMMIT',
      'action': 'ADD_STROKE',
      'canvas_id': '9d1f4c02-77aa-4bb1-8f6d-0c2e5a9b3c71',
      'payload': <String, dynamic>{'n': n},
    };

/// Doc 02 §4.2 worked example (ELEMENT_COMMIT / ADD_STROKE), verbatim.
Map<String, dynamic> doc02Example() => <String, dynamic>{
      'id': '6f1c2a9e-4d2b-4a77-9c5e-1b2f3d4e5a60',
      'type': 'ELEMENT_COMMIT',
      'action': 'ADD_STROKE',
      'canvas_id': '9d1f4c02-77aa-4bb1-8f6d-0c2e5a9b3c71',
      'payload': <String, dynamic>{
        'node_id': '3a7c9d15-5e84-4f0b-a2c6-8b1d7e4f9a03',
        'kind': 'STROKE',
        'layer': 0,
        'bbox': <double>[120.0, 300.0, 450.0, 620.0],
        'style': <String, dynamic>{
          'color': '#1E1E1E',
          'stroke_width': 2.5,
          'opacity': 1.0,
          'blend_mode': 'SRC_OVER',
        },
        'geometry': <String, dynamic>{
          'pts': <List<double>>[
            <double>[120.4, 301.2],
            <double>[124.8, 309.5],
            <double>[131.0, 318.0],
          ],
        },
      },
      'timestamp': 1760760000,
    };

Map<String, dynamic> assetEnvelope(
  String action,
  Map<String, dynamic> payload,
) =>
    <String, dynamic>{
      'id': uuidV4(),
      'type': 'ASSET_UPLOAD',
      'action': action,
      'canvas_id': '9d1f4c02-77aa-4bb1-8f6d-0c2e5a9b3c71',
      'payload': payload,
      'timestamp': 1760760010,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tmpRoot;

  setUpAll(() {
    tmpRoot = Directory(
      '${Directory.current.path}${Platform.pathSeparator}.dart_tool'
      '${Platform.pathSeparator}w1b_vector_sync_test',
    );
    tmpRoot.createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (MethodCall call) async {
      if (call.method == 'getTemporaryDirectory') return tmpRoot.path;
      return null;
    });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
  });

  // -----------------------------------------------------------------------
  group('uuidV4', () {
    test('matches uuid-v4 regex and is unique', () {
      final seen = <String>{};
      for (var i = 0; i < 50; i++) {
        final id = uuidV4();
        expect(id, matches(uuidV4Pattern));
        expect(seen.add(id), isTrue);
      }
    });
  });

  // -----------------------------------------------------------------------
  group('parsePairingUrl table', () {
    test('valid: slatesync://connect?ip&port&token', () {
      final info = parsePairingUrl(
        'slatesync://connect?ip=192.168.1.7&port=50606&token=abc',
      );
      expect(info.ipv4, '192.168.1.7');
      expect(info.port, 50606);
      expect(info.token, 'abc');
    });

    final invalid = <String, String>{
      'missing ip': 'slatesync://connect?port=50606&token=abc',
      'missing token': 'slatesync://connect?ip=192.168.1.7&port=50606',
      'non-integer port':
          'slatesync://connect?ip=192.168.1.7&port=fifty&token=abc',
      'foreign scheme':
          'https://connect?ip=192.168.1.7&port=50606&token=abc',
      'empty string': '',
      'port 0': 'slatesync://connect?ip=192.168.1.7&port=0&token=abc',
    };
    for (final entry in invalid.entries) {
      test('invalid: ${entry.key}', () {
        expect(() => parsePairingUrl(entry.value), throwsFormatException);
      });
    }

    test('manual-entry builder rejects 999.1.1.1 and port 0', () {
      expect(
        () => buildPairingInfo(ipv4: '999.1.1.1', port: 50606, token: 'abc'),
        throwsFormatException,
      );
      expect(
        () => buildPairingInfo(ipv4: '192.168.1.7', port: 0, token: 'abc'),
        throwsFormatException,
      );
      expect(
        () => buildPairingInfo(ipv4: '192.168.1.7', port: 50606, token: ''),
        throwsFormatException,
      );
      final ok = buildPairingInfo(ipv4: '10.0.0.1', port: 1, token: 't');
      expect(ok.ipv4, '10.0.0.1');
      expect(ok.port, 1);
    });
  });

  // -----------------------------------------------------------------------
  group('sendRpc envelope (Doc 02 §4.2)', () {
    test('example fidelity: key set exact, caller values pass through',
        () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.client.connect(testPairing);
      expect(h.client.isConnected, isTrue);

      final example = doc02Example();
      await h.client.sendRpc(example);

      final sent = h.net.channels.single.sent;
      expect(sent, hasLength(1));
      final decoded =
          jsonDecode(sent.single as String) as Map<String, dynamic>;
      expect(
        decoded.keys.toSet(),
        <String>{'id', 'type', 'action', 'canvas_id', 'payload', 'timestamp'},
      );
      expect(decoded, equals(example)); // id/timestamp untouched
    });

    test('fills uuid-v4 id and unix-seconds timestamp when omitted',
        () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.client.connect(testPairing);

      final envelope = rpcEnvelope(n: 7);
      await h.client.sendRpc(envelope);

      final decoded = jsonDecode(
        h.net.channels.single.sent.single as String,
      ) as Map<String, dynamic>;
      expect(
        decoded.keys.toSet(),
        <String>{'id', 'type', 'action', 'canvas_id', 'payload', 'timestamp'},
      );
      expect(decoded['id'], matches(uuidV4Pattern));
      final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      expect(decoded['timestamp'], inInclusiveRange(now - 30, now + 30));
      expect(decoded['type'], envelope['type']);
      expect(decoded['action'], envelope['action']);
      expect(decoded['canvas_id'], envelope['canvas_id']);
      expect(decoded['payload'], equals(envelope['payload']));
    });

    test('rejects an envelope missing a required field', () async {
      final h = Harness();
      addTearDown(h.dispose);
      await expectLater(
        h.client.sendRpc(<String, dynamic>{'type': 'EXPORT_JOB'}),
        throwsFormatException,
      );
    });
  });

  // -----------------------------------------------------------------------
  group('seq counter (template §3 — ONE u16 shared by all frame types)', () {
    test('65538 frames: 65535 → 0 → 1 wrap, every frame 16 bytes', () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.client.connect(testPairing);

      for (var i = 0; i < 65538; i++) {
        h.client.sendLiveFrame(
          FrameType.livePoint,
          ToolId.pen,
          i.toDouble(),
          0.5,
          0.25,
        );
      }

      final sent = h.net.channels.single.sent;
      expect(sent, hasLength(65538));
      final seqs = <int>[];
      for (final raw in sent) {
        expect(raw, isA<Uint8List>());
        final bytes = raw as Uint8List;
        expect(bytes, hasLength(16));
        seqs.add(WireCodec.decodeFrame(bytes).seq);
      }
      expect(seqs.first, 0);
      expect(seqs[65535], 65535);
      expect(seqs[65536], 0);
      expect(seqs[65537], 1);
    });

    test('camera + livePoint interleave on ONE strictly increasing counter',
        () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.client.connect(testPairing);

      for (var i = 0; i < 5; i++) {
        h.client.sendLiveFrame(
          FrameType.camera,
          ToolId.pen,
          1.0 + i,
          i.toDouble(),
          0.0,
        );
        h.client.sendLiveFrame(
          FrameType.livePoint,
          ToolId.pen,
          i.toDouble(),
          1.0,
          0.5,
        );
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      final frames = h.net.channels.single.sent
          .map((raw) => WireCodec.decodeFrame(raw as Uint8List))
          .toList();
      expect(frames, hasLength(10));
      for (var i = 0; i < frames.length; i++) {
        expect(
          frames[i].frameType,
          i.isEven ? FrameType.camera : FrameType.livePoint,
        );
      }
      // No frame dropped ⇒ seq strictly increases across frame types.
      for (var i = 1; i < frames.length; i++) {
        expect(frames[i].seq, (frames[i - 1].seq + 1) & 0xFFFF);
      }
      // Each camera frame is older than the livePoint that follows it:
      // the server's single last_seq gate accepts every one of them.
      for (var i = 0; i + 1 < frames.length; i += 2) {
        expect(frames[i].seq, lessThan(frames[i + 1].seq));
      }
    });

    test('camera ≤60 Hz: latest slot drops the unsent (replaced) frame',
        () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.client.connect(testPairing);

      h.client.sendLiveFrame(FrameType.camera, ToolId.pen, 1.0, 0.0, 0.0);
      h.client.sendLiveFrame(FrameType.camera, ToolId.pen, 2.0, 0.0, 0.0);
      h.client.sendLiveFrame(FrameType.camera, ToolId.pen, 3.0, 0.0, 0.0);
      // 2.0 never left the latest slot: 3.0 replaced it before the timer.
      expect(h.net.channels.single.sent, hasLength(1));

      await Future<void>.delayed(const Duration(milliseconds: 40));
      final frames = h.net.channels.single.sent
          .map((raw) => WireCodec.decodeFrame(raw as Uint8List))
          .toList();
      expect(frames, hasLength(2));
      expect(frames[0].f1, 1.0);
      expect(frames[1].f1, 3.0); // 2.0 dropped (drop-if-unsent)
      expect(frames[1].seq, (frames[0].seq + 1) & 0xFFFF);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(h.net.channels.single.sent, hasLength(2)); // nothing else queued
    });
  });

  // -----------------------------------------------------------------------
  group('offline ring buffer (≤5000 FIFO, live frames dropped)', () {
    test('5001st RPC evicts the oldest; flush replays in order', () async {
      final h = Harness();
      addTearDown(h.dispose);

      for (var i = 0; i <= 5000; i++) {
        await h.client.sendRpc(rpcEnvelope(n: i));
      }
      expect(h.client.offlineQueueLength, 5000);
      expect(h.net.connectCount, 0); // nothing left the device

      await h.client.connect(testPairing); // auto-flush on online
      expect(h.client.isConnected, isTrue);
      final sent = h.net.channels.single.sent;
      expect(sent, hasLength(5000));
      expect(h.client.offlineQueueLength, 0);

      final ns = sent
          .map(
            (raw) =>
                (jsonDecode(raw as String)['payload'] as Map<String, dynamic>)['n']
                    as int,
          )
          .toList();
      expect(ns.first, 1); // seq #0 (oldest) evicted at the 5001st enqueue
      expect(ns.last, 5000);
      for (var i = 1; i < ns.length; i++) {
        expect(ns[i], ns[i - 1] + 1); // FIFO order preserved
      }
    });

    test('live frames dropped offline; RPC buffered then flushed on reconnect',
        () async {
      final h = Harness();
      addTearDown(h.dispose);

      for (var i = 0; i < 10; i++) {
        h.client.sendLiveFrame(FrameType.livePoint, ToolId.pen, 1.0, 2.0, 3.0);
      }
      expect(h.net.connectCount, 0); // zero channel writes while offline

      await h.client.sendRpc(rpcEnvelope(n: 1));
      await h.client.sendRpc(rpcEnvelope(n: 2));
      expect(h.client.offlineQueueLength, 2);

      h.client.flushOfflineQueue(); // offline ⇒ no-op
      expect(h.client.offlineQueueLength, 2);
      expect(h.net.connectCount, 0);

      await h.client.connect(testPairing);
      final sent = h.net.channels.single.sent;
      expect(sent, hasLength(2)); // only the RPCs — live frames were dropped
      final ns = sent
          .map(
            (raw) =>
                (jsonDecode(raw as String)['payload'] as Map<String, dynamic>)['n']
                    as int,
          )
          .toList();
      expect(ns, <int>[1, 2]);
    });
  });

  // -----------------------------------------------------------------------
  group('connection state machine', () {
    test('idle → connecting → online; connect URL matches Doc 11', () async {
      final h = Harness();
      addTearDown(h.dispose);
      expect(h.client.state, SyncState.idle);

      await h.client.connect(testPairing);
      await waitFor(() => h.client.isConnected, description: 'online');

      expect(h.states, <SyncState>[SyncState.connecting, SyncState.online]);
      expect(
        h.net.urls.single.toString(),
        'ws://192.168.1.7:50606/ws?token=abc',
      );
      final stateEvents = h.events
          .where((e) => e.kind == SyncEventKind.stateChanged)
          .toList();
      expect(stateEvents, hasLength(2)); // exactly one event per transition
      expect(stateEvents[0].state, SyncState.connecting);
      expect(stateEvents[1].state, SyncState.online);
      expect(stateEvents.every((e) => e.state != null), isTrue);
    });

    test('discover passes 3 s timeout; discovering → connecting → online',
        () async {
      Duration? seen;
      final h = Harness(
        discoverer: (timeout) async {
          seen = timeout;
          return const PairingInfo(
            ipv4: '10.1.2.3',
            port: 50606,
            token: 'tok9',
          );
        },
      );
      addTearDown(h.dispose);

      await h.client.discover();
      await waitFor(() => h.client.isConnected, description: 'online');

      expect(seen, kDiscoveryTimeout);
      expect(
        h.states,
        <SyncState>[
          SyncState.discovering,
          SyncState.connecting,
          SyncState.online,
        ],
      );
      expect(
        h.net.urls.single.toString(),
        'ws://10.1.2.3:50606/ws?token=tok9',
      );
    });

    test('discover timeout throws TimeoutException and falls back to idle',
        () async {
      final h = Harness(
        discoverer: (timeout) => Future<PairingInfo>.error(
          TimeoutException('mDNS browse timed out', timeout),
        ),
      );
      addTearDown(h.dispose);

      await expectLater(
        h.client.discover(),
        throwsA(isA<TimeoutException>()),
      );
      expect(h.client.state, SyncState.idle);
      // Broadcast delivery is asynchronous — wait for the idle event.
      await waitFor(
        () => h.states.length >= 2,
        description: 'fallback idle event',
      );
      expect(h.states, <SyncState>[SyncState.discovering, SyncState.idle]);
      expect(h.net.connectCount, 0);
    });

    test('backoff ladder 0.5,1,2,4,8 then capped at 8; same pairing reused',
        () async {
      final recorded = <Duration>[];
      final h = Harness(
        failConnects: true,
        backoffDelay: (attempt) {
          recorded.add(VectorSyncClient.defaultBackoffDelay(attempt));
          return const Duration(milliseconds: 2);
        },
      );
      addTearDown(h.dispose);

      await h.client.connect(testPairing);
      expect(recorded.first, const Duration(milliseconds: 500));

      await waitFor(
        () => recorded.length >= 7,
        description: '7 backoff delays',
      );
      expect(
        recorded.take(7).toList(),
        <Duration>[
          const Duration(milliseconds: 500),
          const Duration(seconds: 1),
          const Duration(seconds: 2),
          const Duration(seconds: 4),
          const Duration(seconds: 8),
          const Duration(seconds: 8),
          const Duration(seconds: 8),
        ],
      );
      expect(h.net.connectCount, greaterThanOrEqualTo(7));
      expect(h.net.urls.toSet(), hasLength(1)); // same PairingInfo every try
      expect(h.states.first, SyncState.connecting);
      expect(h.states[1], SyncState.backoff);
      expect(h.states[2], SyncState.connecting);
    });

    test('drop ≠4001 ⇒ backoff then automatic reconnect to online', () async {
      final h = Harness(
        backoffDelay: (_) => const Duration(milliseconds: 2),
      );
      addTearDown(h.dispose);
      await h.client.connect(testPairing);
      await waitFor(() => h.client.isConnected, description: 'online');

      h.net.channels.first.serverClose(1000); // normal close, not 4001
      await waitFor(
        () => h.net.connectCount >= 2,
        description: 'reconnect attempt',
      );
      await waitFor(() => h.client.isConnected, description: 'online again');

      expect(
        h.states,
        <SyncState>[
          SyncState.connecting,
          SyncState.online,
          SyncState.backoff,
          SyncState.connecting,
          SyncState.online,
        ],
      );
    });

    test('close 4001 ⇒ single authFailed transition, terminal, ring retained',
        () async {
      final h = Harness(
        backoffDelay: (_) => const Duration(milliseconds: 2),
      );
      addTearDown(h.dispose);
      await h.client.connect(testPairing);
      await waitFor(() => h.client.isConnected, description: 'online');

      await h.client.sendRpc(rpcEnvelope(n: 1));
      expect(h.net.channels.single.sent, hasLength(1));

      h.net.channels.single.serverClose(4001);
      await waitFor(
        () => h.client.state == SyncState.authFailed,
        description: 'authFailed',
      );
      expect(
        h.states,
        <SyncState>[SyncState.connecting, SyncState.online, SyncState.authFailed],
      );

      final eventCount = h.events.length;
      await h.client.sendRpc(rpcEnvelope(n: 2));
      expect(h.client.offlineQueueLength, 1); // ring retained
      h.client.flushOfflineQueue(); // no auto-flush after authFailed
      expect(h.client.offlineQueueLength, 1);
      expect(h.net.channels.single.sent, hasLength(1));

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.net.connectCount, 1); // terminal — zero retries
      expect(h.client.state, SyncState.authFailed);
      expect(h.events.length, eventCount); // no further events at all
    });
  });

  // -----------------------------------------------------------------------
  group('receive path (Stream<SyncEvent>)', () {
    test('EXPORT_PROGRESS ⇒ rpcReceived first, then progress', () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.client.connect(testPairing);

      final envelope = <String, dynamic>{
        'id': 'a2c68b1d-7e4f-49a0-8d35-6f1c2a9e4d2b',
        'type': 'EXPORT_JOB',
        'action': 'EXPORT_PROGRESS',
        'canvas_id': '9d1f4c02-77aa-4bb1-8f6d-0c2e5a9b3c71',
        'payload': <String, dynamic>{
          'job_id': 'b7e04c2d-8f31-4a06-9c77-5d2e1b9f8a40',
          'percent': 42,
        },
        'timestamp': 1760760003,
      };
      h.net.channels.single.serverSendText(jsonEncode(envelope));
      await waitFor(
        () => h.events.any((e) => e.kind == SyncEventKind.progress),
        description: 'progress event',
      );

      final rpc = h.events.firstWhere(
        (e) => e.kind == SyncEventKind.rpcReceived,
      );
      final progress = h.events.firstWhere(
        (e) => e.kind == SyncEventKind.progress,
      );
      expect(rpc.msg, equals(envelope));
      expect(progress.jobId, 'b7e04c2d-8f31-4a06-9c77-5d2e1b9f8a40');
      expect(progress.percent, 42.0);
      expect(
        h.events.indexOf(rpc),
        lessThan(h.events.indexOf(progress)),
      );
    });

    test('ASSET chunks delivered shuffled ⇒ temp file byte-equals source',
        () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.client.connect(testPairing);

      const total = 8;
      final source = Uint8List.fromList(
        List<int>.generate(2000, (i) => (i * 7) % 251),
      );
      final chunks = <int, Uint8List>{};
      final base = source.length ~/ total;
      var offset = 0;
      for (var i = 0; i < total; i++) {
        final end = i == total - 1 ? source.length : offset + base;
        chunks[i] = Uint8List.sublistView(source, offset, end);
        offset = end;
      }

      final channel = h.net.channels.single;
      void send(Map<String, dynamic> env) =>
          channel.serverSendText(jsonEncode(env));

      send(
        assetEnvelope('ASSET_START', <String, dynamic>{
          'transfer_id': 't-5a9f',
          'filename': 'img_9921.png',
          'total_chunks': total,
          'size_bytes': source.length,
        }),
      );

      // Delivered out of index order (shuffled), any-order reassembly.
      const shuffled = <int>[5, 2, 7, 0, 4, 1, 6, 3];
      for (final index in shuffled) {
        send(
          assetEnvelope('ASSET_CHUNK', <String, dynamic>{
            'transfer_id': 't-5a9f',
            'index': index,
            'data_b64': base64Encode(chunks[index]!),
          }),
        );
      }
      await waitFor(
        () =>
            h.events.where((e) => e.kind == SyncEventKind.fileChunk).length >=
            total,
        description: '8 fileChunk events',
      );
      final chunkEvents = h.events
          .where((e) => e.kind == SyncEventKind.fileChunk)
          .toList();
      expect(
        chunkEvents.map((e) => e.index).toSet(),
        <int>{0, 1, 2, 3, 4, 5, 6, 7},
      );
      for (final event in chunkEvents) {
        expect(event.data, equals(chunks[event.index!]));
        expect(event.transferId, 't-5a9f');
      }

      send(assetEnvelope('ASSET_DONE', <String, dynamic>{
        'transfer_id': 't-5a9f',
      }));
      await waitFor(
        () => h.events.any((e) => e.kind == SyncEventKind.fileReceived),
        description: 'fileReceived event',
      );

      final received = h.events.firstWhere(
        (e) => e.kind == SyncEventKind.fileReceived,
      );
      expect(received.transferId, 't-5a9f');
      final file = File(received.path!);
      expect(file.existsSync(), isTrue);
      expect(file.readAsBytesSync(), equals(source));
      file.deleteSync();
    });

    test('truncated transfer (7 of 8 chunks) aborts with no fileReceived',
        () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.client.connect(testPairing);
      final channel = h.net.channels.single;

      channel.serverSendText(jsonEncode(assetEnvelope('ASSET_START', <String, dynamic>{
        'transfer_id': 't-trunc',
        'filename': 'a.png',
        'total_chunks': 8,
        'size_bytes': 2000,
      })));
      for (var i = 0; i < 7; i++) {
        channel.serverSendText(jsonEncode(assetEnvelope('ASSET_CHUNK', <String, dynamic>{
          'transfer_id': 't-trunc',
          'index': i,
          'data_b64': base64Encode(Uint8List(250)),
        })));
      }
      channel.serverSendText(jsonEncode(assetEnvelope('ASSET_DONE', <String, dynamic>{
        'transfer_id': 't-trunc',
      })));

      // START + 7 chunks + DONE all surfaced as rpcReceived…
      await waitFor(
        () =>
            h.events
                .where((e) => e.kind == SyncEventKind.rpcReceived)
                .length >=
            9,
        description: '9 rpcReceived events',
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // …but the transfer never completes.
      expect(
        h.events.any((e) => e.kind == SyncEventKind.fileReceived),
        isFalse,
      );
    });

    test('duplicate chunk index aborts with no fileReceived', () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.client.connect(testPairing);
      final channel = h.net.channels.single;

      channel.serverSendText(jsonEncode(assetEnvelope('ASSET_START', <String, dynamic>{
        'transfer_id': 't-dup',
        'filename': 'b.png',
        'total_chunks': 8,
        'size_bytes': 2000,
      })));
      // indices 0..6 plus a duplicate of 3 — index 7 never arrives.
      const withDuplicate = <int>[0, 1, 2, 3, 4, 5, 6, 3];
      for (final index in withDuplicate) {
        channel.serverSendText(jsonEncode(assetEnvelope('ASSET_CHUNK', <String, dynamic>{
          'transfer_id': 't-dup',
          'index': index,
          'data_b64': base64Encode(Uint8List(250)),
        })));
      }
      channel.serverSendText(jsonEncode(assetEnvelope('ASSET_DONE', <String, dynamic>{
        'transfer_id': 't-dup',
      })));

      await waitFor(
        () =>
            h.events
                .where((e) => e.kind == SyncEventKind.rpcReceived)
                .length >=
            10,
        description: '10 rpcReceived events',
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        h.events.any((e) => e.kind == SyncEventKind.fileReceived),
        isFalse,
      );
    });
  });
}
