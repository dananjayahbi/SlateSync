/// Pairing session glue: remembers the last successful pairing and dials it
/// again on the next launch.
///
/// Consumes [PairingCredentialsStore] (persistence) and drives the Doc 25
/// [VectorSyncClient] state machine:
///
///  * [autoConnect] — cold-start attempt with the saved credentials; a
///    timeout/auth failure simply returns `false` (never throws, never hangs)
///    so the caller can fall back to [PairingScreen].
///  * save-on-online — every transition to [SyncState.online] persists the
///    pairing that produced it, so a QR scan, manual entry, mDNS discovery
///    or the auto-connect itself all become the remembered pairing.
///
/// Injected into the shell (`main.dart`) rather than baked into the widgets;
/// pure Dart + an injected store, so tests need no path_provider, no sockets.
library;

import 'dart:async';

import 'package:mobile_app/network/pairing_credentials_store.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

/// Status copy shown on [PairingScreen] when the silent reconnect failed.
const String kPairingAutoConnectFailedNotice =
    'Could not reach the last paired SlateSync PC — '
    'scan the QR code or enter the IP manually.';

/// Status copy when the PC rejected the remembered token (close 4001).
const String kPairingAuthFailedNotice =
    'The PC no longer accepts the saved pairing — '
    'scan the new QR code to pair again.';

/// Result of one silent reconnect attempt.
enum _AutoConnectOutcome { online, authFailed, failed }

/// Owns "last pairing" persistence for one app-lifetime sync client.
class PairingSessionController {
  PairingSessionController({
    required this.client,
    PairingCredentialsStore? store,
    this.deviceName,
    this.attemptTimeout = const Duration(seconds: 8),
  }) : store = store ?? PairingCredentialsStore() {
    _subscription = client.events.listen(_onSyncEvent);
  }

  /// Doc 25 client whose state transitions are observed.
  final VectorSyncClient client;

  /// Credentials persistence (injectable for tests).
  final PairingCredentialsStore store;

  /// How long a silent reconnect may take before it counts as failed.
  final Duration attemptTimeout;

  /// Optional tablet display name recorded with the credentials.
  String? deviceName;

  StreamSubscription<SyncEvent>? _subscription;
  PairingCredentials? _lastSaved;
  bool _hadSavedCredentials = false;
  String? _lastError;
  bool _disposed = false;

  /// Credentials persisted on disk before the current attempt (test/UI
  /// diagnostics).
  PairingCredentials? get savedCredentials => _lastSaved;

  /// Whether [autoConnect] found saved credentials on disk.
  bool get hadSavedCredentials => _hadSavedCredentials;

  /// Human-readable reason the last [autoConnect] failed; `null` on success.
  String? get lastError => _lastError;

  /// Reconnects with the persisted pairing. Returns `true` once the client is
  /// online, `false` when there was nothing saved or the attempt did not
  /// reach [SyncState.online] within [attemptTimeout]. Never throws.
  Future<bool> autoConnect() async {
    if (_disposed) {
      return false;
    }
    final PairingCredentials? saved = await store.load();
    _lastSaved = saved;
    _hadSavedCredentials = saved != null;
    if (saved == null) {
      _lastError = null;
      return false;
    }
    final _AutoConnectOutcome outcome = await _connectAndWait(saved);
    switch (outcome) {
      case _AutoConnectOutcome.online:
        _lastError = null;
        return true;
      case _AutoConnectOutcome.authFailed:
        // The PC rotated its token: the saved pairing is dead — forget it so
        // the next launch goes straight to the pairing screen.
        _lastError = kPairingAuthFailedNotice;
        _lastSaved = null;
        await store.clear();
        return false;
      case _AutoConnectOutcome.failed:
        // Transient (PC off / not on this network): keep the credentials and
        // let the normal pairing screen take over.
        _lastError = kPairingAutoConnectFailedNotice;
        return false;
    }
  }

  /// Persists [info] (the pairing the user just completed). Duplicate saves
  /// are skipped, and persistence failures never surface to the caller.
  Future<void> saveFromPairing(PairingInfo info) async {
    final PairingCredentials credentials = PairingCredentials.fromPairingInfo(
      info,
      deviceName: deviceName,
    );
    if (_lastSaved == credentials) {
      return;
    }
    _lastSaved = credentials;
    await store.save(credentials);
  }

  /// Forgets the saved pairing (stale token / explicit re-pair).
  Future<void> forget() async {
    _lastSaved = null;
    _hadSavedCredentials = false;
    await store.clear();
  }

  Future<void> dispose() async {
    _disposed = true;
    final StreamSubscription<SyncEvent>? subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  void _onSyncEvent(SyncEvent event) {
    if (_disposed ||
        event.kind != SyncEventKind.stateChanged ||
        event.state != SyncState.online) {
      return;
    }
    final PairingInfo? info = client.pairing;
    if (info == null) {
      return; // fake/standalone client without a recorded pairing
    }
    unawaited(saveFromPairing(info));
  }

  Future<_AutoConnectOutcome> _connectAndWait(
    PairingCredentials credentials,
  ) async {
    if (client.isConnected) {
      return _AutoConnectOutcome.online;
    }
    final Completer<_AutoConnectOutcome> completer =
        Completer<_AutoConnectOutcome>();
    void settle(_AutoConnectOutcome outcome) {
      if (!completer.isCompleted) {
        completer.complete(outcome);
      }
    }

    final StreamSubscription<SyncEvent> sub = client.events.listen((
      SyncEvent event,
    ) {
      if (event.kind != SyncEventKind.stateChanged) {
        return;
      }
      if (event.state == SyncState.online) {
        settle(_AutoConnectOutcome.online);
      } else if (event.state == SyncState.authFailed) {
        settle(_AutoConnectOutcome.authFailed);
      }
    });
    try {
      await client.connect(credentials.toPairingInfo());
      if (client.isConnected) {
        return _AutoConnectOutcome.online;
      }
      return await completer.future.timeout(
        attemptTimeout,
        onTimeout: () => _AutoConnectOutcome.failed,
      );
    } catch (_) {
      return _AutoConnectOutcome.failed;
    } finally {
      await sub.cancel();
    }
  }
}
