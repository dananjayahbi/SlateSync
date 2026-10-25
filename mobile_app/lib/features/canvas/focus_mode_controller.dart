/// Round-12 issue 03 — focus mode.
///
/// Focus mode hides everything on the canvas screen except the canvas itself
/// and one button to come back. It exists for continuous note-taking: every
/// other control is a target you can hit by accident with a palm resting on a
/// tablet, and the chrome steals vertical space you want for writing.
///
/// Two deliberate choices:
///
/// * **Not persisted.** Focus mode is a momentary state of looking at the page,
///   not a preference. Reopening an app into a "where did everything go?"
///   screen is worse than re-entering focus mode by hand.
/// * **Pure state, no widgets.** Keeping the controller free of Flutter widgets
///   means the interaction rules (which panels must never hide, what happens on
///   a mid-focus tool change) are unit-testable without a pump.
library;

import 'package:flutter/foundation.dart';

/// What the page must keep visible while focus mode is on.
///
/// A bare `bool` would force every call site to re-derive these rules, and they
/// are exactly the rules that produce "I can't get out of focus mode" bugs.
@immutable
class FocusChrome {
  const FocusChrome({
    required this.showTopBar,
    required this.showToolDock,
    required this.showBanner,
    required this.showHint,
    required this.showFocusButton,
  });

  /// Chrome for normal editing.
  static const FocusChrome normal = FocusChrome(
    showTopBar: true,
    showToolDock: true,
    showBanner: true,
    showHint: true,
    showFocusButton: true,
  );

  /// Chrome while focused: only the way out survives.
  static const FocusChrome focused = FocusChrome(
    showTopBar: false,
    showToolDock: false,
    showBanner: false,
    showHint: false,
    showFocusButton: true,
  );

  final bool showTopBar;
  final bool showToolDock;
  final bool showBanner;
  final bool showHint;
  final bool showFocusButton;

  @override
  bool operator ==(Object other) =>
      other is FocusChrome &&
      other.showTopBar == showTopBar &&
      other.showToolDock == showToolDock &&
      other.showBanner == showBanner &&
      other.showHint == showHint &&
      other.showFocusButton == showFocusButton;

  @override
  int get hashCode =>
      Object.hash(showTopBar, showToolDock, showBanner, showHint, showFocusButton);

  @override
  String toString() =>
      'FocusChrome(topBar: $showTopBar, dock: $showToolDock, '
      'banner: $showBanner, hint: $showHint, button: $showFocusButton)';
}

/// Owns the focus-mode flag and derives the resulting chrome.
class FocusModeController extends ChangeNotifier {
  FocusModeController({bool focused = false}) {
    _focused = focused;
  }

  bool _focused = false;
  bool _disposed = false;

  bool get isFocused => _focused;

  /// Chrome that should currently be rendered.
  FocusChrome get chrome => _focused ? FocusChrome.focused : FocusChrome.normal;

  /// Flips the mode and notifies. Returns the new state.
  bool toggle() => setFocused(!_focused);

  /// Sets the mode, notifying only on an actual change.
  bool setFocused(bool value) {
    if (_focused == value) {
      return _focused;
    }
    _focused = value;
    if (!_disposed) {
      notifyListeners();
    }
    return _focused;
  }

  /// Leaves focus mode. Safe to call when already unfocused.
  void exit() {
    setFocused(false);
  }

  /// Enters focus mode. Safe to call when already focused.
  void enter() {
    setFocused(true);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
