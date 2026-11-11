// Context usage ring + menu/sheet header (docs/context_usage_ring_plan.md v2).
//
// The ring mirrors AnyBuff's Composer TokenRing: 12 o'clock start, round
// caps, three color bands (primary / amber at 70% / error at 90%) and a
// pulsing fade while a response is streaming. Stateful on purpose — frequent
// ChatInputBar rebuilds must never restart the value animation from zero.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../theme/app_font_weights.dart';
import '../services/context_usage_service.dart';

/// Color bands: < 70% primary, 70–89% warning amber, >= 90% error red.
/// Top-level so the thresholds are testable without pumping the widget.
Color contextUsageColorForRatio(BuildContext context, double ratio) {
  final cs = Theme.of(context).colorScheme;
  if (ratio >= 0.90) return cs.error;
  if (ratio >= 0.70) return Colors.orange.shade600;
  return cs.primary;
}

/// Circular usage indicator. [ratio] must already be clamped 0..1
/// ([ContextUsageSnapshot.ratio]).
class ContextUsageRing extends StatefulWidget {
  const ContextUsageRing({
    super.key,
    required this.ratio,
    this.size = 20,
    this.strokeWidth = 2.6,
    this.running = false,
    this.trackColor,
  });

  final double ratio;
  final double size;
  final double strokeWidth;

  /// Pulsing fade while a response is streaming.
  final bool running;

  /// Track color; defaults to onSurface @ 10%.
  final Color? trackColor;

  @override
  State<ContextUsageRing> createState() => _ContextUsageRingState();
}

class _ContextUsageRingState extends State<ContextUsageRing>
    with TickerProviderStateMixin {
  static const Duration _valueDuration = Duration(milliseconds: 250);

  late final AnimationController _value;
  late final AnimationController _pulse;
  late final Animation<double> _pulseOpacity;
  Animation<double>? _ratioAnim;
  late double _displayedRatio;

  @override
  void initState() {
    super.initState();
    _displayedRatio = widget.ratio.clamp(0.0, 1.0).toDouble();
    _value = AnimationController(vsync: this, duration: _valueDuration);
    _value.addListener(_onValueChanged);
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _pulseOpacity = Tween<double>(begin: 1.0, end: 0.55).animate(_pulse);
    if (widget.running) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant ContextUsageRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.running != oldWidget.running) {
      if (widget.running) {
        _pulse.repeat(reverse: true);
      } else {
        _pulse
          ..stop()
          ..value = 0;
      }
    }
    final target = widget.ratio.clamp(0.0, 1.0).toDouble();
    if (target == _displayedRatio) return;
    // Animate from the currently displayed value — never from zero — so the
    // frequent ChatInputBar rebuilds don't flash the ring.
    _ratioAnim = Tween<double>(
      begin: _displayedRatio,
      end: target,
    ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(_value);
    _value
      ..reset()
      ..forward();
  }

  void _onValueChanged() {
    final anim = _ratioAnim;
    if (anim == null) return;
    final value = anim.value.clamp(0.0, 1.0).toDouble();
    if (value == _displayedRatio) return;
    setState(() => _displayedRatio = value);
  }

  @override
  void dispose() {
    _value.removeListener(_onValueChanged);
    _value.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final track =
        widget.trackColor ??
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.10);
    return FadeTransition(
      opacity: _pulseOpacity,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(
          painter: ContextUsageRingPainter(
            ratio: _displayedRatio,
            color: contextUsageColorForRatio(context, _displayedRatio),
            trackColor: track,
            strokeWidth: widget.strokeWidth,
          ),
        ),
      ),
    );
  }
}

/// Ring shown inside the compact context button.
///
/// The ring frame (empty track) is kept when [usage] is null or the window is
/// unknown — the button must not fall back to the plain workflow icon, which
/// changes the button's silhouette whenever a model's window is unknown.
class ContextUsageButtonIcon extends StatelessWidget {
  const ContextUsageButtonIcon({
    super.key,
    required this.usage,
    required this.loading,
    required this.color,
  });

  final ValueListenable<ContextUsageSnapshot?> usage;
  final bool loading;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ContextUsageSnapshot?>(
      valueListenable: usage,
      builder: (context, snapshot, _) => Center(
        // The slot's tight 24px constraints would otherwise stretch the ring.
        child: ContextUsageRing(
          ratio: snapshot?.ratio ?? 0.0,
          size: 20,
          strokeWidth: 2.6,
          running: loading,
          trackColor: color.withValues(alpha: 0.12),
        ),
      ),
    );
  }
}

/// Public (not library-private) so widget tests can assert the animated value
/// through `CustomPaint.painter`.
class ContextUsageRingPainter extends CustomPainter {
  const ContextUsageRingPainter({
    required this.ratio,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  final double ratio;
  final Color color;
  final Color trackColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = (size.shortestSide - strokeWidth) / 2;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: radius,
    );

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = trackColor;
    canvas.drawArc(rect, 0, 2 * math.pi, false, trackPaint);

    if (ratio <= 0) return;
    final sweep = 2 * math.pi * ratio.clamp(0.0, 1.0).toDouble();
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;
    // Start at 12 o'clock.
    canvas.drawArc(rect, -math.pi / 2, sweep, false, paint);
  }

  @override
  bool shouldRepaint(ContextUsageRingPainter oldDelegate) =>
      oldDelegate.ratio != ratio ||
      oldDelegate.color != color ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// `used / max Token ····· [percent]` row shown at the top of the context
/// menu (desktop) and the context management sheet (mobile). When the window
/// is unknown the denominator renders as `...` and the percentage badge is
/// hidden; only an absent snapshot collapses the header entirely.
class ContextUsageMenuHeader extends StatelessWidget {
  const ContextUsageMenuHeader({
    super.key,
    required this.listenable,
    this.padding = const EdgeInsets.fromLTRB(12, 10, 12, 10),
    this.showDivider = false,
  });

  final ValueListenable<ContextUsageSnapshot?> listenable;
  final EdgeInsets padding;

  /// Hairline divider rendered below the row — only when content is shown,
  /// so a collapsed header never leaves a stray divider behind.
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ContextUsageSnapshot?>(
      valueListenable: listenable,
      builder: (context, snapshot, _) {
        if (snapshot == null) {
          return const SizedBox.shrink();
        }
        final cs = Theme.of(context).colorScheme;
        final l10n = AppLocalizations.of(context);
        final estimatedLabel = l10n?.contextUsageEstimatedBadge ?? '≈';
        final hasWindow = snapshot.hasWindow;
        final overBudget = hasWindow && snapshot.ratio >= 0.90;
        final accent = overBudget ? cs.error : cs.primary;
        final maxLabel = hasWindow
            ? compactTokenText(snapshot.maxTokens!)
            : '...';
        return Padding(
          padding: padding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ContextUsageRing(
                    ratio: snapshot.ratio,
                    size: 18,
                    strokeWidth: 2.2,
                  ),
                  const SizedBox(width: 10),
                  // No Spacer here: a flex sibling would split the row's free
                  // width with the label and ellipsize `used / max` on narrow
                  // menus. Expanded keeps the badge at the end without
                  // truncating the denominator.
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            '${compactTokenText(snapshot.usedTokens)} / '
                            '$maxLabel Token',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              color: cs.onSurface,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                        if (snapshot.estimated) ...[
                          const SizedBox(width: 6),
                          Text(
                            estimatedLabel,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: cs.onSurface.withValues(alpha: 0.55),
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // No denominator → no percentage. The row still shows the
                  // measured usage on the left while the window is unknown.
                  if (hasWindow) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${snapshot.displayPercent}%',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: AppFontWeights.semibold,
                          color: accent,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (showDivider)
                Divider(
                  height: 1,
                  thickness: 1,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white.withValues(alpha: 0.08)
                      : cs.outlineVariant.withValues(alpha: 0.2),
                ),
            ],
          ),
        );
      },
    );
  }
}
