import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kTouchSlop;
import 'package:flutter/material.dart';

/// Reveals block actions on pointer hover, or on tap for touch devices.
///
/// Desktop platforms have a real hover state, so actions fade in while the
/// pointer is anywhere inside the wrapped block and fade out when it leaves.
/// Touch devices have no hover state; the equivalent is a single tap that
/// reveals the actions for [autoHideAfter] and then dismisses them again. A
/// connected mouse or trackpad still takes the hover path because pointer
/// events keep their [PointerDeviceKind]. Tapping anywhere outside the block
/// also dismisses a touch reveal immediately.
///
/// Note that [MediaQueryData.accessibleNavigation] must not force the actions
/// open: Android reports it as soon as *any* accessibility service is running
/// (screen readers, select-to-speak, password managers, gesture helpers, ...),
/// which would leave every block toolbar permanently visible for users who are
/// not using a screen reader at all.
class HoverReveal extends StatefulWidget {
  const HoverReveal({
    super.key,
    required this.child,
    this.autoHideAfter = const Duration(seconds: 3),
  });

  final Widget child;

  /// How long a touch reveal stays visible without another tap.
  final Duration autoHideAfter;

  @override
  State<HoverReveal> createState() => _HoverRevealState();
}

class _HoverRevealState extends State<HoverReveal> {
  bool _hovered = false;
  bool _touchRevealed = false;
  Timer? _autoHideTimer;
  int? _tapPointer;
  Offset? _tapDownPosition;

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    super.dispose();
  }

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  void _handlePointerDown(PointerDownEvent event) {
    // Mouse hover is handled by MouseRegion; only touch/pen need tap reveal.
    if (event.kind == PointerDeviceKind.mouse) return;
    _tapPointer = event.pointer;
    _tapDownPosition = event.position;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _tapPointer) return;
    final down = _tapDownPosition;
    if (down == null) return;
    if ((event.position - down).distance > kTouchSlop) {
      // A scroll/drag, not a tap; do not flash the actions.
      _tapDownPosition = null;
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _tapPointer) return;
    final down = _tapDownPosition;
    _tapPointer = null;
    _tapDownPosition = null;
    if (down == null) return;
    if ((event.position - down).distance > kTouchSlop) return;
    _revealForTouch();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer != _tapPointer) return;
    _tapPointer = null;
    _tapDownPosition = null;
  }

  /// Dismisses a touch reveal when the user taps outside the block.
  ///
  /// Hover is left alone: an outside click on desktop does not mean the
  /// pointer left the block, and `MouseRegion` already handles that.
  void _hideForOutsideTap() {
    if (!_touchRevealed) return;
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
    setState(() => _touchRevealed = false);
  }

  void _revealForTouch() {
    _autoHideTimer?.cancel();
    if (!_touchRevealed) {
      setState(() => _touchRevealed = true);
    }
    _autoHideTimer = Timer(widget.autoHideAfter, () {
      if (!mounted) return;
      setState(() => _touchRevealed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final revealed = _hovered || _touchRevealed;
    return TapRegion(
      onTapOutside: (_) => _hideForOutsideTap(),
      child: MouseRegion(
        onEnter: (_) => _setHovered(true),
        onExit: (_) => _setHovered(false),
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _handlePointerDown,
          onPointerMove: _handlePointerMove,
          onPointerUp: _handlePointerUp,
          onPointerCancel: _handlePointerCancel,
          child: HoverRevealScope(revealed: revealed, child: widget.child),
        ),
      ),
    );
  }
}

/// Shares the current [HoverReveal] state with [RevealableActions] descendants.
class HoverRevealScope extends InheritedWidget {
  const HoverRevealScope({
    super.key,
    required this.revealed,
    required super.child,
  });

  final bool revealed;

  /// Returns `true` when there is no [HoverReveal] ancestor so widgets used
  /// outside a hover container keep their previous always-visible behaviour.
  static bool of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<HoverRevealScope>();
    return scope?.revealed ?? true;
  }

  @override
  bool updateShouldNotify(HoverRevealScope oldWidget) =>
      oldWidget.revealed != revealed;
}

/// Keeps block actions in the layout but hides them until they are revealed.
///
/// Size is reserved (opacity/ignore-pointer instead of removing the widget)
/// so revealing the actions never reflows the block or the surrounding chat.
/// Keyboard focus landing on one of the wrapped actions also reveals them;
/// the tracking is intentionally scoped to this subtree so text selection
/// focus inside the block body does not pin the actions open.
class RevealableActions extends StatefulWidget {
  const RevealableActions({
    super.key,
    required this.child,
    this.visible,
    this.duration = const Duration(milliseconds: 140),
  });

  final Widget child;

  /// Overrides the surrounding [HoverReveal]; `null` follows its state.
  final bool? visible;

  final Duration duration;

  @override
  State<RevealableActions> createState() => _RevealableActionsState();
}

class _RevealableActionsState extends State<RevealableActions> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final revealed =
        widget.visible ?? (HoverRevealScope.of(context) || _focused);
    // A screen reader cannot hover or tap to reveal the toolbar, so keep the
    // buttons in the semantics tree while they are visually hidden. They stay
    // activatable through their semantic actions (and keep the pre-hover
    // behaviour of this toolbar for accessibility users), while sighted users
    // still get the tap/hover reveal.
    final accessibleNavigation =
        MediaQuery.maybeOf(context)?.accessibleNavigation ?? false;
    return Focus(
      // The actions' container is not a tab stop itself, but focus moving
      // onto one of the buttons must reveal it.
      canRequestFocus: false,
      onFocusChange: (hasFocus) {
        if (_focused == hasFocus) return;
        setState(() => _focused = hasFocus);
      },
      child: IgnorePointer(
        ignoring: !revealed,
        child: ExcludeSemantics(
          excluding: !revealed && !accessibleNavigation,
          child: AnimatedOpacity(
            opacity: revealed ? 1 : 0,
            duration: widget.duration,
            curve: Curves.easeOut,
            // Opacity 0 otherwise drops the subtree from the semantics tree,
            // which would hide the actions from screen readers. Visibility is
            // controlled by the ExcludeSemantics above instead.
            alwaysIncludeSemantics: true,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
