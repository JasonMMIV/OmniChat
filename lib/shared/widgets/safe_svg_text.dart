import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'safe_svg_image.dart' show SafeSvgImage, isSafeSvgText;
import 'svg_parse_guard.dart';

/// Renders an inline `<svg>` payload without any network or file access.
///
/// Validation and dimension limits are shared with [SafeSvgImage]; this widget
/// only adds the inline (intrinsic-size) layout path.
class SafeSvgText extends StatefulWidget {
  const SafeSvgText({
    super.key,
    required this.svg,
    this.width,
    this.height,
    this.currentColor,
    this.fontSize,
    this.parseTimeout = const Duration(seconds: 2),
    this.errorBuilder,
  });

  final String svg;
  final double? width;
  final double? height;
  final Color? currentColor;
  final double? fontSize;
  final Duration parseTimeout;
  final WidgetBuilder? errorBuilder;

  @override
  State<SafeSvgText> createState() => _SafeSvgTextState();
}

class _SafeSvgTextState extends State<SafeSvgText> {
  late bool _safe = _validate(widget.svg);

  static bool _validate(String svg) {
    if (svg.trim().isEmpty) return false;
    if (utf8.encode(svg).length > SafeSvgImage.maxBytes) return false;
    return isSafeSvgText(svg);
  }

  @override
  void didUpdateWidget(covariant SafeSvgText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.svg != widget.svg) {
      _safe = _validate(widget.svg);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_safe) return const Icon(Icons.broken_image);

    final width = _bounded(widget.width);
    final height = _bounded(widget.height);
    final theme = SvgTheme(
      currentColor: widget.currentColor ?? const Color(0xFF000000),
      fontSize: widget.fontSize ?? 14,
    );
    return SvgParseGuard(
      svg: widget.svg,
      theme: theme,
      timeout: widget.parseTimeout,
      sourceFallback: true,
      errorBuilder: widget.errorBuilder,
      childBuilder: (_) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: SafeSvgImage.maxDimension, maxHeight: SafeSvgImage.maxDimension),
        child: SvgPicture.string(
          widget.svg,
          width: width,
          height: height,
          fit: BoxFit.contain,
          theme: theme,
          errorBuilder: (_, __, ___) => widget.errorBuilder?.call(context) ?? const Icon(Icons.broken_image),
        ),
      ),
    );
  }

  static double? _bounded(double? value) {
    if (value == null || !value.isFinite) return null;
    return value.clamp(1.0, SafeSvgImage.maxDimension).toDouble();
  }
}
