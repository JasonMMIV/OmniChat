import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;

import '../../core/services/web/ssrf_guard.dart';
import '../../utils/sandbox_path_resolver.dart';
import 'svg_parse_guard.dart';

/// True for Markdown image sources that should use the SVG renderer.
bool isSvgSource(String source) {
  final lower = source.trim().toLowerCase();
  if (lower.startsWith('data:image/svg+xml')) return true;
  final parsed = Uri.tryParse(lower);
  final path = parsed?.path ?? lower;
  return path.endsWith('.svg');
}

/// Rejects active or external-reference SVG features before handing bytes to
/// the renderer. This is a cheap pre-scan, not a full XML sanitizer.
bool isSafeSvgText(String svg) {
  final lower = svg.toLowerCase();
  final structural = lower
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(RegExp(r'<style\b[\s\S]*?</style>'), '');
  if (!RegExp(r'<svg\b').hasMatch(structural)) return false;
  if (structural.contains('<script') || structural.contains('<foreignobject') || structural.contains('<iframe')) {
    return false;
  }
  if (RegExp(r'\son[a-z]+\s*=').hasMatch(structural)) return false;
  // Only same-document fragment references are allowed.
  if (RegExp(r'''(?:href|xlink:href)\s*=\s*['"](?!#)''').hasMatch(lower)) {
    return false;
  }
  // url(#gradient) and url('#gradient') are fine; external/data/file URLs are
  // not. Capture the target so an optional quote cannot backtrack into a
  // non-fragment match.
  final urlStarts = RegExp(r'url\(').allMatches(structural).length;
  final urlMatches = RegExp(r'''url\(\s*(?:['"]\s*)?([^)"'\s]*)\s*['"]?\s*\)''').allMatches(structural).toList();
  if (urlStarts != urlMatches.length) return false;
  for (final match in urlMatches) {
    final reference = match.group(1) ?? '';
    if (!reference.startsWith('#')) return false;
  }
  // Cheap structural caps before handing the source to the parser.
  var elements = 0;
  var depth = 0;
  for (final match in RegExp(r'<\s*(/?)\s*([a-z][\w:-]*)([^>]*)>').allMatches(structural)) {
    final closing = match.group(1) == '/';
    if (closing) {
      if (depth > 0) depth--;
      continue;
    }
    elements++;
    if (elements > 5000) return false;
    final attrs = match.group(3) ?? '';
    if (attrs.trimRight().endsWith('/')) continue;
    depth++;
    if (depth > 64) return false;
  }
  final rootTag = RegExp(r'<svg\b[^>]*>').firstMatch(structural)?.group(0);
  if (rootTag != null) {
    double? dimension(String name) {
      final match = RegExp('(?<![\\w-])$name\\s*=\\s*["\']\\s*([0-9]*\\.?[0-9]+)').firstMatch(rootTag);
      return double.tryParse(match?.group(1) ?? '');
    }

    final rootWidth = dimension('width');
    final rootHeight = dimension('height');
    if ((rootWidth != null && rootWidth > SafeSvgImage.maxDimension) ||
        (rootHeight != null && rootHeight > SafeSvgImage.maxDimension)) {
      return false;
    }
    final viewBox = RegExp(
      r'''viewbox\s*=\s*["']\s*([-\d.]+)[\s,]+([-\d.]+)[\s,]+([-\d.]+)[\s,]+([-\d.]+)''',
    ).firstMatch(rootTag);
    if (viewBox != null) {
      final viewWidth = double.tryParse(viewBox.group(3) ?? '')?.abs();
      final viewHeight = double.tryParse(viewBox.group(4) ?? '')?.abs();
      if (viewWidth != null && viewHeight != null && viewWidth * viewHeight > 4096 * 1024) {
        return false;
      }
    }
  }
  var pathChars = 0;
  for (final match in RegExp(r'''<path\b[^>]*\bd\s*=\s*["']([^"']*)["']''').allMatches(structural)) {
    pathChars += match.group(1)?.length ?? 0;
    if (pathChars > 256 * 1024) return false;
  }
  return true;
}

/// Loads an SVG without delegating downloads to `SvgPicture.network`.
///
/// Remote sources are fetched with an [SsrfGuard] check on every redirect hop
/// and a hard [maxBytes] cap. Local files use async length/read calls so a UNC
/// path cannot block the UI isolate. Rendering is bounded to 4096 px on each
/// axis and uses `BoxFit.contain`.
class SafeSvgImage extends StatefulWidget {
  const SafeSvgImage({
    super.key,
    required this.source,
    this.width,
    this.height,
    this.byteLimit,
    this.timeout = const Duration(seconds: 15),
    this.parseTimeout = const Duration(seconds: 2),
    this.placeholderBuilder,
    this.errorBuilder,
    this.guard,
    this.clientFactory,
  });

  final String source;
  final double? width;
  final double? height;

  /// Per-widget byte cap; defaults to [maxBytes].
  final int? byteLimit;
  final Duration timeout;
  final Duration parseTimeout;
  final WidgetBuilder? placeholderBuilder;
  final WidgetBuilder? errorBuilder;

  /// Optional injection points for tests / custom transports.
  final SsrfGuard? guard;
  final http.Client Function()? clientFactory;

  static const int maxBytes = 512 * 1024;
  static const double maxDimension = 4096;

  int get effectiveByteLimit => byteLimit ?? maxBytes;

  @override
  State<SafeSvgImage> createState() => _SafeSvgImageState();
}

class _SafeSvgImageState extends State<SafeSvgImage> {
  static final Map<String, Future<String?>> _cache = <String, Future<String?>>{};
  static const int _cacheLimit = 8;

  late Future<String?> _svg;

  @override
  void initState() {
    super.initState();
    _svg = _load();
  }

  @override
  void didUpdateWidget(covariant SafeSvgImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source || oldWidget.byteLimit != widget.byteLimit) {
      _svg = _load();
    }
  }

  Future<String?> _load() {
    final source = widget.source;
    // Include the byte limit so a Markdown 512 KB image and a 2 MB PlantUML
    // diagram sharing a URL do not inherit whichever limit loaded first.
    final key = '${widget.effectiveByteLimit}|$source';
    // Large data URIs would pin up to ~1 MB each in the static cache; small
    // ones are cheap to keep and avoid re-decoding on every new State.
    if (source.startsWith('data:') && source.length > 64 * 1024) {
      return _validate(_loadUncached(source));
    }
    final existing = _cache[key];
    if (existing != null) return existing;
    final future = _validate(_loadUncached(source));
    _cache[key] = future;
    unawaited(
      future.then<void>(
        (value) {
          if (value == null && identical(_cache[key], future)) {
            _cache.remove(key);
          }
        },
        onError: (_) {
          if (identical(_cache[key], future)) _cache.remove(key);
        },
      ),
    );
    if (_cache.length > _cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
    return future;
  }

  Future<String?> _validate(Future<String?> raw) async {
    final svg = await raw;
    if (svg == null || svg.trim().isEmpty || !isSafeSvgText(svg)) {
      return null;
    }
    return svg;
  }

  Future<String?> _loadUncached(String source) async {
    final raw = source.trim();
    if (raw.isEmpty) return null;

    if (raw.startsWith('data:')) {
      return _decodeDataUri(raw);
    }
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return _fetchRemote(Uri.parse(raw));
    }
    if (raw.startsWith('//')) {
      return _fetchRemote(Uri.parse('https:$raw'));
    }
    if (raw.startsWith(r'\\')) return null;

    try {
      final uri = raw.startsWith('file://') ? Uri.tryParse(raw) : null;
      final file = uri != null && uri.host.isEmpty ? File(uri.toFilePath()) : File(SandboxPathResolver.fix(raw));
      final length = await file.length();
      if (length <= 0 || length > widget.effectiveByteLimit) return null;
      final bytes = await file.readAsBytes();
      return _decodeUtf8(bytes);
    } catch (_) {
      return null;
    }
  }

  String? _decodeDataUri(String source) {
    try {
      final comma = source.indexOf(',');
      if (comma < 0) return null;
      final meta = source.substring(5, comma).toLowerCase();
      final payload = source.substring(comma + 1);
      if (payload.length > widget.effectiveByteLimit * 2) return null;
      final List<int> bytes;
      if (meta.contains(';base64')) {
        bytes = base64Decode(payload);
      } else {
        bytes = Uint8List.fromList(utf8.encode(Uri.decodeFull(payload)));
      }
      if (bytes.length > widget.effectiveByteLimit) return null;
      return _decodeUtf8(bytes);
    } catch (_) {
      return null;
    }
  }

  String? _decodeUtf8(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _fetchRemote(Uri start) async {
    final client = widget.clientFactory?.call() ?? http.Client();
    try {
      var uri = start;
      final guard = widget.guard ?? SsrfGuard();
      for (var hop = 0; hop < 5; hop++) {
        if (await guard.check(uri) != null) return null;

        final request = http.Request('GET', uri)..followRedirects = false;
        final response = await client.send(request).timeout(widget.timeout);
        final status = response.statusCode;
        if (status >= 300 && status < 400) {
          final location = response.headers['location'];
          await response.stream.drain<void>().timeout(const Duration(seconds: 3));
          if (location == null || location.isEmpty) return null;
          uri = uri.resolve(location);
          continue;
        }
        if (status != 200) {
          await response.stream.drain<void>().timeout(const Duration(seconds: 3));
          return null;
        }
        // Many static hosts serve `.svg` as text/plain or octet-stream; only
        // reject types that are clearly not SVG (PNG/HTML etc.). The root
        // pre-scan is the authoritative check.
        final contentType = response.headers['content-type']?.toLowerCase();
        final mime = contentType?.split(';').first.trim();
        if (mime != null && ((mime.startsWith('image/') && mime != 'image/svg+xml') || mime == 'text/html')) {
          await response.stream.drain<void>().timeout(const Duration(seconds: 3));
          return null;
        }

        final contentLength = int.tryParse(response.headers['content-length'] ?? '');
        if (contentLength != null && contentLength > widget.effectiveByteLimit) {
          await response.stream.drain<void>().timeout(const Duration(seconds: 3));
          return null;
        }

        final bytes = <int>[];
        final stream = response.stream.timeout(widget.timeout);
        await for (final chunk in stream) {
          if (bytes.length + chunk.length > widget.effectiveByteLimit) return null;
          bytes.addAll(chunk);
        }
        return _decodeUtf8(bytes);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final requestedWidth = widget.width;
        final width =
            (requestedWidth != null && requestedWidth.isFinite
                    ? requestedWidth.clamp(1.0, SafeSvgImage.maxDimension)
                    : (constraints.maxWidth.isFinite
                          ? constraints.maxWidth.clamp(1.0, SafeSvgImage.maxDimension)
                          : SafeSvgImage.maxDimension))
                .toDouble();
        final requestedHeight = widget.height;
        final height = requestedHeight != null && requestedHeight.isFinite
            ? requestedHeight.clamp(1.0, SafeSvgImage.maxDimension).toDouble()
            : null;

        return FutureBuilder<String?>(
          future: _svg,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return widget.placeholderBuilder?.call(context) ??
                  const SizedBox(
                    height: 64,
                    child: Center(
                      child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  );
            }
            final svg = snapshot.data;
            if (svg == null) {
              return widget.errorBuilder?.call(context) ?? const Icon(Icons.broken_image);
            }
            return SvgParseGuard(
              svg: svg,
              timeout: widget.parseTimeout,
              errorBuilder: widget.errorBuilder,
              childBuilder: (_) => ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: SafeSvgImage.maxDimension,
                  maxHeight: SafeSvgImage.maxDimension,
                ),
                child: SvgPicture.string(
                  svg,
                  width: width,
                  height: height,
                  fit: BoxFit.contain,
                  placeholderBuilder: (_) =>
                      widget.placeholderBuilder?.call(context) ??
                      const SizedBox(
                        height: 64,
                        child: Center(
                          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      ),
                  errorBuilder: (errorContext, _, __) =>
                      widget.errorBuilder?.call(errorContext) ?? const Icon(Icons.broken_image),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
