// Desktop anchored skills popover (PLAN_AGENT_SKILLS.md §8.4) — modeled on
// quick_phrase_popover: Overlay + glass panel anchored above the input bar.
// Each row: sparkles icon + skill name + description preview + scope badge.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/models/skill.dart';
import '../icons/lucide_adapter.dart';
import '../l10n/app_localizations.dart';

Future<SkillDefinition?> showDesktopSkillsPopover(
  BuildContext context, {
  required GlobalKey anchorKey,
  required List<SkillDefinition> skills,
}) async {
  if (skills.isEmpty) return null;
  final overlay = Overlay.of(context);
  final keyContext = anchorKey.currentContext;
  if (keyContext == null) return null;

  final box = keyContext.findRenderObject() as RenderBox?;
  if (box == null) return null;
  final offset = box.localToGlobal(Offset.zero);
  final size = box.size;
  final anchorRect =
      Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);

  final completer = Completer<SkillDefinition?>();
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _SkillsPopover(
      anchorRect: anchorRect,
      anchorWidth: size.width,
      skills: skills,
      onSelect: (s) {
        try {
          entry.remove();
        } catch (_) {}
        if (!completer.isCompleted) completer.complete(s);
      },
      onClose: () {
        try {
          entry.remove();
        } catch (_) {}
        if (!completer.isCompleted) completer.complete(null);
      },
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _SkillsPopover extends StatefulWidget {
  const _SkillsPopover({
    required this.anchorRect,
    required this.anchorWidth,
    required this.skills,
    required this.onSelect,
    required this.onClose,
  });

  final Rect anchorRect;
  final double anchorWidth;
  final List<SkillDefinition> skills;
  final ValueChanged<SkillDefinition> onSelect;
  final VoidCallback onClose;

  @override
  State<_SkillsPopover> createState() => _SkillsPopoverState();
}

class _SkillsPopoverState extends State<_SkillsPopover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeIn;
  Offset _offset = const Offset(0, 0.12);
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
    _fadeIn = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      setState(() => _offset = Offset.zero);
      try {
        await _controller.forward();
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    setState(() => _offset = const Offset(0, 1.0));
    try {
      await _controller.reverse();
    } catch (_) {}
    if (mounted) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final width = (widget.anchorWidth - 16).clamp(320.0, 720.0);
    final left = (widget.anchorRect.left + (widget.anchorRect.width - width) / 2)
        .clamp(8.0, screen.width - width - 8.0);
    final clipHeight = widget.anchorRect.top.clamp(0.0, screen.height);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _close,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: clipHeight,
          child: ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: left,
                  width: width,
                  bottom: 0,
                  child: FadeTransition(
                    opacity: _fadeIn,
                    child: AnimatedSlide(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      offset: _offset,
                      child: _GlassPanel(
                        borderRadius:
                            const BorderRadius.vertical(top: Radius.circular(14)),
                        child: _SkillList(
                          skills: widget.skills,
                          onSelect: (s) {
                            if (_closing) return;
                            widget.onSelect(s);
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.child, this.borderRadius});
  final Widget child;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: (isDark ? Colors.black : Colors.white)
                .withOpacity(isDark ? 0.28 : 0.56),
            border: Border(
              top: BorderSide(
                  color: Colors.white.withOpacity(isDark ? 0.06 : 0.18),
                  width: 0.7),
              left: BorderSide(
                  color: Colors.white.withOpacity(isDark ? 0.04 : 0.12),
                  width: 0.6),
              right: BorderSide(
                  color: Colors.white.withOpacity(isDark ? 0.04 : 0.12),
                  width: 0.6),
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _SkillList extends StatelessWidget {
  const _SkillList({required this.skills, required this.onSelect});
  final List<SkillDefinition> skills;
  final ValueChanged<SkillDefinition> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
          shrinkWrap: true,
          itemCount: skills.length,
          itemBuilder: (context, index) {
            final s = skills[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 1),
              child: _SkillRow(
                skill: s,
                onTap: () => onSelect(s),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SkillRow extends StatefulWidget {
  const _SkillRow({required this.skill, required this.onTap});
  final SkillDefinition skill;
  final VoidCallback onTap;

  @override
  State<_SkillRow> createState() => _SkillRowState();
}

class _SkillRowState extends State<_SkillRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final hoverBg = (isDark ? Colors.white : Colors.black)
        .withOpacity(isDark ? 0.12 : 0.10);
    final l10n = AppLocalizations.of(context)!;
    final scopeLabel = widget.skill.scope == SkillScope.project
        ? l10n.skillScopeProject
        : l10n.skillScopeGlobal;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: _hovered ? hoverBg : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                Lucide.Sparkles,
                size: 16,
                color: cs.primary.withOpacity(0.8),
              ),
              const SizedBox(width: 8),
              Text(
                widget.skill.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.skill.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: cs.onSurface.withOpacity(0.7),
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: cs.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  scopeLabel,
                  style: TextStyle(
                    fontSize: 10,
                    color: cs.primary.withOpacity(0.85),
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
