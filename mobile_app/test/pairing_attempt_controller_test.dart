/// Regression — a failed pairing must be *visible* (Doc 25 §5 step 2).
///
/// Reported bug: "when I scan the QR, it doesn't catch the device. Also it
/// says nothing." The scan path called `connect()` and popped the screen
/// immediately, so a timeout or a rejected token returned to the gallery with
/// no message. `PairingAttemptController` waits for the handshake and turns
/// each outcome into copy the screen renders.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/features/pairing/pairing_attempt_controller.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

class _FakeClient extends VectorSyncClient {
  final StreamController<SyncEvent> _events =
      StreamController<SyncEvent>.broadcast();
  final List<PairingInfo> connects = <PairingInfo>[];

  /// State the scripted handshake settles on; `null` ⇒ never settles.
  SyncState? handshake;

  bool throwOnConnect = false;

  SyncState _state = SyncState.idle;
  PairingInfo? _info;

  @override
  Stream<SyncEvent> get events => _events.stream;

  @override
  SyncState get state => _state;

  @override
  PairingInfo? get pairing => _info;

  @override
  bool get isConnected => _state == SyncState.online;

  @override
  Future<void> connect(PairingInfo info) async {
    connects.add(info);
    _info = info;
    if (throwOnConnect) {
      throw StateError('dial refused');
    }
    final SyncState? next = handshake;
    if (next != null) {
      _state = next;
      _events.add(SyncEvent(kind: SyncEventKind.stateChanged, state: next));
    }
  }

  void emitState(SyncState state) {
    _state = state;
    _events.add(SyncEvent(kind: SyncEventKind.stateChanged, state: state));
  }
}

const PairingInfo _qrInfo = PairingInfo(
  ipv4: '192.168.1.244',
  port: kSyncWsPort,
  token: 'tok',
);

void main() {
  late _FakeClient client;

  setUp(() {
    client = _FakeClient();
  });

  tearDown(() async {
    await client.dispose();
  });

  test('online handshake settles on online with no message', () async {
    client.handshake = SyncState.online;
    final PairingAttemptController controller = PairingAttemptController(
      client: client,
    );
    addTearDown(controller.dispose);

    await controller.start(_qrInfo);

    expect(client.connects, <PairingInfo>[_qrInfo]);
    expect(controller.status.value, PairingAttemptStatus.online);
    expect(controller.message.value, isNull);
  });

  test('connecting is published before the handshake completes', () async {
    client.handshake = null; // never settles on its own
    final PairingAttemptController controller = PairingAttemptController(
      client: client,
      timeout: const Duration(milliseconds: 40),
    );
    addTearDown(controller.dispose);

    final Future<void> pending = controller.start(_qrInfo);
    await Future<void>.delayed(Duration.zero);
    expect(controller.status.value, PairingAttemptStatus.connecting);
    expect(controller.message.value, kPairingConnectingNotice);
    await pending;
    controller.cancel();
  });

  test('rejected token reports the re-pair notice', () async {
    client.handshake = SyncState.authFailed;
    final PairingAttemptController controller = PairingAttemptController(
      client: client,
    );
    addTearDown(controller.dispose);

    await controller.start(_qrInfo);

    expect(controller.status.value, PairingAttemptStatus.authFailed);
    expect(controller.message.value, kPairingRejectedNotice);
  });

  test('silent PC (no close frame) times out with the address in the copy',
      () async {
    client.handshake = null;
    final PairingAttemptController controller = PairingAttemptController(
      client: client,
      timeout: const Duration(milliseconds: 30),
    );
    addTearDown(controller.dispose);

    await controller.start(_qrInfo);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(controller.status.value, PairingAttemptStatus.unreachable);
    expect(controller.message.value, contains('192.168.1.244:50606'));
    expect(controller.message.value, contains('same network'));
  });

  test('a connect() that throws counts as unreachable', () async {
    client.throwOnConnect = true;
    final PairingAttemptController controller = PairingAttemptController(
      client: client,
    );
    addTearDown(controller.dispose);

    await controller.start(_qrInfo);

    expect(controller.status.value, PairingAttemptStatus.unreachable);
    expect(controller.message.value, kPairingTimeoutNotice(_qrInfo));
  });

  test('a late online retry after the timeout clears the failure', () async {
    // The Doc 25 client keeps its own backoff ladder: if the PC comes up late
    // the pairing really did succeed, so a stale error must not stay on screen.
    client.handshake = null;
    final PairingAttemptController controller = PairingAttemptController(
      client: client,
      timeout: const Duration(milliseconds: 30),
    );
    addTearDown(controller.dispose);

    await controller.start(_qrInfo);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(controller.status.value, PairingAttemptStatus.unreachable);

    client.emitState(SyncState.online);
    await Future<void>.delayed(Duration.zero); // broadcast streams are async

    expect(controller.status.value, PairingAttemptStatus.online);
    expect(controller.message.value, isNull);
  });

  test('a late authFailed after the timeout replaces the notice', () async {
    client.handshake = null;
    final PairingAttemptController controller = PairingAttemptController(
      client: client,
      timeout: const Duration(milliseconds: 30),
    );
    addTearDown(controller.dispose);

    await controller.start(_qrInfo);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    client.emitState(SyncState.authFailed);
    await Future<void>.delayed(Duration.zero);

    expect(controller.status.value, PairingAttemptStatus.authFailed);
    expect(controller.message.value, kPairingRejectedNotice);
  });

  test('cancel returns to idle and clears the attempt', () async {
    client.handshake = null;
    final PairingAttemptController controller = PairingAttemptController(
      client: client,
      timeout: const Duration(seconds: 5),
    );
    addTearDown(controller.dispose);

    final Future<void> pending = controller.start(_qrInfo);
    await Future<void>.delayed(Duration.zero);
    controller.cancel();

    expect(controller.status.value, PairingAttemptStatus.idle);
    expect(controller.message.value, isNull);
    expect(controller.attempt, isNull);
    await pending;
  });

  test('start is ignored while an attempt is still connecting', () async {
    client.handshake = null;
    final PairingAttemptController controller = PairingAttemptController(
      client: client,
      timeout: const Duration(milliseconds: 40),
    );
    addTearDown(controller.dispose);

    final Future<void> first = controller.start(_qrInfo);
    await Future<void>.delayed(Duration.zero);
    await controller.start(
      const PairingInfo(ipv4: '10.0.0.9', port: kSyncWsPort, token: 'other'),
    );

    expect(client.connects, hasLength(1));
    await first;
    controller.cancel();
  });
}
