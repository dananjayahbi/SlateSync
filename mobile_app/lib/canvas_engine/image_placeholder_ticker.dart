/// Round-12 issue 06 — the tick that animates image placeholders.
///
/// A tile bake is synchronous and CACHED (`tiled_canvas_painter`), so a
/// placeholder painted once would freeze mid-sweep. Something has to request new
/// frames while any image is still decoding, and stop as soon as they are all
/// resolved.
///
/// [ImagePlaceholderTicker] owns that decision: the studio page registers the
/// asset cache, and the ticker runs a small repeating timer only while the cache
/// reports at least one pending asset. When nothing is pending it stops, so an
/// idle canvas costs nothing.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Frames per second for the sheen. 20 is smooth enough for a slow sweep and
/// cheap enough to keep the tile rebake off the critical path.
const int kPlaceholderFps = 20;

/// Drives [phase] from 0..1 in a loop while [pending] reports work.
class ImagePlaceholderTicker {
  ImagePlaceholderTicker({
    required this.pending,
    required this.onTick,
    this.fps = kPlaceholderFps,
    this.duration = const Duration(milliseconds: 1400),
  });

  /// Returns true while at least one placeholder is on screen.
  final bool Function() pending;

  /// Called each frame with a new phase, and with `paused` once when it stops.
  final void Function(double phase) onTick;

  final int fps;

  /// One full sweep of the sheen.
  final Duration duration;

  Timer? _timer;
  Stopwatch _clock = Stopwatch();
  double _phase = 0.0;
  bool _disposed = false;

  /// Current phase in `0..1` (also the value a static paint can reuse).
  double get phase => _phase;

  @visibleForTesting
  bool get isRunning => _timer != null;

  /// Starts animating if there is pending work. Safe to call repeatedly.
  void ensureRunning() {
    if (_disposed || _timer != null) {
      return;
    }
    if (!pending()) {
      return;
    }
    _clock = Stopwatch()..start();
    _timer = Timer.periodic(
      Duration(milliseconds: (1000 / fps).round()),
      (_) => _advance(),
    );
  }

  /// Stops animating (nothing is pending). Safe to call repeatedly.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
  }

  /// Called after a decode resolves: stop if that was the last one.
  void onAssetReady() {
    if (_disposed) {
      return;
    }
    if (!pending()) {
      stop();
    }
  }

  void _advance() {
    if (_disposed) {
      stop();
      return;
    }
    if (!pending()) {
      stop(); // last image landed — stop driving frames
      return;
    }
    final int totalMicros = duration.inMicroseconds;
    if (totalMicros <= 0) {
      return;
    }
    _phase = (_clock.elapsedMicroseconds % totalMicros) / totalMicros;
    onTick(_phase);
  }

  void dispose() {
    _disposed = true;
    stop();
  }
}
