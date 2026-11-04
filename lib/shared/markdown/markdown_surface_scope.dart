import 'package:flutter/material.dart';

/// Soft scrim for a bare assistant message painted over a chat wallpaper.
///
/// The alpha is deliberately high enough that [ColorScheme.onSurface] keeps
/// its contrast over bright/dark wallpapers; the text shadow remains as a
/// secondary safety net. Table/code/details surfaces stay fully opaque.
Color assistantWallpaperScrimColor(ColorScheme cs, {double maskStrength = 0}) {
  final base = cs.brightness == Brightness.dark ? 0.88 : 0.84;
  // The wallpaper mask already darkens/tints the backdrop; avoid stacking a
  // full-strength scrim on top of an almost-opaque user mask.
  final alpha = (base - 0.08 * maskStrength.clamp(0.0, 1.0)).clamp(0.0, 1.0);
  return cs.surface.withValues(alpha: alpha);
}

/// Paired surface/ink values for Markdown blocks.
///
/// The scope exists so Markdown widgets do not have to guess which background
/// they are painted on (solid bubble, frosted bubble, or bare over a chat
/// wallpaper). It also gives the future modern pipeline a single place to read
/// colors from (plan §3.10 / §4.4).
@immutable
class MarkdownSurface {
  const MarkdownSurface({
    required this.surface,
    required this.onSurface,
    required this.onSurfaceVariant,
    this.isTranslucent = false,
    this.hasWallpaper = false,
  });

  factory MarkdownSurface.fromColorScheme(ColorScheme cs) {
    return MarkdownSurface(
      surface: cs.surface,
      onSurface: cs.onSurface,
      onSurfaceVariant: cs.onSurfaceVariant,
    );
  }

  /// Opaque surface used by block elements (tables, code, details).
  final Color surface;

  /// Paired ink for body text and block content.
  final Color onSurface;

  /// Paired ink for secondary text.
  final Color onSurfaceVariant;

  /// True when the text is painted over a translucent bubble (frosted) or a
  /// bare chat background, where the theme's [onSurface] alone cannot
  /// guarantee contrast.
  final bool isTranslucent;

  /// True when the assistant has a chat background image behind the message.
  final bool hasWallpaper;

  bool get wantsBodyTextShadow => isTranslucent || hasWallpaper;

  /// Subtle, background-agnostic shadow that keeps body text legible over
  /// busy wallpapers without changing the ink color itself.
  List<Shadow> get bodyTextShadows => wantsBodyTextShadow
      ? const <Shadow>[
          Shadow(
            color: Color(0x33000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ]
      : const <Shadow>[];

  MarkdownSurface copyWith({
    Color? surface,
    Color? onSurface,
    Color? onSurfaceVariant,
    bool? isTranslucent,
    bool? hasWallpaper,
  }) {
    return MarkdownSurface(
      surface: surface ?? this.surface,
      onSurface: onSurface ?? this.onSurface,
      onSurfaceVariant: onSurfaceVariant ?? this.onSurfaceVariant,
      isTranslucent: isTranslucent ?? this.isTranslucent,
      hasWallpaper: hasWallpaper ?? this.hasWallpaper,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MarkdownSurface &&
        other.surface == surface &&
        other.onSurface == onSurface &&
        other.onSurfaceVariant == onSurfaceVariant &&
        other.isTranslucent == isTranslucent &&
        other.hasWallpaper == hasWallpaper;
  }

  @override
  int get hashCode => Object.hash(
        surface,
        onSurface,
        onSurfaceVariant,
        isTranslucent,
        hasWallpaper,
      );
}

/// Provides a [MarkdownSurface] to descendant Markdown renderers.
class MarkdownSurfaceScope extends InheritedWidget {
  const MarkdownSurfaceScope({
    super.key,
    required this.surface,
    required super.child,
  });

  final MarkdownSurface surface;

  static MarkdownSurface? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<MarkdownSurfaceScope>()
        ?.surface;
  }

  static MarkdownSurface of(BuildContext context) {
    return maybeOf(context) ??
        MarkdownSurface.fromColorScheme(Theme.of(context).colorScheme);
  }

  @override
  bool updateShouldNotify(MarkdownSurfaceScope oldWidget) {
    return oldWidget.surface != surface;
  }
}
