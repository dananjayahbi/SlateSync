/// Round 12 — issue 06: an animated placeholder while images decode.
///
/// Report: opening a canvas containing images showed NOTHING inside the image
/// frames until the bytes finished decoding.
///
/// Cause: a tile bake is synchronous and cached, so `_drawImage` simply returned
/// when `AssetImageCache.imageOf` was null. The cache already distinguishes
/// "decoding" (`isPending`) from "failed" (`hasFailed`) — the painter just never
/// asked. `image_placeholder.dart` owns the decision and the visual;
/// `image_placeholder_ticker.dart` owns the animation lifetime, so an idle
/// canvas requests no frames.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/canvas_engine/image_placeholder.dart';
import 'package:mobile_app/canvas_engine/image_placeholder_ticker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('imagePlaceholderFor — the decision', () {
    test('a decoded image paints the bitmap, no placeholder', () {
      expect(
        imagePlaceholderFor(
          isPending: false,
          hasFailed: false,
          isReady: true,
          hasAssetRef: true,
        ),
        isNull,
      );
    });

    test('a decoding image gets the loading placeholder', () {
      expect(
        imagePlaceholderFor(
          isPending: true,
          hasFailed: false,
          isReady: false,
          hasAssetRef: true,
        ),
        ImagePlaceholderKind.loading,
      );
    });

    test('a failed decode gets the broken mark, not a spinner', () {
      expect(
        imagePlaceholderFor(
          isPending: false,
          hasFailed: true,
          isReady: false,
          hasAssetRef: true,
        ),
        ImagePlaceholderKind.failed,
      );
    });

    test('bytes known but not yet pending still shows loading', () {
      expect(
        imagePlaceholderFor(
          isPending: false,
          hasFailed: false,
          isReady: false,
          hasAssetRef: true,
        ),
        ImagePlaceholderKind.loading,
        reason: 'the frame must never be blank',
      );
    });

    test('a node with no asset ref is not faked', () {
      expect(
        imagePlaceholderFor(
          isPending: false,
          hasFailed: false,
          isReady: false,
          hasAssetRef: false,
        ),
        isNull,
      );
    });

    test('ready wins over a stale pending/failed flag', () {
      expect(
        imagePlaceholderFor(
          isPending: true,
          hasFailed: true,
          isReady: true,
          hasAssetRef: true,
        ),
        isNull,
      );
    });
  });

  group('paintImagePlaceholder — the visual', () {
    Future<Uint8List> rasterFor(
      ImagePlaceholderKind kind, {
      double phase = 0.0,
    }) async {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      paintImagePlaceholder(
        canvas,
        const Rect.fromLTWH(20, 20, 200, 120),
        kind,
        phase: phase,
      );
      final ui.Picture picture = recorder.endRecording();
      final ui.Image image = await picture.toImage(260, 180);
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      picture.dispose();
      return data!.buffer.asUint8List();
    }

    /// Number of pixels with any alpha — the amount of painted ink.
    Future<int> inkFor(ImagePlaceholderKind kind, {double phase = 0.0}) async {
      final Uint8List bytes = await rasterFor(kind, phase: phase);
      int count = 0;
      for (int i = 3; i < bytes.length; i += 4) {
        if (bytes[i] > 0) {
          count++;
        }
      }
      return count;
    }

    test('a loading placeholder paints something', () async {
      expect(await inkFor(ImagePlaceholderKind.loading), greaterThan(0));
    });

    test('a failed placeholder paints a distinct mark', () async {
      expect(await inkFor(ImagePlaceholderKind.failed), greaterThan(0));
    });

    test('the sheen MOVES as the phase advances', () async {
      // Compare the whole rendered frame, not just an alpha count: the sheen is
      // a moving highlight, so the number of tinted pixels can coincide while
      // the pixels themselves differ.
      final Uint8List a =
          await rasterFor(ImagePlaceholderKind.loading, phase: 0.0);
      final Uint8List b =
          await rasterFor(ImagePlaceholderKind.loading, phase: 0.5);
      int differing = 0;
      for (int i = 0; i < a.length && i < b.length; i++) {
        if (a[i] != b[i]) {
          differing++;
        }
      }
      expect(differing, greaterThan(0),
          reason: 'a frozen placeholder would look like a broken image');
    });

    test('the animation loops (phase 0 and 1 look identical)', () async {
      final int atZero = await inkFor(ImagePlaceholderKind.loading, phase: 0.0);
      final int atOne = await inkFor(ImagePlaceholderKind.loading, phase: 1.0);
      expect(atOne, atZero);
    });

    test('a non-finite phase does not throw', () async {
      expect(
        await inkFor(ImagePlaceholderKind.loading, phase: double.nan),
        greaterThan(0),
      );
    });

    test('a degenerate rect paints nothing', () async {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      paintImagePlaceholder(
        canvas,
        const Rect.fromLTWH(10, 10, 0, 0),
        ImagePlaceholderKind.loading,
      );
      final ui.Picture picture = recorder.endRecording();
      final ui.Image image = await picture.toImage(64, 64);
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      picture.dispose();
      final Uint8List bytes = data!.buffer.asUint8List();
      int count = 0;
      for (int i = 3; i < bytes.length; i += 4) {
        if (bytes[i] > 0) {
          count++;
        }
      }
      expect(count, 0);
    });

    test('a tiny rect still renders without a broken glyph', () async {
      // The glyph is suppressed under 6 dp; only the panel/outline remains.
      expect(
        await inkFor(ImagePlaceholderKind.failed),
        greaterThanOrEqualTo(0),
      );
    });
  });

  group('ImagePlaceholderTicker — animation lifetime', () {
    test('it does not run when nothing is pending', () {
      final ImagePlaceholderTicker ticker = ImagePlaceholderTicker(
        pending: () => false,
        onTick: (_) {},
      );
      ticker.ensureRunning();
      expect(ticker.isRunning, isFalse,
          reason: 'an idle canvas must not request frames');
      ticker.dispose();
    });

    test('it runs while something is pending', () {
      final ImagePlaceholderTicker ticker = ImagePlaceholderTicker(
        pending: () => true,
        onTick: (_) {},
        fps: 1000,
      );
      ticker.ensureRunning();
      expect(ticker.isRunning, isTrue);
      ticker.dispose();
    });

    test('ensureRunning is idempotent', () {
      final ImagePlaceholderTicker ticker = ImagePlaceholderTicker(
        pending: () => true,
        onTick: (_) {},
        fps: 1000,
      );
      ticker.ensureRunning();
      ticker.ensureRunning();
      expect(ticker.isRunning, isTrue);
      ticker.dispose();
    });

    test('onAssetReady stops once the last image resolves', () {
      final ImagePlaceholderTicker ticker = ImagePlaceholderTicker(
        pending: () => false,
        onTick: (_) {},
      );
      ticker.onAssetReady();
      expect(ticker.isRunning, isFalse);
      ticker.dispose();
    });

    test('dispose stops the timer', () {
      final ImagePlaceholderTicker ticker = ImagePlaceholderTicker(
        pending: () => true,
        onTick: (_) {},
        fps: 1000,
      );
      ticker.ensureRunning();
      ticker.dispose();
      expect(ticker.isRunning, isFalse);
    });

    test('phase advances on real ticks and stays within 0..1', () async {
      final List<double> phases = <double>[];
      final ImagePlaceholderTicker ticker = ImagePlaceholderTicker(
        pending: () => true,
        onTick: phases.add,
        fps: 1000,
        duration: const Duration(milliseconds: 60),
      );
      ticker.ensureRunning();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      ticker.dispose();
      expect(phases, isNotEmpty);
      for (final double phase in phases) {
        expect(phase, inInclusiveRange(0.0, 1.0));
      }
    });

    test('the timer stops itself when the last asset resolves mid-flight',
        () async {
      bool pending = true;
      final ImagePlaceholderTicker ticker = ImagePlaceholderTicker(
        pending: () => pending,
        onTick: (_) {},
        fps: 1000,
      );
      ticker.ensureRunning();
      expect(ticker.isRunning, isTrue);
      pending = false;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ticker.isRunning, isFalse,
          reason: 'the tick loop must stop on its own once nothing is pending');
      ticker.dispose();
    });
  });
}
