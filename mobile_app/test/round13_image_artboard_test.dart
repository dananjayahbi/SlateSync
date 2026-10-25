/// Round-13 issue 03 — a gallery image used as a canvas is sized to the image.
///
/// The gallery marks such a document with a preset name outside the frozen
/// table (`IMAGE`) and carries the real device-pixel dimensions. `ArtboardManager`
/// used to resolve dimensions from the preset table and throw on anything
/// outside it, so opening one of those canvases crashed the studio before the
/// first frame. These tests pin both halves: marker presets adopt the
/// document's own dims, and the Doc 23 upgrade matrix is untouched.
library;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/canvas_engine/artboard_manager.dart';
import 'package:mobile_app/core/models/canvas_models.dart';Artboard _artboard({
  required String preset,
  double? width,
  double? height,
  bool infinite = false,
}) =>
    Artboard(
      preset: preset,
      width: width,
      height: height,
      isInfinite: infinite,
      backgroundStyle: 'BLANK',
      backgroundColor: '#FFFFFF',
    );

void main() {
  group('ArtboardManager.forDocument', () {
    test('a marker preset adopts the document dims instead of throwing', () {
      final ArtboardManager m = ArtboardManager.forDocument(
        _artboard(preset: 'IMAGE', width: 1080, height: 1920),
      );
      expect(m.current.preset, 'IMAGE');
      expect(m.current.width, 1080.0);
      expect(m.current.height, 1920.0);
      expect(m.isInfinite, isFalse);
      expect(m.boundaryRect(), const Rect.fromLTWH(0, 0, 1080, 1920));
    });

    test('a marker preset keeps its non-standard dimensions exactly', () {
      // A gallery image is a device-pixel rectangle; rounding it to a paper
      // size would letterbox or crop the picture the user chose.
      final ArtboardManager m = ArtboardManager.forDocument(
        _artboard(preset: 'IMAGE', width: 4032, height: 3024),
      );
      expect(m.current.width, 4032.0);
      expect(m.current.height, 3024.0);
    });

    test('a marker preset without usable dims still fails loudly', () {
      expect(
        () => ArtboardManager.forDocument(_artboard(preset: 'IMAGE')),
        throwsArgumentError,
      );
      expect(
        () => ArtboardManager.forDocument(
          _artboard(preset: 'IMAGE', width: 0, height: 0),
        ),
        throwsArgumentError,
      );
    });

    test('known presets still come from the table', () {
      // The document dims are deliberately wrong here: the table is normative
      // for real presets, so they must win.
      final ArtboardManager a4 = ArtboardManager.forDocument(
        _artboard(preset: 'A4', width: 10, height: 10),
      );
      expect(a4.current.width, 2480.0);
      expect(a4.current.height, 3508.0);

      final ArtboardManager book = ArtboardManager.forDocument(
        _artboard(preset: 'BOOK', width: 10, height: 10),
      );
      expect(book.current.width, Presets.book.w);
      expect(book.current.height, Presets.book.h);
    });

    test('INFINITE keeps null dims and no boundary', () {
      final ArtboardManager m = ArtboardManager.forDocument(
        _artboard(preset: 'INFINITE', infinite: true),
      );
      expect(m.isInfinite, isTrue);
      expect(m.current.width, isNull);
      expect(m.boundaryRect(), isNull);
    });

    test('the document background is carried over', () {
      final ArtboardManager m = ArtboardManager.forDocument(
        Artboard(
          preset: 'IMAGE',
          width: 800,
          height: 600,
          isInfinite: false,
          backgroundStyle: 'RULED',
          backgroundColor: '#000000',
          backgroundSpacing: 64,
        ),
      );
      expect(m.current.backgroundStyle, 'RULED');
      expect(m.current.backgroundColor, '#000000');
      expect(m.current.backgroundSpacing, 64.0);
    });
  });

  group('the Doc 23 upgrade matrix is unchanged', () {
    test('a marker canvas can still be upgraded to a paper size', () {
      final ArtboardManager m = ArtboardManager.forDocument(
        _artboard(preset: 'IMAGE', width: 400, height: 300),
      );
      m.noteContent(const Rect.fromLTWH(0, 0, 400, 300));
      final UpgradeResult r = m.tryUpgrade('A4');
      expect(r.allowed, isTrue);
      expect(m.current.preset, 'A4');
      expect(m.boundaryRect(), const Rect.fromLTWH(0, 0, 2480, 3508));
    });

    test('content larger than the target is still refused', () {
      final ArtboardManager m = ArtboardManager.forDocument(
        _artboard(preset: 'IMAGE', width: 9000, height: 9000),
      );
      m.noteContent(const Rect.fromLTWH(0, 0, 9000, 9000));
      final UpgradeResult r = m.tryUpgrade('A4');
      expect(r.allowed, isFalse);
      expect(r.reasonKey, ReasonKeys.clipsContent);
      expect(m.current.preset, 'IMAGE');
    });

    test('unknown upgrade targets are still invalid_target', () {
      final ArtboardManager m = ArtboardManager.forDocument(
        _artboard(preset: 'IMAGE', width: 400, height: 300),
      );
      expect(m.tryUpgrade('IMAGE').reasonKey, ReasonKeys.invalidTarget);
    });
  });
}
