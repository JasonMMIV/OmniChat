import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../features/home/widgets/addons_menu.dart';
import '../l10n/app_localizations.dart';

/// Desktop entry for the Add-ons menu. Uses the same geometry as the previous
/// MCP menu: anchored to the composer, centered, up to 720px wide and flush
/// above the input bar (2026-11-10 Windows feedback pass).
Future<void> showAddonsPopover(
  BuildContext context, {
  required GlobalKey anchorKey,
  required String? assistantId,
  ValueChanged<String>? onDelegateProfile,
}) async {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;
  final keyContext = anchorKey.currentContext;
  if (keyContext == null) return;

  final box = keyContext.findRenderObject() as RenderBox?;
  if (box == null) return;
  final offset = box.localToGlobal(Offset.zero);
  final size = box.size;
  final anchorRect = Rect.fromLTWH(
    offset.dx,
    offset.dy,
    size.width,
    size.height,
  );

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _AddonsPopover(
      anchorRect: anchorRect,
      anchorWidth: size.width,
      assistantId: assistantId,
      onDelegateProfile: onDelegateProfile,
      onClose: () {
        try {
          entry.remove();
        } catch (_) {}
      },
    ),
  );
  overlay.insert(entry);
}

class _AddonsPopover extends StatefulWidget {
  const _AddonsPopover({
    required this.anchorRect,
    required this.anchorWidth,
    required this.assistantId,
    required this.onClose,
    this.onDelegateProfile,
  });

  final Rect anchorRect;
  final double anchorWidth;
  final String? assistantId;
  final ValueChanged<String>? onDelegateProfile;
  final VoidCallback onClose;

  @override
  State<_AddonsPopover> createState() => _AddonsPopoverState();
}

class _AddonsPopoverState extends State<_AddonsPopover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeIn;
  Offset _offset = const Offset(0, 0.12);
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
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
    // Same width formula as the old MCP popover (2026-11-10 feedback).
    final width = (widget.anchorWidth - 16).clamp(260.0, 720.0);
    final left =
        (widget.anchorRect.left + (widget.anchorRect.width - width) / 2).clamp(
          8.0,
          screen.width - width - 8.0,
        );
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
                      child: _Panel(
                        child: _AddonsPopoverContent(
                          assistantId: widget.assistantId,
                          onClose: _close,
                          onDelegateProfile: widget.onDelegateProfile,
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

/// Glass panel matching the pre-Add-ons composer popovers (including the old
/// MCP menu this replaces): blurred backdrop + translucent surface.
class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const radius = BorderRadius.vertical(top: Radius.circular(14));

    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: (isDark ? Colors.black : Colors.white).withOpacity(
              isDark ? 0.28 : 0.56,
            ),
            border: Border(
              top: BorderSide(
                color: Colors.white.withOpacity(isDark ? 0.06 : 0.18),
                width: 0.7,
              ),
              left: BorderSide(
                color: Colors.white.withOpacity(isDark ? 0.04 : 0.12),
                width: 0.6,
              ),
              right: BorderSide(
                color: Colors.white.withOpacity(isDark ? 0.04 : 0.12),
                width: 0.6,
              ),
            ),
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

class _AddonsPopoverContent extends StatelessWidget {
  const _AddonsPopoverContent({
    required this.assistantId,
    required this.onClose,
    this.onDelegateProfile,
  });

  final String? assistantId;
  final Future<void> Function() onClose;
  final ValueChanged<String>? onDelegateProfile;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ConstrainedBox(
      // Same max height as the old MCP menu.
      constraints: const BoxConstraints(maxHeight: 420),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.chatInputBarAddonsTooltip,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            AddonsMenuContent(
              assistantId: assistantId,
              // Await the 260 ms reverse animation so the overlay entry is
              // gone before the Self-Review dialog opens.
              onRequestClose: onClose,
              onDelegateProfile: onDelegateProfile,
            ),
          ],
        ),
      ),
    );
  }
}
