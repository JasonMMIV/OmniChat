import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/models/chat_message.dart';
import '../../../shared/responsive/breakpoints.dart';
import '../utils/mini_map_pairs.dart';

const double _userFontSize = 15;
const double _userLineHeight = 1.35;
const double _assistantFontSize = 15.2;
const double _assistantLineHeight = 1.4;
const double _userVerticalPadding = 8;
const double _assistantVerticalPadding = 4;
const double _rowGap = 6;
const double _rowBottomPadding = 6;
const double _rowExtentSlack = 0.5;

/// Shows the mini-map as an anchored popup above [anchorKey].
///
/// The route is a normal dialog route rather than a raw [OverlayEntry] so the
/// Android system back button closes the popup instead of leaving the page.
Future<String?> showMiniMapPopover(
  BuildContext context, {
  required GlobalKey anchorKey,
  required List<ChatMessage> messages,
}) async {
  final anchorContext = anchorKey.currentContext;
  if (anchorContext == null) return null;

  final anchorBox = anchorContext.findRenderObject() as RenderBox?;
  if (anchorBox == null || !anchorBox.hasSize) return null;

  final pairs = buildMiniMapPairs(messages);
  if (pairs.isEmpty) return null;

  final initialAnchorRect =
      anchorBox.localToGlobal(Offset.zero) & anchorBox.size;

  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    transitionDuration: Duration.zero,
    requestFocus: false,
    pageBuilder: (dialogContext, _, __) {
      return _MiniMapPopover(
        anchorKey: anchorKey,
        initialAnchorRect: initialAnchorRect,
        pairs: pairs,
        onSelect: (id) => Navigator.of(dialogContext).pop(id),
      );
    },
  );
}

class _MiniMapPopover extends StatefulWidget {
  const _MiniMapPopover({
    required this.anchorKey,
    required this.initialAnchorRect,
    required this.pairs,
    required this.onSelect,
  });

  final GlobalKey anchorKey;
  final Rect initialAnchorRect;
  final List<MiniMapPair> pairs;
  final ValueChanged<String> onSelect;

  @override
  State<_MiniMapPopover> createState() => _MiniMapPopoverState();
}

class _MiniMapPopoverState extends State<_MiniMapPopover>
    with SingleTickerProviderStateMixin {
  static const double _anchorGap = 6;
  static const double _edgeInset = 12;
  static const double _maxPanelWidth = 380;
  static const double _maxPanelHeight = 420;
  static const double _mobileHeightFactor = 0.45;

  late final AnimationController _controller;
  late final Animation<double> _fadeIn;
  late final Animation<double> _slideY;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _fadeIn = curve;
    _slideY = Tween<double>(begin: 16, end: 0).animate(curve);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Rect? _currentAnchorRect() {
    final anchorContext = widget.anchorKey.currentContext;
    if (anchorContext == null) return null;
    final anchorBox = anchorContext.findRenderObject() as RenderBox?;
    if (anchorBox == null || !anchorBox.hasSize) return null;
    return anchorBox.localToGlobal(Offset.zero) & anchorBox.size;
  }

  void _handleSelect(String id) {
    if (!mounted || _closing) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    _closing = true;
    widget.onSelect(id);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final padding = media.padding;
    final anchorRect = _currentAnchorRect() ?? widget.initialAnchorRect;

    final right = math.max(_edgeInset, screen.width - anchorRect.right);
    final availableWidth =
        screen.width - right - math.max(padding.left, _edgeInset);
    final panelWidth = math.min(_maxPanelWidth, availableWidth);

    final maxAvailableHeight = anchorRect.top - padding.top - _edgeInset;
    final platformCap = screen.width < AppBreakpoints.tablet
        ? math.min(_maxPanelHeight, screen.height * _mobileHeightFactor)
        : _maxPanelHeight;
    final maxHeight = math.min(platformCap, maxAvailableHeight);

    if (panelWidth <= 0 || maxHeight <= 0) {
      return const SizedBox.shrink();
    }

    final bottom = screen.height - anchorRect.top + _anchorGap;

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          right: right,
          bottom: bottom,
          width: panelWidth,
          child: ConstrainedBox(
            key: const ValueKey('mini-map-popover'),
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: FadeTransition(
              opacity: _fadeIn,
              child: AnimatedBuilder(
                animation: _slideY,
                builder: (context, child) => Transform.translate(
                  offset: Offset(0, _slideY.value),
                  child: child,
                ),
                child: _GlassPanel(
                  child: _MiniMapList(
                    pairs: widget.pairs,
                    onSelect: _handleSelect,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(14);
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: (isDark ? Colors.black : Colors.white).withOpacity(
              isDark ? 0.28 : 0.56,
            ),
            border: Border.all(
              color: Colors.white.withOpacity(isDark ? 0.07 : 0.18),
              width: 0.7,
            ),
            borderRadius: radius,
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

class _MiniMapList extends StatelessWidget {
  const _MiniMapList({required this.pairs, required this.onSelect});

  static const EdgeInsets _padding = EdgeInsets.fromLTRB(12, 10, 12, 2);

  final List<MiniMapPair> pairs;
  final ValueChanged<String> onSelect;
  double _rowHeight(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final userLineHeight = (textScaler.scale(_userFontSize) * _userLineHeight)
        .ceilToDouble();
    final assistantLineHeight =
        (textScaler.scale(_assistantFontSize) * _assistantLineHeight)
            .ceilToDouble();
    final userHeight = _userVerticalPadding * 2 + userLineHeight;
    final assistantHeight = _assistantVerticalPadding * 2 + assistantLineHeight;
    return userHeight +
        _rowGap +
        assistantHeight +
        _rowBottomPadding +
        _rowExtentSlack;
  }

  @override
  Widget build(BuildContext context) {
    if (pairs.isEmpty) return const SizedBox.shrink();

    final rowHeight = _rowHeight(context);
    final contentHeight =
        _padding.top + pairs.length * rowHeight + _padding.bottom;

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = math.min(contentHeight, constraints.maxHeight);
        if (height <= 0) return const SizedBox.shrink();
        return SizedBox(
          height: height,
          child: ListView.builder(
            key: const ValueKey('mini-map-list'),
            padding: _padding,
            primary: false,
            itemExtent: rowHeight,
            itemCount: pairs.length,
            itemBuilder: (context, index) {
              final pair = pairs[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: _rowBottomPadding),
                child: _MiniMapRow(
                  user: pair.user,
                  assistant: pair.assistant,
                  onSelect: onSelect,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _MiniMapRow extends StatefulWidget {
  const _MiniMapRow({
    required this.user,
    required this.assistant,
    required this.onSelect,
  });

  final ChatMessage? user;
  final ChatMessage? assistant;
  final ValueChanged<String> onSelect;

  @override
  State<_MiniMapRow> createState() => _MiniMapRowState();
}

class _MiniMapRowState extends State<_MiniMapRow> {
  bool _hoverUser = false;
  bool _hoverAssistant = false;
  bool _pressedUser = false;
  bool _pressedAssistant = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final userText = widget.user?.content ?? '';
    final assistantText = widget.assistant?.content ?? '';

    final baseUserColor = isDark
        ? cs.primary.withOpacity(0.15)
        : cs.primary.withOpacity(0.08);
    final hoverUserColor = isDark
        ? cs.primary.withOpacity(0.22)
        : cs.primary.withOpacity(0.14);
    final pressedUserColor = isDark
        ? cs.primary.withOpacity(0.30)
        : cs.primary.withOpacity(0.18);
    final userColor = _pressedUser
        ? pressedUserColor
        : (_hoverUser ? hoverUserColor : baseUserColor);

    final assistantColor = _pressedAssistant
        ? cs.onSurface.withOpacity(0.09)
        : (_hoverAssistant
              ? cs.onSurface.withOpacity(0.05)
              : Colors.transparent);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: MouseRegion(
            cursor: widget.user != null
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onEnter: (_) {
              if (widget.user == null) return;
              setState(() => _hoverUser = true);
            },
            onExit: (_) {
              if (widget.user == null) return;
              setState(() => _hoverUser = false);
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: widget.user == null
                  ? null
                  : (_) => setState(() => _pressedUser = true),
              onTapUp: widget.user == null
                  ? null
                  : (_) => setState(() => _pressedUser = false),
              onTapCancel: widget.user == null
                  ? null
                  : () => setState(() => _pressedUser = false),
              onTap: widget.user == null
                  ? null
                  : () => widget.onSelect(widget.user!.id),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: _userVerticalPadding,
                ),
                decoration: BoxDecoration(
                  color: userColor,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  userText.isNotEmpty ? miniMapToOneLine(userText) : ' ',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _userFontSize,
                    height: _userLineHeight,
                    color: cs.onSurface,
                    decoration: TextDecoration.none,
                  ),
                  textAlign: TextAlign.left,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: _rowGap),
        MouseRegion(
          cursor: widget.assistant != null
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) {
            if (widget.assistant == null) return;
            setState(() => _hoverAssistant = true);
          },
          onExit: (_) {
            if (widget.assistant == null) return;
            setState(() => _hoverAssistant = false);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: widget.assistant == null
                ? null
                : (_) => setState(() => _pressedAssistant = true),
            onTapUp: widget.assistant == null
                ? null
                : (_) => setState(() => _pressedAssistant = false),
            onTapCancel: widget.assistant == null
                ? null
                : () => setState(() => _pressedAssistant = false),
            onTap: widget.assistant == null
                ? null
                : () => widget.onSelect(widget.assistant!.id),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: _assistantVerticalPadding,
              ),
              decoration: BoxDecoration(
                color: assistantColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                assistantText.isNotEmpty
                    ? miniMapToOneLine(assistantText)
                    : ' ',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: _assistantFontSize,
                  height: _assistantLineHeight,
                  decoration: TextDecoration.none,
                ),
                textAlign: TextAlign.left,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
