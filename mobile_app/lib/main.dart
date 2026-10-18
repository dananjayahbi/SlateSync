/// SlateSync Studio — Wave 3.A master shell (Doc 05 stub finalized here).
///
/// Wires the Doc 26 Home Canvas Gallery to the Wave 3.A Infinite Canvas
/// Studio route (`features/canvas/canvas_studio_page.dart`) through one
/// app-lifetime Doc 25 `VectorSyncClient` shared with the export sheet and
/// canvas RPC/live-frame paths.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'core/models/canvas_models.dart';
import 'core/theme/studio_theme.dart';
import 'features/canvas/canvas_studio_page.dart';
import 'features/home/home_canvas_dashboard.dart';
import 'network/vector_sync_client.dart';

void main() {
  runApp(const SlateSyncApp());
}

class SlateSyncApp extends StatefulWidget {
  const SlateSyncApp({super.key});

  @override
  State<SlateSyncApp> createState() => _SlateSyncAppState();
}

class _SlateSyncAppState extends State<SlateSyncApp> {
  /// One sync client for the whole app: the studio page streams strokes and
  /// the export sheet shares the same connection + event stream.
  final VectorSyncClient _client = VectorSyncClient();

  @override
  void dispose() {
    unawaited(_client.dispose());
    super.dispose();
  }

  void _openCanvas(CanvasDocumentModel doc) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            CanvasStudioPage(document: doc, client: _client),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SlateSync Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: StudioTheme.bg,
        colorScheme: const ColorScheme.dark(
          surface: StudioTheme.surface,
          primary: StudioTheme.accent,
          error: StudioTheme.danger,
          onPrimary: StudioTheme.text,
          onSurface: StudioTheme.text,
        ),
      ),
      home: HomeCanvasDashboard(onOpenDocument: _openCanvas),
    );
  }
}
