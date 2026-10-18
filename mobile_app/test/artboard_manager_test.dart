import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/canvas_engine/artboard_manager.dart';

/// Doc 23 §6 upgrade matrix: every row runs as an independent case, plus
/// reasonKey assertions, `boundaryRect` ⇔ INFINITE, union monotonicity,
/// `resetContent`, and the non-destructive guarantee (failures mutate
/// nothing; success never rewrites `content_bounds`).
void main() {
  ArtboardManager seeded(String preset, Rect? content) {
    final ArtboardManager m = ArtboardManager(preset: preset);
    if (content != null) {
      m.noteContent(content);
    }
    return m;
  }

  group('construction & boundaryRect()', () {
    test('A5 seeds preset dims at top-left origin', () {
      final ArtboardManager m = ArtboardManager(preset: 'A5');
      expect(m.current.preset, 'A5');
      expect(m.current.width, 1748.0);
      expect(m.current.height, 2480.0);
      expect(m.isInfinite, isFalse);
      expect(m.boundaryRect(), const Rect.fromLTWH(0, 0, 1748, 2480));
      expect(m.contentBounds, Rect.zero);
    });

    test('INFINITE seeds null dims and null boundary', () {
      final ArtboardManager m = ArtboardManager(preset: 'INFINITE');
      expect(m.current.width, isNull);
      expect(m.current.height, isNull);
      expect(m.isInfinite, isTrue);
      expect(m.boundaryRect(), isNull);
    });

    test('LETTER and A4 seed their matrix dims', () {
      expect(ArtboardManager(preset: 'LETTER').boundaryRect(),
          const Rect.fromLTWH(0, 0, 2550, 3300));
      expect(ArtboardManager(preset: 'A4').boundaryRect(),
          const Rect.fromLTWH(0, 0, 2480, 3508));
    });

    test('unknown construction preset throws ArgumentError', () {
      expect(() => ArtboardManager(preset: 'A3'), throwsArgumentError);
    });
  });

  group('noteContent / resetContent union tracking', () {
    test('first call adopts, later calls expand monotonically', () {
      final ArtboardManager m = ArtboardManager(preset: 'A4');
      m.noteContent(const Rect.fromLTWH(100, 100, 100, 100));
      expect(m.contentBounds, const Rect.fromLTWH(100, 100, 100, 100));
      m.noteContent(const Rect.fromLTWH(0, 0, 50, 50));
      expect(m.contentBounds, const Rect.fromLTWH(0, 0, 200, 200));
      m.noteContent(const Rect.fromLTWH(150, 150, 400, 500));
      expect(m.contentBounds, const Rect.fromLTWH(0, 0, 550, 650));
      // never narrows
      m.noteContent(const Rect.fromLTWH(300, 300, 10, 10));
      expect(m.contentBounds, const Rect.fromLTWH(0, 0, 550, 650));
    });

    test('non-finite rects are ignored (stay empty)', () {
      final ArtboardManager m = ArtboardManager(preset: 'A4');
      m.noteContent(Rect.fromLTRB(0, 0, double.infinity, 100));
      expect(m.contentBounds, Rect.zero);
      expect(m.tryUpgrade('A5').allowed, isTrue); // still empty ⇒ any target
    });

    test('resetContent clears back to empty ⇒ any target allowed', () {
      final ArtboardManager m = seeded(
          'A4', const Rect.fromLTWH(0, 0, 3000, 4000));
      expect(m.tryUpgrade('A5').allowed, isFalse);
      m.resetContent();
      expect(m.contentBounds, Rect.zero);
      expect(m.tryUpgrade('A5').allowed, isTrue);
      // Re-noting the same out-of-bounds content blocks the next downgrade.
      m.noteContent(const Rect.fromLTWH(0, 0, 3000, 4000));
      expect(m.tryUpgrade('A5').allowed, isFalse);
      expect(m.tryUpgrade('INFINITE').allowed, isTrue);
    });
  });

  group('tryUpgrade matrix (§4.4 verbatim)', () {
    test('row 1: A5 content fitting A5 → A4 allowed', () {
      final ArtboardManager m =
          seeded('A5', const Rect.fromLTWH(0, 0, 1700, 2400));
      final UpgradeResult r = m.tryUpgrade('A4');
      expect(r.allowed, isTrue);
      expect(r.reasonKey, isNull);
      expect(m.current.preset, 'A4');
      expect(m.current.width, 2480.0);
      expect(m.current.height, 3508.0);
      expect(m.boundaryRect(), const Rect.fromLTWH(0, 0, 2480, 3508));
    });

    test('row 2: A4 content (0,0,3000,2400) → A5 refused clips_content', () {
      final ArtboardManager m =
          seeded('A4', const Rect.fromLTWH(0, 0, 3000, 2400));
      final UpgradeResult r = m.tryUpgrade('A5');
      expect(r.allowed, isFalse);
      expect(r.reasonKey, ReasonKeys.clipsContent);
      // failure mutates nothing
      expect(m.current.preset, 'A4');
      expect(m.contentBounds, const Rect.fromLTWH(0, 0, 3000, 2400));
      expect(m.boundaryRect(), const Rect.fromLTWH(0, 0, 2480, 3508));
    });

    test('row 3: A5 fitting content → INFINITE allowed, null dims', () {
      final ArtboardManager m =
          seeded('A5', const Rect.fromLTWH(10, 10, 100, 100));
      final UpgradeResult r = m.tryUpgrade('INFINITE');
      expect(r.allowed, isTrue);
      expect(r.reasonKey, isNull);
      expect(m.current.width, isNull);
      expect(m.current.height, isNull);
      expect(m.isInfinite, isTrue);
      expect(m.boundaryRect(), isNull);
      expect(m.contentBounds, const Rect.fromLTWH(10, 10, 100, 100));
    });

    test('row 4: INFINITE content (0,0,9000,9000) → A4 refused', () {
      final ArtboardManager m =
          seeded('INFINITE', const Rect.fromLTWH(0, 0, 9000, 9000));
      final UpgradeResult r = m.tryUpgrade('A4');
      expect(r.allowed, isFalse);
      expect(r.reasonKey, ReasonKeys.clipsContent);
      expect(m.isInfinite, isTrue); // state untouched
      expect(m.boundaryRect(), isNull);
    });

    test('row 5: INFINITE content (10,10,2000,3000) → A4 allowed', () {
      final ArtboardManager m =
          seeded('INFINITE', const Rect.fromLTWH(10, 10, 2000, 3000));
      final UpgradeResult r = m.tryUpgrade('A4');
      expect(r.allowed, isTrue);
      expect(r.reasonKey, isNull);
      expect(m.current.preset, 'A4');
      expect(m.current.width, 2480.0);
      expect(m.current.height, 3508.0);
      // non-destructive: content_bounds untouched by the upgrade
      expect(m.contentBounds, const Rect.fromLTWH(10, 10, 2000, 3000));
    });

    test('row 6: empty document → any target allowed', () {
      for (final String target in <String>['A5', 'A4', 'LETTER', 'INFINITE']) {
        final ArtboardManager m = ArtboardManager(preset: 'A5');
        final UpgradeResult r = m.tryUpgrade(target);
        expect(r.allowed, isTrue, reason: 'empty doc → $target');
        expect(r.reasonKey, isNull);
      }
    });

    test('row 7: LETTER content at Letter edge → A4 refused (2550 > 2480)',
        () {
      final ArtboardManager m =
          seeded('LETTER', const Rect.fromLTWH(0, 0, 2550, 3300));
      final UpgradeResult r = m.tryUpgrade('A4');
      expect(r.allowed, isFalse);
      expect(r.reasonKey, ReasonKeys.clipsContent);
      expect(m.current.preset, 'LETTER');
    });

    test('row 8: edge equality passes (max_x == 2480, max_y == 3508)', () {
      final ArtboardManager m =
          seeded('A4', const Rect.fromLTWH(0, 0, 2480, 3508));
      final UpgradeResult r = m.tryUpgrade('A4');
      expect(r.allowed, isTrue);
      expect(r.reasonKey, isNull);
      // negative min fails even when max fits
      final ArtboardManager neg =
          seeded('INFINITE', const Rect.fromLTWH(-1, 0, 100, 100));
      expect(neg.tryUpgrade('A4').reasonKey, ReasonKeys.clipsContent);
    });

    test('unknown target → invalid_target, checked before emptiness', () {
      final ArtboardManager empty = ArtboardManager(preset: 'A5');
      final UpgradeResult r = empty.tryUpgrade('a4');
      expect(r.allowed, isFalse);
      expect(r.reasonKey, ReasonKeys.invalidTarget);
      expect(empty.tryUpgrade('').reasonKey, ReasonKeys.invalidTarget);
      final ArtboardManager seededM = seeded(
          'A5', const Rect.fromLTWH(0, 0, 100, 100));
      expect(seededM.tryUpgrade('A3X').reasonKey, ReasonKeys.invalidTarget);
      // state untouched by invalid attempts
      expect(seededM.current.preset, 'A5');
    });

    test('success preserves backgroundStyle/backgroundColor', () {
      final ArtboardManager m = ArtboardManager(preset: 'A5');
      m.current.backgroundStyle = 'RULED';
      m.current.backgroundColor = '#EEEDED';
      m.noteContent(const Rect.fromLTWH(0, 0, 100, 100));
      expect(m.tryUpgrade('A4').allowed, isTrue);
      expect(m.current.backgroundStyle, 'RULED');
      expect(m.current.backgroundColor, '#EEEDED');
      expect(m.tryUpgrade('INFINITE').allowed, isTrue);
      expect(m.current.backgroundStyle, 'RULED');
      expect(m.current.backgroundColor, '#EEEDED');
    });

    test('reasonKeys are exactly the two frozen strings', () {
      expect(ReasonKeys.clipsContent, 'clips_content');
      expect(ReasonKeys.invalidTarget, 'invalid_target');
      final ArtboardManager m =
          seeded('A4', const Rect.fromLTWH(0, 0, 3000, 2400));
      final UpgradeResult r = m.tryUpgrade('A5');
      expect(r.reasonKey, 'clips_content');
      expect(m.tryUpgrade('NOPE').reasonKey, 'invalid_target');
      expect(m.tryUpgrade('INFINITE').reasonKey, isNull);
    });
  });
}
