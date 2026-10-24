/// Pairing UX (Issue 03): one screen with the three Doc 25 §5 step 1–2
/// pairing modes — auto-discover (`client.discover()`), QR scan (Doc 25
/// [PairingScanner] parsing `slatesync://connect?ip=&port=&token=` via the
/// frozen `parsePairingUrl`) and manual IP entry (Doc 25
/// [ManualPairingScreen]).
///
/// Entry points: the Home app bar "Connect" icon
/// (`HomeCanvasDashboard`) and the Studio top bar connection button — both
/// push this screen. On a successful pair the screen pops back and the Doc 25
/// connection state machine proceeds; openers follow `client.events`
/// `StateChanged` to update their banner/status label.
///
/// Camera failures (permission denied / no camera) fall back to manual entry
/// with an explicit hint. Tests inject [PairingScreen.scannerBuilder] so no
/// real camera or network is ever touched.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:mobile_app/core/theme/studio_theme.dart'; // Doc 05
import 'package:mobile_app/network/vector_sync_client.dart'; // Doc 25

/// Builds the QR scanner widget for [PairingScreen]. Mirrors
/// [PairingScanner]'s constructor so tests can substitute a fake camera.
typedef PairingScannerBuilder = Widget Function({
  required void Function(PairingInfo info) onPair,
  required void Function(MobileScannerErrorCode code) onCameraError,
});

/// Copy shown when auto-discover times out or fails (Doc 25 §5 step 1:
/// caller falls back to manual entry / QR).
const String kDiscoverFailedHint =
    "Couldn't find a SlateSync PC on this network — "
    'scan the QR code or enter the IP manually.';

String _cameraErrorMessage(MobileScannerErrorCode code) => switch (code) {
      MobileScannerErrorCode.permissionDenied =>
        'Camera permission denied — enter the PC address manually.',
      MobileScannerErrorCode.unsupported =>
        'No camera available on this device — enter the PC address manually.',
      _ => 'Camera unavailable — enter the PC address manually.',
    };

/// Full-screen pairing hub with Auto-discover / Scan QR / Manual IP modes.
class PairingScreen extends StatefulWidget {
  const PairingScreen({
    super.key,
    required this.client,
    this.scannerBuilder,
    this.notice,
  });

  /// App-lifetime Doc 25 client (template §5 surface).
  final VectorSyncClient client;

  /// Test seam — defaults to the Doc 25 [PairingScanner] widget.
  final PairingScannerBuilder? scannerBuilder;

  /// Status shown above the pairing modes — e.g. why the silent reconnect
  /// with the saved credentials did not work
  /// ([kPairingAutoConnectFailedNotice]); `null` ⇒ nothing shown.
  final String? notice;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  bool _discovering = false;
  bool _showScanner = false;
  String? _discoverHint;
  MobileScannerErrorCode? _cameraError;

  // ----- Success paths -----------------------------------------------------

  /// Hands [info] to the Doc 25 state machine and returns to the opener, whose
  /// banner follows `client.events` `StateChanged`.
  void _onPaired(PairingInfo info) {
    unawaited(widget.client.connect(info));
    _popIfMounted();
  }

  /// Manual entry sits on top of this screen: two pops unwind both routes.
  void _onManualPaired(PairingInfo info) {
    unawaited(widget.client.connect(info));
    if (!mounted) {
      return;
    }
    final NavigatorState nav = Navigator.of(context);
    nav.pop(); // manual screen
    nav.pop(); // pairing screen
  }

  void _popIfMounted() {
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
  }

  // ----- Auto-discover -----------------------------------------------------

  Future<void> _runDiscover() async {
    if (_discovering) {
      return;
    }
    setState(() {
      _discovering = true;
      _discoverHint = null;
    });
    try {
      // On success `discover()` has already parsed TXT+A/SRV into a
      // `PairingInfo` and kicked off `connect` (Doc 25 §5 step 1).
      await widget.client.discover();
      if (!mounted) {
        return;
      }
      setState(() => _discovering = false);
      _popIfMounted();
    } catch (_) {
      // TimeoutException (3 s mDNS) or StateError (bad TXT/no A-record):
      // show the manual fallback hint instead (Doc 25 §5 step 10).
      if (!mounted) {
        return;
      }
      setState(() {
        _discovering = false;
        _discoverHint = kDiscoverFailedHint;
      });
    }
  }

  // ----- Scan QR -----------------------------------------------------------

  Widget _defaultScanner({
    required void Function(PairingInfo info) onPair,
    required void Function(MobileScannerErrorCode code) onCameraError,
  }) =>
      PairingScanner(onPair: onPair, onCameraError: onCameraError);

  void _startScan() {
    setState(() {
      _showScanner = true;
      _cameraError = null;
    });
  }

  void _onCameraError(MobileScannerErrorCode code) {
    if (!mounted) {
      return;
    }
    setState(() => _cameraError = code);
  }

  // ----- Manual ------------------------------------------------------------

  void _openManual() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => ManualPairingScreen(
          title: 'Enter IP manually',
          onConnect: _onManualPaired,
        ),
      ),
    );
  }

  // ----- Build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('pairing_screen'),
      backgroundColor: StudioTheme.bg,
      appBar: AppBar(
        backgroundColor: StudioTheme.surface,
        title: const Text('Connect to SlateSync', key: Key('pairing_title')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (widget.notice != null) ...<Widget>[
            Text(
              widget.notice!,
              key: const Key('pairing-auto-connect-notice'),
              style: const TextStyle(color: StudioTheme.danger),
            ),
            const SizedBox(height: 12),
          ],
          _sectionCard(
            icon: Icons.wifi_find,
            title: 'Auto-discover',
            subtitle: 'Find the SlateSync PC automatically on this network',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ElevatedButton(
                  key: const Key('pairing-discover'),
                  onPressed: _discovering ? null : _runDiscover,
                  child: Text(_discovering ? 'Searching…' : 'Search for PC'),
                ),
                if (_discoverHint != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    _discoverHint!,
                    key: const Key('pairing-discover-hint'),
                    style: const TextStyle(color: StudioTheme.danger),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _sectionCard(
            icon: Icons.qr_code_scanner,
            title: 'Scan QR',
            subtitle: 'Point at the QR code shown in the SlateSync PC tray',
            child: _buildScanArea(),
          ),
          const SizedBox(height: 12),
          _sectionCard(
            icon: Icons.lan,
            title: 'Manual IP',
            subtitle: 'IPv4, port $kSyncWsPort and session token',
            child: ElevatedButton(
              key: const Key('pairing-manual'),
              onPressed: _openManual,
              child: const Text('Enter IP manually'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanArea() {
    final MobileScannerErrorCode? error = _cameraError;
    if (error != null) {
      // Permission denied / no camera → manual fallback (Issue 03).
      return Column(
        key: const Key('pairing-camera-fallback'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            _cameraErrorMessage(error),
            key: const Key('pairing-camera-fallback-text'),
            style: const TextStyle(color: StudioTheme.danger),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            key: const Key('pairing-manual-fallback'),
            onPressed: _openManual,
            child: const Text('Enter IP manually'),
          ),
        ],
      );
    }
    if (!_showScanner) {
      return ElevatedButton(
        key: const Key('pairing-scan'),
        onPressed: _startScan,
        child: const Text('Scan QR code'),
      );
    }
    final PairingScannerBuilder buildScanner =
        widget.scannerBuilder ?? _defaultScanner;
    return SizedBox(
      height: 280,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
        child: buildScanner(
          onPair: _onPaired,
          onCameraError: _onCameraError,
        ),
      ),
    );
  }

  Widget _sectionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Card(
      color: StudioTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, color: StudioTheme.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: const TextStyle(
                          color: StudioTheme.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: StudioTheme.text.withValues(alpha: 0.6),
                          fontSize: StudioTheme.captionSize,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
