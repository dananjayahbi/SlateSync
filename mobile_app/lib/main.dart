/// SlateSync Studio — Wave 3.A master shell (Doc 05 stub finalized here).
///
/// Wires the Doc 26 Home Canvas Gallery to the Wave 3.A Infinite Canvas
/// Studio route (`features/canvas/canvas_studio_page.dart`) through one
/// app-lifetime Doc 25 `VectorSyncClient` shared with the export sheet and
/// canvas RPC/live-frame paths, plus the Doc 02 §8 round-4
/// [CanvasSyncBridge] that mirrors canvas open/list state to the PC.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'core/models/canvas_models.dart';
import 'core/theme/studio_theme.dart';
import 'features/canvas/canvas_studio_page.dart';
import 'features/home/home_canvas_dashboard.dart';
import 'features/pairing/pairing_screen.dart';
import 'features/pairing/pairing_session_controller.dart';
import 'features/sync/canvas_sync_bridge.dart';
import 'network/pairing_credentials_store.dart';
import 'network/vector_sync_client.dart';

void main() {
  runApp(const SlateSyncApp());
}

class SlateSyncApp extends StatefulWidget {
  const SlateSyncApp({
    super.key,
    this.client,
    this.credentialsStore,
    this.deviceName,
    this.autoConnect = true,
  });

  /// Optional app-lifetime sync client (tests inject a fake; `null` ⇒ the
  /// State creates and owns one, exactly as before).
  final VectorSyncClient? client;

  /// Credentials persistence seam (tests inject a sandboxed store file;
  /// `null` ⇒ path_provider app-support `slatesync_pairing.json`).
  final PairingCredentialsStore? credentialsStore;

  /// Optional tablet display name published as `device_name`.
  final String? deviceName;

  /// Silent reconnect from the saved pairing on start; tests that drive the
  /// shell without storage pass `false`.
  final bool autoConnect;

  @override
  State<SlateSyncApp> createState() => _SlateSyncAppState();
}

class _SlateSyncAppState extends State<SlateSyncApp> {
  /// One sync client for the whole app: the studio page streams strokes and
  /// the export sheet shares the same connection + event stream.
  late final VectorSyncClient _client;

  /// Doc 02 §8 canvas sync bridge: `CANVAS_LIST` pushes + `OPEN_CANVAS`
  /// (canvas dialect) hand-off for PC-initiated switches.
  late final CanvasSyncBridge _bridge;

  /// Remembers the last successful pairing and silently reconnects on start
  /// (the PC keeps a static token, so one QR scan is permanent).
  late final PairingSessionController _pairing;

  /// Route pushes go through the `MaterialApp` navigator directly: this
  /// State's `context` sits ABOVE `MaterialApp`, so `Navigator.of(context)`
  /// would find no Navigator ancestor (release builds: null-check crash on
  /// `navigator!` — Issue 02 "Can't open a canvas").
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// Issue 03 round 5: bumped whenever a studio route completes (popped
  /// back to home, or superseded by a later switch) so the home gallery
  /// deterministically re-reads its rows on return (wired through
  /// [HomeCanvasDashboard.refreshListenable] together with the bridge's
  /// Doc 02 §9 `hubChanged`).
  final ValueNotifier<int> _returnRefresh = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? VectorSyncClient();
    _pairing = PairingSessionController(
      client: _client,
      store: widget.credentialsStore ?? PairingCredentialsStore(),
      deviceName: widget.deviceName,
    );
    _bridge = CanvasSyncBridge(client: _client, deviceName: widget.deviceName);
    _bridge.remoteOpen.addListener(_onRemoteOpen);
    if (widget.autoConnect) {
      // Silent reconnect with the saved pairing; on failure the normal
      // pairing screen takes over with a status line.
      unawaited(_restorePairing());
    }
  }

  /// Auto-connect on start. Nothing saved ⇒ stay on the home gallery (the
  /// existing "Connect" entry point); saved but unreachable ⇒ fall back to
  /// [PairingScreen] with an explanatory notice. Never hangs, never crashes,
  /// and the gallery stays usable offline.
  Future<void> _restorePairing() async {
    final bool online = await _pairing.autoConnect();
    if (!mounted || online || !_pairing.hadSavedCredentials) {
      return;
    }
    _showPairingFallback(_pairing.lastError);
  }

  /// Opens [PairingScreen] with [notice]. Direct push when the navigator is
  /// already mounted (the normal case — auto-connect awaits real I/O), else
  /// deferred to the first frame.
  void _showPairingFallback(String? notice) {
    void push() {
      final NavigatorState? navigator = _navigatorKey.currentState;
      // The user may have navigated (studio/pairing) meanwhile.
      if (!mounted || navigator == null || navigator.canPop()) {
        return;
      }
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) =>
                PairingScreen(client: _client, notice: notice),
          ),
        ),
      );
    }

    if (_navigatorKey.currentState != null) {
      push();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => push());
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    _bridge.remoteOpen.removeListener(_onRemoteOpen);
    unawaited(_bridge.dispose());
    unawaited(_pairing.dispose());
    if (widget.client == null) {
      unawaited(_client.dispose()); // only dispose the client we created
    }
    super.dispose();
  }

  void _openCanvas(CanvasDocumentModel doc) {
    // Doc 02 §8.3.1 — mobile open/create/switch broadcasts the full
    // document so the PC mirrors it. Fire-and-forget: navigation must not
    // wait on the wire.
    unawaited(_bridge.announceOpen(doc));
    final NavigatorState? navigator = _navigatorKey.currentState;
    assert(
      navigator != null,
      'SlateSyncApp navigator must be mounted before opening a canvas',
    );
    if (navigator == null) {
      return;
    }
    _pushStudio(navigator, doc);
  }

  /// Issue 03 round 5 — single-studio navigation invariant: EVERY studio
  /// entry (local gallery open, create-new flow, remote/bridge open, hub
  /// driven switch) leaves EXACTLY ONE [CanvasStudioPage] in the stack,
  /// with the home gallery as the root route.
  ///
  /// `pushAndRemoveUntil(... (r) => r.isFirst)` removes whatever else is
  /// stacked above home — a stale studio buried under a dialog, a second
  /// studio from a rapid double-open race — so studio routes can never
  /// nest ("overlapping canvases") and Back always lands on home. From a
  /// bare `[home]` stack it degenerates to a plain push, preserving the
  /// original behavior.
  ///
  /// Completing the pushed route (Back, or a later switch superseding it)
  /// bumps [_returnRefresh] to refresh the gallery beneath.
  void _pushStudio(NavigatorState navigator, CanvasDocumentModel doc) {
    final pushed = navigator.pushAndRemoveUntil<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            CanvasStudioPage(document: doc, client: _client),
      ),
      (Route<dynamic> route) => route.isFirst,
    );
    unawaited(
      pushed.then((_) {
        _returnRefresh.value += 1;
      }),
    );
  }

  /// Doc 02 §8.3.3 — a PC-initiated open arrives through
  /// [CanvasSyncBridge.remoteOpen] (single-shot; cleared after consume).
  ///
  /// Navigation uses the `navigatorKey`'s Navigator (never
  /// `Navigator.of(this.context)` — that context sits above `MaterialApp`,
  /// Issue 02) through [_pushStudio]: whatever is on top — studio, pairing,
  /// an export sheet, a dialog — the remote switch REPLACES the whole
  /// stack above home, so repeated PC-initiated switches never stack stale
  /// routes (round 4's top-only `pushReplacement` left a buried old studio
  /// alive when a dialog covered it) and Back always lands on the home
  /// gallery.
  void _onRemoteOpen() {
    final CanvasDocumentModel? doc = _bridge.remoteOpen.value;
    if (doc == null) {
      return;
    }
    final NavigatorState? navigator = _navigatorKey.currentState;
    if (navigator == null) {
      return; // not mounted yet — value stays set for a later consume
    }
    _bridge.remoteOpen.value = null; // clear after consume (single-shot)
    _pushStudio(navigator, doc);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SlateSync Studio',
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: StudioTheme.bg,
        colorScheme: const ColorScheme.light(
          surface: StudioTheme.surface,
          primary: StudioTheme.accent,
          error: StudioTheme.danger,
          onPrimary: StudioTheme.text,
          onSurface: StudioTheme.text,
        ),
      ),
      // Issue 02: the app is light-only; no dark variant is wired.
      themeMode: ThemeMode.light,
      home: HomeCanvasDashboard(
        onOpenDocument: _openCanvas,
        client: _client,
        // Doc 02 §8.1 — create/rename/delete pushes a fresh CANVAS_LIST.
        onListChanged: _bridge.publishList,
        // Doc 02 §9 (round 5): hub store mutations (bridge.hubChanged) plus
        // returns to this route (studio popped/superseded ⇒ _returnRefresh)
        // re-read the gallery rows — debounced inside the dashboard.
        refreshListenable: Listenable.merge(<Listenable>[
          _bridge.hubChanged,
          _returnRefresh,
        ]),
      ),
    );
  }
}
