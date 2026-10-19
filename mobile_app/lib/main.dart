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
import 'features/sync/canvas_sync_bridge.dart';
import 'network/vector_sync_client.dart';

void main() {
  runApp(const SlateSyncApp());
}

class SlateSyncApp extends StatefulWidget {
  const SlateSyncApp({super.key, this.client});

  /// Optional app-lifetime sync client (tests inject a fake; `null` ⇒ the
  /// State creates and owns one, exactly as before).
  final VectorSyncClient? client;

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

  /// Route pushes go through the `MaterialApp` navigator directly: this
  /// State's `context` sits ABOVE `MaterialApp`, so `Navigator.of(context)`
  /// would find no Navigator ancestor (release builds: null-check crash on
  /// `navigator!` — Issue 02 "Can't open a canvas").
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? VectorSyncClient();
    _bridge = CanvasSyncBridge(client: _client);
    _bridge.remoteOpen.addListener(_onRemoteOpen);
  }

  @override
  void dispose() {
    _bridge.remoteOpen.removeListener(_onRemoteOpen);
    unawaited(_bridge.dispose());
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
    navigator?.push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            CanvasStudioPage(document: doc, client: _client),
      ),
    );
  }

  /// Doc 02 §8.3.3 — a PC-initiated open arrives through
  /// [CanvasSyncBridge.remoteOpen] (single-shot; cleared after consume).
  ///
  /// Navigation uses the `navigatorKey`'s Navigator (never
  /// `Navigator.of(this.context)` — that context sits above `MaterialApp`,
  /// Issue 02). If something is already pushed (studio, pairing, dialog) it
  /// is REPLACED so repeated PC-initiated switches never stack stale
  /// routes — back always lands on the home gallery; from the home gallery
  /// itself the studio is pushed on top, preserving the existing stack.
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
    final MaterialPageRoute<void> route = MaterialPageRoute<void>(
      builder: (BuildContext context) =>
          CanvasStudioPage(document: doc, client: _client),
    );
    if (navigator.canPop()) {
      navigator.pushReplacement(route);
    } else {
      navigator.push(route);
    }
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
      ),
    );
  }
}
