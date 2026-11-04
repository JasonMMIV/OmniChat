import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Watches the vector-graphics parse of an SVG string and shows a fallback if
/// it does not finish within [timeout].
///
/// The actual renderer is supplied by [childBuilder] so this widget can wrap
/// both the remote/local `SafeSvgImage` path and the inline `SafeSvgText`
/// path. [vg.loadPicture] is used only as a bounded preflight; it is not drawn
/// twice. The preflight picture is disposed immediately.
class SvgParseGuard extends StatefulWidget {
  const SvgParseGuard({
    super.key,
    required this.svg,
    required this.childBuilder,
    this.theme,
    this.timeout = const Duration(seconds: 2),
    this.errorBuilder,
    this.sourceFallback = false,
    this.parseProbe,
  });

  final String svg;
  final WidgetBuilder childBuilder;
  final SvgTheme? theme;
  final Duration timeout;
  final WidgetBuilder? errorBuilder;
  final bool sourceFallback;

  /// Test seam for a deliberately slow/failing parse. Production callers
  /// leave this null and use [vg.loadPicture].
  @visibleForTesting
  final Future<void> Function()? parseProbe;

  @override
  State<SvgParseGuard> createState() => _SvgParseGuardState();
}

class _SvgParseGuardState extends State<SvgParseGuard> {
  Timer? _timer;
  int _generation = 0;
  bool _started = false;
  bool _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _start();
    }
  }

  @override
  void didUpdateWidget(covariant SvgParseGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.svg != widget.svg || oldWidget.theme != widget.theme || oldWidget.timeout != widget.timeout) {
      _start();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _start() {
    _timer?.cancel();
    final generation = ++_generation;
    // didUpdateWidget/didChangeDependencies are followed by a build, so this
    // assignment does not need setState (which would be illegal during build).
    _failed = false;

    final Future<void> preflight;
    try {
      preflight = widget.parseProbe?.call() ?? _loadPreflight();
    } catch (_) {
      _markFailed(generation);
      return;
    }

    final timer = Timer(widget.timeout, () => _markFailed(generation));
    _timer = timer;
    unawaited(
      preflight.then<void>(
        (_) => timer.cancel(),
        onError: (_, __) {
          timer.cancel();
          _markFailed(generation);
        },
      ),
    );
  }

  Future<void> _loadPreflight() async {
    final info = await vg.loadPicture(SvgStringLoader(widget.svg, theme: widget.theme), context);
    info.picture.dispose();
  }

  void _markFailed(int generation) {
    if (!mounted || generation != _generation || _failed) return;
    setState(() => _failed = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return widget.errorBuilder?.call(context) ??
          (widget.sourceFallback ? _SvgSourceFallback(svg: widget.svg) : const Icon(Icons.broken_image));
    }
    return widget.childBuilder(context);
  }
}

class _SvgSourceFallback extends StatelessWidget {
  const _SvgSourceFallback({required this.svg});

  final String svg;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            svg,
            style: TextStyle(color: cs.onSurface, fontFamily: 'monospace', fontSize: 12, height: 1.35),
          ),
        ),
      ),
    );
  }
}
