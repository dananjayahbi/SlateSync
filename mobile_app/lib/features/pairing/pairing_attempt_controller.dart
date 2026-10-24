/// Waits for the outcome of one pairing attempt so the UI can report it.
///
/// Scanning the QR used to call `client.connect()` and pop the screen
/// immediately, so a tablet that could not reach the PC (wrong network, PC
/// firewall, stale token) returned to the gallery with **no feedback at all**
/// — the reported "it doesn't catch the device and says nothing".
///
/// This controller owns the wait: it subscribes to the Doc 25 state machine
/// BEFORE dialling (so a fast `online` is never missed), settles on the first
/// terminal outcome, and exposes it through [PairingAttemptStatus] plus
/// [ValueNotifier]s the screen can rebuild from. Pure Dart + an injected
/// client: no widgets, no storage, no real timers in tests beyond `fakeAsync`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:mobile_app/features/pairing/pairing_session_controller.dart'
    show kPairingAuthFailedNotice;
import 'package:mobile_app/network/vector_sync_client.dart';

/// Copy shown while the handshake is in flight.
const String kPairingConnectingNotice =
    'Connecting to the SlateSync PC…';

/// Copy shown when the PC never answered (wrong network / firewall / PC off).
String kPairingTimeoutNotice(PairingInfo info) =>
    'No answer from ${info.ipv4}:${info.port} — make sure the PC agent is '
    'running and both devices are on the same network, then scan again.';

/// Copy shown when the scanned token is not the PC's current one.
const String kPairingRejectedNotice = kPairingAuthFailedNotice;

/// How one pairing attempt ended.
enum PairingAttemptStatus { idle, connecting, online, authFailed, unreachable }

/// Drives one `connect()` and publishes its terminal outcome.
class PairingAttemptController {
  PairingAttemptController({
    required this.client,
    this.timeout = const Duration(seconds: 12),
  });

  /// Doc 25 client whose state transitions are observed.
  final VectorSyncClient client;

  /// How long a handshake may take before it counts as unreachable.
  final Duration timeout;

  /// Current phase — screens rebuild from this.
  final ValueNotifier<PairingAttemptStatus> status =
      ValueNotifier<PairingAttemptStatus>(PairingAttemptStatus.idle);

  /// Human-readable reason for the last non-online outcome; `null` otherwise.
  final ValueNotifier<String?> message = ValueNotifier<String?>(null);

  /// Pairing currently being attempted (`null` when idle/finished).
  PairingInfo? get attempt => _attempt;

  PairingInfo? _attempt;
  StreamSubscription<SyncEvent>? _subscription;
  Timer? _timer;
  bool _disposed = false;

  /// Starts (or restarts) the attempt for [info]. Never throws.
  Future<void> start(PairingInfo info) async {
    if (_disposed || status.value == PairingAttemptStatus.connecting) {
      return;
    }
    _finishWait();
    _attempt = info;
    status.value = PairingAttemptStatus.connecting;
    message.value = kPairingConnectingNotice;
    _subscription = client.events.listen(_onSyncEvent);
    _timer = Timer(timeout, () => _settle(PairingAttemptStatus.unreachable));
    try {
      await client.connect(info);
    } catch (_) {
      _settle(PairingAttemptStatus.unreachable);
      return;
    }
    if (client.isConnected) {
      _settle(PairingAttemptStatus.online);
    }
  }

  /// Stops waiting without touching the connection (user pressed Cancel).
  void cancel() {
    _finishWait();
    status.value = PairingAttemptStatus.idle;
    message.value = null;
    _attempt = null;
  }

  void dispose() {
    _disposed = true;
    _finishWait();
    status.dispose();
    message.dispose();
  }

  void _onSyncEvent(SyncEvent event) {
    if (_disposed || event.kind != SyncEventKind.stateChanged) {
      return;
    }
    if (event.state == SyncState.online) {
      // Also covers a Doc 25 backoff retry landing after the timeout: the PC
      // came up late, so the pairing did succeed — stop reporting a failure.
      _settle(PairingAttemptStatus.online);
    } else if (event.state == SyncState.authFailed) {
      _settle(PairingAttemptStatus.authFailed);
    }
  }

  void _settle(PairingAttemptStatus outcome) {
    if (_disposed) {
      return;
    }
    final PairingAttemptStatus current = status.value;
    // Terminal outcomes are sticky, except that a late retry may still connect
    // after the timeout was reported.
    if (current == PairingAttemptStatus.online ||
        current == PairingAttemptStatus.authFailed ||
        current == PairingAttemptStatus.idle) {
      return;
    }
    if (current == PairingAttemptStatus.unreachable &&
        outcome == PairingAttemptStatus.unreachable) {
      return; // the timeout already reported this
    }
    switch (outcome) {
      case PairingAttemptStatus.online:
        _finishWait();
        message.value = null;
      case PairingAttemptStatus.authFailed:
        _finishWait();
        message.value = kPairingRejectedNotice;
      case PairingAttemptStatus.unreachable:
        // Keep listening: the client's own backoff may still connect, and that
        // must clear the failure instead of leaving a stale error on screen.
        _cancelTimer();
        message.value = kPairingTimeoutNotice(_attempt!);
      case PairingAttemptStatus.idle:
      case PairingAttemptStatus.connecting:
        return;
    }
    status.value = outcome;
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _finishWait() {
    _cancelTimer();
    final StreamSubscription<SyncEvent>? subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
  }
}
