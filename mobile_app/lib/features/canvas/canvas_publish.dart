/// Round-9 issue 08 — publish the OPEN canvas so the PC mirror can follow
/// artboard-level edits (background style / spacing, paper colour, size).
///
/// The stream contract has no `UPDATE_ARTBOARD` action and
/// `ws_rpc_schema.json` is frozen, so the only legal carrier is the round-5
/// hub action `CANVAS_PUT {canvas, source}` (`hub_sync.dart`
/// `canvasPutEnvelope`). Sending it does NOT navigate or switch anything on
/// either side — the PC applies it as an LWW store update.
///
/// Kept in its own file so `canvas_studio_page.dart` stays a wiring surface
/// and the envelope shape lives next to the other §9 helpers' consumer.
library;

import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/features/sync/hub_sync.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

/// Broadcasts [doc] as a `CANVAS_PUT` owned by this device.
///
/// Best-effort: an offline client queues or drops the frame, and a failure
/// must never break the local save that triggered it.
Future<void> publishCanvasDocument(
  VectorSyncClient client,
  CanvasDocumentModel doc,
) async {
  try {
    await client.sendRpc(canvasPutEnvelope(doc, source: 'device'));
  } catch (_) {
    // Sync is a mirror, not the store of record — never surface this.
  }
}

/// Snapshot of the artboard fields a mirror cares about, used to decide
/// whether a save actually changed the page look (and therefore whether a
/// `CANVAS_PUT` is worth sending).
class ArtboardFingerprint {
  const ArtboardFingerprint({
    required this.preset,
    required this.style,
    required this.spacing,
    required this.color,
    required this.width,
    required this.height,
  });

  factory ArtboardFingerprint.of(Artboard artboard) => ArtboardFingerprint(
        preset: artboard.preset,
        style: artboard.backgroundStyle,
        spacing: artboard.backgroundSpacing,
        color: artboard.backgroundColor,
        width: artboard.width,
        height: artboard.height,
      );

  final String preset;
  final String style;
  final double spacing;
  final String color;
  final double? width;
  final double? height;

  @override
  bool operator ==(Object other) =>
      other is ArtboardFingerprint &&
      other.preset == preset &&
      other.style == style &&
      other.spacing == spacing &&
      other.color == color &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(preset, style, spacing, color, width, height);
}
