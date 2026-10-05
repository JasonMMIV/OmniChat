// 過程收褶（process folding）UI 殼 — PLAN_PROCESS_FOLDING.md Phase 2。
//
// Port of AnyBuff's ProcessGroup.tsx: one collapsible header folding every
// non-prose row of one work segment (thinking text blocks + tool cards, in
// timeline order). The triangle points right while collapsed (`>`) and down
// once expanded (`v`, same AnimatedRotation parameters as the pre-folding
// reasoning card); the label flips 處理中.../Working… → 已完成/Worked with a
// compact three-dot bounce while live, and the elapsed timer carries over
// from the pre-folding thinking card.
//
// Presentation only: grouping and the live verdict come from
// process_group_logic.dart; the fold state is resolved by the caller
// (resolveProcessOpen: explicit pin > forced open > follow the run).
// Styling note (from AnyBuff, kept here): the live state is carried by the
// wording plus the bounce dots — not by an accent colour — so the header
// never pulls the eye away from the answer prose.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';

/// Collapsible shell for one work segment's process rows.
class ProcessGroupCard extends StatefulWidget {
  /// true → 處理中.../Working… label + bounce dots + running timer;
  /// false → 已完成/Worked.
  final bool live;

  /// Resolved fold state ([resolveProcessOpen] at the call site) — true
  /// renders the body rows.
  final bool open;

  final VoidCallback? onToggle;

  /// Elapsed timer anchors. The call site passes the message-level reasoning
  /// times (the pre-folding card's timer contract); null startAt hides the
  /// timer entirely. While live with no [finishedAt] the timer ticks.
  final DateTime? startAt;
  final DateTime? finishedAt;

  /// Folded rows in timeline order: thinking text blocks, then tool cards.
  /// Defaults to empty — a header-only shell (the caller never renders the
  /// group when the logic layer reports `visible: false`, so an empty shell
  /// is a degenerate, valid state).
  final List<Widget> children;

  const ProcessGroupCard({
    super.key,
    required this.live,
    required this.open,
    this.children = const [],
    this.onToggle,
    this.startAt,
    this.finishedAt,
  });

  @override
  State<ProcessGroupCard> createState() => _ProcessGroupCardState();
}

class _ProcessGroupCardState extends State<ProcessGroupCard>
    with SingleTickerProviderStateMixin {
  // Only the elapsed text rebuilds per tick — not the whole card (same
  // pattern as the pre-folding reasoning card's timer).
  final ValueNotifier<int> _elapsedTick = ValueNotifier<int>(0);
  late final Ticker _ticker = Ticker((_) {
    if (mounted) _elapsedTick.value++;
  });

  void _syncTicker() {
    final bool running = widget.live &&
        widget.startAt != null &&
        widget.finishedAt == null;
    if (running) {
      if (!_ticker.isActive) _ticker.start();
    } else {
      if (_ticker.isActive) _ticker.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant ProcessGroupCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elapsedTick.dispose();
    super.dispose();
  }

  String _elapsed() {
    final start = widget.startAt;
    if (start == null) return '';
    final end = widget.finishedAt ?? DateTime.now();
    final ms = end.difference(start).inMilliseconds;
    return '(${(ms / 1000).toStringAsFixed(1)}s)';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardTextColor =
        isDark ? const Color(0xFF9E9EA4) : const Color(0xFF7E7F83);
    final l10n = AppLocalizations.of(context)!;
    final label =
        widget.live ? l10n.processGroupWorking : l10n.processGroupWorked;

    final Widget header = IosCardPress(
      borderRadius: BorderRadius.circular(10),
      baseColor: Colors.transparent,
      pressedScale: 1.0,
      duration: const Duration(milliseconds: 220),
      onTap: widget.onToggle,
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            AnimatedRotation(
              turns: widget.open ? 0.25 : 0.0, // right -> down
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOutCubic,
              child: Icon(Lucide.ChevronRight, size: 18, color: cardTextColor),
            ),
            const SizedBox(width: 8),
            _LabelShimmer(
              enabled: widget.live,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.normal,
                  color: cardTextColor,
                ),
              ),
            ),
            if (widget.live) ...[
              const SizedBox(width: 6),
              _BouncingDots(color: cardTextColor),
            ],
            if (widget.startAt != null) ...[
              const SizedBox(width: 8),
              ValueListenableBuilder<int>(
                valueListenable: _elapsedTick,
                builder: (context, _, __) => _LabelShimmer(
                  enabled: widget.live,
                  child: Text(
                    _elapsed(),
                    style: TextStyle(
                      fontSize: 13,
                      color: cardTextColor.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: const Cubic(0.2, 0.8, 0.2, 1),
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          if (widget.open)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: widget.children,
              ),
            ),
        ],
      ),
    );
  }
}

/// The live "…" affordance — Flutter port of AnyBuff's
/// `.thinking-dots-compact` CSS bounce (0.9 s loop with 0.15 s/0.3 s
/// staggers, here approximated with a phase offset per dot). A tiny custom
/// animation rather than an icon glyph, so the bounce can match the bubble's
/// stream-placeholder rhythm.
class _BouncingDots extends StatefulWidget {
  final Color color;

  const _BouncingDots({required this.color});

  @override
  State<_BouncingDots> createState() => _BouncingDotsState();
}

class _BouncingDotsState extends State<_BouncingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('process-group-dots'),
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final double phase = (_c.value + i * 0.18) % 1.0;
              final double lift = math.sin(math.pi * phase); // 0..1..0
              return Transform.scale(
                scale: 0.72 + 0.28 * lift,
                child: Opacity(
                  opacity: 0.4 + 0.6 * lift,
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: widget.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

/// Lightweight shimmer sweep over the label while the segment is live —
/// self-contained copy of the pre-folding card's shimmer so the shell stays
/// decoupled from chat_message_widget.dart (the effect, not the code, is
/// what carries over).
class _LabelShimmer extends StatefulWidget {
  final Widget child;
  final bool enabled;

  const _LabelShimmer({required this.child, this.enabled = false});

  @override
  State<_LabelShimmer> createState() => _LabelShimmerState();
}

class _LabelShimmerState extends State<_LabelShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant _LabelShimmer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !_c.isAnimating) _c.repeat();
    if (!widget.enabled && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value; // 0..1
        return ShaderMask(
          shaderCallback: (rect) {
            final width = rect.width;
            final gradientWidth = width * 0.4;
            final dx = (width + gradientWidth) * t - gradientWidth;
            final shaderRect = Rect.fromLTWH(
              -dx,
              0,
              width + gradientWidth * 2,
              rect.height,
            );
            return LinearGradient(
              colors: [
                Colors.white.withValues(alpha: 0.0),
                Colors.white.withValues(alpha: 0.35),
                Colors.white.withValues(alpha: 0.0),
              ],
              stops: const [0.0, 0.5, 1.0],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ).createShader(shaderRect);
          },
          blendMode: BlendMode.srcATop,
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
