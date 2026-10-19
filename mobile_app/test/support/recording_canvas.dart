import 'dart:ui' show Picture;

import 'package:flutter/painting.dart';

/// Deterministic [Canvas] spy for painter tests (Issue 02 draw-path
/// assertions): records draw-call names together with the [Paint] used,
/// forwarding nothing. Non-overridden calls fall through to [noSuchMethod]
/// (void methods are safe; the painters under test issue no value-returning
/// calls besides those overridden here).
class RecordingCanvas implements Canvas {
  /// Insertion-ordered map of call name → paints seen for that call
  /// (repeated calls append; paint-less calls record a fresh [Paint]).
  final Map<String, List<Paint>> paintsByCall = <String, List<Paint>>{};

  /// Distinct call names in first-seen order.
  List<String> get calls => paintsByCall.keys.toList(growable: false);

  /// Every paint recorded for [call].
  List<Paint> paintsOf(String call) => paintsByCall[call] ?? const <Paint>[];

  /// True when [call] was issued at least once.
  bool didCall(String call) => paintsByCall.containsKey(call);

  void _record(String call, Paint? paint) {
    paintsByCall.putIfAbsent(call, () => <Paint>[]).add(paint ?? Paint());
  }

  @override
  void drawRect(Rect rect, Paint paint) => _record('drawRect', paint);

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) =>
      _record('drawLine', paint);

  @override
  void drawCircle(Offset c, double radius, Paint paint) =>
      _record('drawCircle', paint);

  @override
  void drawPath(Path path, Paint paint) => _record('drawPath', paint);

  @override
  void drawPicture(Picture picture) => _record('drawPicture', null);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
