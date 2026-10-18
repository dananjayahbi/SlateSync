/// Doc 23 — Artboard Bounds Upgrader.
///
/// Unifies infinite and bounded canvases: renders A5/A4/Letter boundaries
/// (`null` ⇒ infinite), tracks `content_bounds` by incremental union, and
/// enforces the overview §4.4 non-destructive upgrade rule through
/// [tryUpgrade] returning a frozen [UpgradeResult] `{allowed, reasonKey}`.
/// Never silently downsizes — consumers render the warning overlay from
/// `reasonKey`; Doc 22 painters read [boundaryRect] for page edges.
library;

import 'dart:ui';

import 'package:mobile_app/core/models/canvas_models.dart'; // Doc 05

/// Frozen upgrade reason keys (Doc 23 §4 / template §5): exactly two strings
/// plus `null` on success — no other key ever exists in this module.
class ReasonKeys {
  ReasonKeys._();

  /// Content would be cropped by the smaller target preset.
  static const String clipsContent = 'clips_content';

  /// Target preset string is not one of A5/A4/LETTER/INFINITE.
  static const String invalidTarget = 'invalid_target';
}

/// Frozen `tryUpgrade` result (template §5, Doc 23 §4).
class UpgradeResult {
  const UpgradeResult(this.allowed, this.reasonKey);

  final bool allowed;

  /// `null` on success; otherwise one of [ReasonKeys].
  final String? reasonKey;
}

/// Artboard boundary + `content_bounds` union tracker (Doc 23).
class ArtboardManager {
  ArtboardManager({required String preset}) : _current = _initialFor(preset);

  /// Valid upgrade targets (template §3 preset matrix, verbatim).
  static const Set<String> _validTargets = {'A5', 'A4', 'LETTER', 'INFINITE'};

  Artboard _current;

  /// `null` ⇒ nothing noted yet (empty document).
  Rect? _content;

  /// Current artboard; replaced only by a successful [tryUpgrade].
  Artboard get current => _current;

  /// Tracked content bounds; [Rect.zero] while nothing has been noted.
  Rect get contentBounds => _content ?? Rect.zero;

  bool get isInfinite => _current.isInfinite;

  /// Incremental union into the tracked content rect (first call adopts `r`).
  /// Called by painters and Doc 24/26 on every commit; non-finite rects are
  /// ignored. The tracked rect only ever expands here or clears via
  /// [resetContent] — no path in this module narrows it.
  void noteContent(Rect r) {
    if (!r.isFinite) {
      return;
    }
    _content = _content == null ? r : _content!.expandToInclude(r);
  }

  /// Clear-all path (Doc 24/26 erase-all): the document counts as empty again
  /// for the next [tryUpgrade].
  void resetContent() {
    _content = null;
  }

  /// Page rectangle at top-left origin `(0,0)→(w,h)` (template §3);
  /// `null` exactly when the current artboard is INFINITE.
  Rect? boundaryRect() {
    final double? w = _current.width;
    final double? h = _current.height;
    if (_current.isInfinite || w == null || h == null) {
      return null;
    }
    return Rect.fromLTWH(0, 0, w, h);
  }

  /// Overview §4.4 rule (template §3, verbatim precedence):
  /// 1. unknown target ⇒ `invalid_target` (validated before consulting
  ///    content); 2. empty document ⇒ allowed for any target; 3. `INFINITE`
  /// ⇒ always allowed; 4. otherwise allow iff `min_x >= 0 && min_y >= 0 &&
  /// max_x <= w && max_y <= h` with edge equality passing, else
  /// `clips_content`. Every success swaps `current` for a fresh [Artboard]
  /// (dims from [Presets] or null for INFINITE, background fields
  /// preserved); failures mutate nothing.
  UpgradeResult tryUpgrade(String targetPreset) {
    if (!_validTargets.contains(targetPreset)) {
      return const UpgradeResult(false, ReasonKeys.invalidTarget);
    }
    final bool empty = _content == null;
    if (!empty && targetPreset != 'INFINITE') {
      final (w: double tw, h: double th) = _dimsFor(targetPreset)!;
      final Rect c = _content!;
      final bool fits =
          c.left >= 0 && c.top >= 0 && c.right <= tw && c.bottom <= th;
      if (!fits) {
        return const UpgradeResult(false, ReasonKeys.clipsContent);
      }
    }
    if (targetPreset == 'INFINITE') {
      _current = Artboard(
        preset: 'INFINITE',
        width: null,
        height: null,
        isInfinite: true,
        backgroundStyle: _current.backgroundStyle,
        backgroundColor: _current.backgroundColor,
      );
    } else {
      final (w: double tw, h: double th) = _dimsFor(targetPreset)!;
      _current = Artboard(
        preset: targetPreset,
        width: tw,
        height: th,
        isInfinite: false,
        backgroundStyle: _current.backgroundStyle,
        backgroundColor: _current.backgroundColor,
      );
    }
    return const UpgradeResult(true, null);
  }

  /// Preset dimension table (template §3, 300-DPI world units); `null` for
  /// anything outside the three bounded presets. (`Presets.a5` is a named
  /// record while `a4`/`letter` are positional — normalized to named here.)
  static ({double w, double h})? _dimsFor(String preset) => switch (preset) {
        'A5' => (w: Presets.a5.w, h: Presets.a5.h),
        'A4' => (w: Presets.a4.$1, h: Presets.a4.$2),
        'LETTER' => (w: Presets.letter.$1, h: Presets.letter.$2),
        _ => null,
      };

  static Artboard _initialFor(String preset) {
    if (preset == 'INFINITE') {
      return Artboard.infinite();
    }
    final (w: double w, h: double h) = _dimsFor(preset) ??
        (throw ArgumentError.value(
          preset,
          'preset',
          'Unknown artboard preset (expected A5, A4, LETTER or INFINITE)',
        ));
    return Artboard(
      preset: preset,
      width: w,
      height: h,
      isInfinite: false,
      backgroundStyle: 'BLANK',
      backgroundColor: '#FFFFFF',
    );
  }
}
