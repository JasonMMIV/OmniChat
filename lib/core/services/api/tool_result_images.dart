// Tool-result image planning (file_view_image Stage 2).
//
// The persisted tool result carries `[image:<absolute-path>]` markers. At send
// time this module:
//   1. extracts markers from role:'tool' messages (newest-first, bounded),
//   2. validates the path against the workspace / session-outputs / MCP cache
//      roots or an explicitly trusted path,
//   3. decodes + downscales + re-encodes the image,
//   4. returns a per-message plan the transports turn into native vision
//      parts.
//
// No bytes are persisted here. A missing/unreadable/oversized image degrades
// to the original text marker, never to a failed turn.

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../utils/markdown_media_sanitizer.dart';
import 'tool_image_codec.dart';

export 'tool_image_codec.dart' show ToolImageEncoded, ToolImageTarget;

/// Raw marker extracted from a tool result.
class ToolImageMarker {
  const ToolImageMarker({
    required this.path,
    required this.start,
    required this.end,
    required this.raw,
  });

  final String path;
  final int start;
  final int end;
  final String raw;
}

/// One validated image ready for a transport encoder.
class ToolImagePayload {
  const ToolImagePayload({
    required this.path,
    required this.encoded,
    required this.displayName,
  });

  /// Canonical absolute path on disk.
  final String path;
  final ToolImageEncoded encoded;

  /// Unique per `functionResponse` (Gemini); also useful for diagnostics.
  final String displayName;

  String get mime => encoded.mime;
  Uint8List get bytes => encoded.bytes;
  int get width => encoded.width;
  int get height => encoded.height;
}

/// Non-fatal image failure. These are logged and the marker stays as text.
class ToolImageError {
  const ToolImageError(this.code, this.path, [this.detail = '']);

  final String code;
  final String path;
  final String detail;

  @override
  String toString() => 'ToolImageError($code, $path): $detail';
}

/// Per-message result: cleaned text + attached images.
class ToolImageResolution {
  const ToolImageResolution({
    required this.cleanText,
    this.images = const <ToolImagePayload>[],
    this.errors = const <ToolImageError>[],
  });

  final String cleanText;
  final List<ToolImagePayload> images;
  final List<ToolImageError> errors;
}

/// Caller-supplied policy (workspace root + global enable flag).
class ToolImagePolicy {
  const ToolImagePolicy({
    this.workspaceRoot,
    this.enabled = true,
    this.extraAllowedRoots = const <String>[],
    this.maxRawBytes = ToolImageCodec.defaultMaxRawBytes,
  });

  final String? workspaceRoot;
  final bool enabled;
  final List<String> extraAllowedRoots;
  final int maxRawBytes;

  /// Resolves the Flutter-owned directories (session outputs + MCP screenshot
  /// cache) and the trusted-path ledger into a pure-Dart policy.
  ResolvedToolImagePolicy resolve({
    Iterable<String> systemRoots = const <String>[],
    Iterable<String> trustedPaths = const <String>[],
  }) {
    final roots = <String>[
      if (workspaceRoot != null && workspaceRoot!.trim().isNotEmpty)
        workspaceRoot!,
      ...extraAllowedRoots,
      ...systemRoots,
    ];
    return ResolvedToolImagePolicy(
      allowedRoots: <String>[
        for (final root in roots)
          if (root.trim().isNotEmpty) _normalize(root),
      ],
      trustedPaths: <String>{
        for (final path in trustedPaths)
          if (path.trim().isNotEmpty) _normalize(path),
      },
      enabled: enabled,
      maxRawBytes: maxRawBytes,
    );
  }
}

/// Pure-Dart policy after path-directory resolution.
class ResolvedToolImagePolicy {
  const ResolvedToolImagePolicy({
    required this.allowedRoots,
    this.trustedPaths = const <String>{},
    this.enabled = true,
    this.maxRawBytes = ToolImageCodec.defaultMaxRawBytes,
  });

  final List<String> allowedRoots;
  final Set<String> trustedPaths;
  final bool enabled;
  final int maxRawBytes;

  /// Root-based allowance (workspace / session outputs / MCP cache). The
  /// caller must pass the **canonical** path so a symlink cannot smuggle a
  /// target outside the root.
  bool allowsRoot(String path) {
    final normalized = _normalize(path);
    for (final root in allowedRoots) {
      if (_isWithin(root, normalized)) return true;
    }
    return false;
  }

  /// Explicitly approved paths. This is the in-memory ledger only; persisted
  /// tool-event extras must never grant an outside path (imported backups are
  /// untrusted).
  bool allowsTrusted(String path) => trustedPaths.contains(_normalize(path));

  bool allows(String path) => allowsRoot(path) || allowsTrusted(path);
}

/// The complete send-time image plan.
class ToolImagePlan {
  const ToolImagePlan({
    this.byMessageIndex = const <int, ToolImageResolution>{},
    this.tailUserImages = const <ToolImagePayload>[],
    this.totalImages = 0,
    this.errors = const <ToolImageError>[],
  });

  static const ToolImagePlan empty = ToolImagePlan();

  /// Native transports (Claude / Responses / Gemini) read this by message index.
  final Map<int, ToolImageResolution> byMessageIndex;

  /// Chat Completions appends these after the final consecutive tool group.
  final List<ToolImagePayload> tailUserImages;

  final int totalImages;
  final List<ToolImageError> errors;

  bool get isEmpty => totalImages == 0;

  static Future<ToolImagePlan> build({
    required List<Map<String, dynamic>> messages,
    required ResolvedToolImagePolicy policy,
    required ToolImageTarget target,
    required bool canImageInput,
    ToolImageCodec codec = const ToolImageCodec(),
  }) async {
    if (!policy.enabled || !canImageInput || messages.isEmpty) {
      return ToolImagePlan.empty;
    }

    final maxPerRequest = target.maxImagesPerRequest;
    final maxPerMessage = target.maxImagesPerToolMessage;
    final byMessageIndex = <int, ToolImageResolution>{};
    final tailImages = <ToolImagePayload>[];
    final allErrors = <ToolImageError>[];
    final seenPaths = <String>{};
    var totalImages = 0;

    // For the Chat Completions synthetic-user path only the final consecutive
    // tool group is eligible. Earlier groups stay as text markers so replaying
    // a long history does not inject a user turn per tool round.
    var tailStart = messages.length;
    if (target == ToolImageTarget.openAiChat) {
      while (tailStart > 0 &&
          (messages[tailStart - 1]['role'] ?? '').toString() == 'tool') {
        tailStart--;
      }
      if (tailStart == messages.length) return ToolImagePlan.empty;
    }

    for (var i = messages.length - 1; i >= 0; i--) {
      if (totalImages >= maxPerRequest) break;
      final message = messages[i];
      if ((message['role'] ?? '').toString() != 'tool') continue;
      if (target == ToolImageTarget.openAiChat && i < tailStart) continue;

      final text = _toolContent(message);
      if (text.isEmpty) continue;
      final markers = extractMarkers(text);
      if (markers.isEmpty) continue;

      final messageImages = <ToolImagePayload>[];
      final messageErrors = <ToolImageError>[];
      final attachedMarkers = <ToolImageMarker>[];

      for (final marker in markers) {
        if (messageImages.length >= maxPerMessage ||
            totalImages >= maxPerRequest) {
          break;
        }
        final rawPath = marker.path.trim();
        final canonical = await _canonicalExistingFile(rawPath);
        if (canonical == null) {
          final error = ToolImageError(
            'image_not_found',
            rawPath,
            'The image file does not exist or is not readable.',
          );
          messageErrors.add(error);
          allErrors.add(error);
          continue;
        }

        final normalizedCanonical = _normalize(canonical);
        if (!_isAllowed(
          policy: policy,
          canonical: normalizedCanonical,
          raw: rawPath,
        )) {
          final error = ToolImageError(
            'image_outside_workspace',
            canonical,
            'The image path is outside the allowed roots.',
          );
          messageErrors.add(error);
          allErrors.add(error);
          continue;
        }

        // Duplicate marker whose earlier occurrence was successfully
        // attached: remove the duplicate text marker instead of sending the
        // same image twice. Crucially, `seenPaths` is only populated after a
        // successful attach below — a failed first occurrence must not erase
        // the marker or suppress a retry.
        if (seenPaths.contains(normalizedCanonical)) {
          attachedMarkers.add(marker);
          continue;
        }

        final expectedSha = _shaFor(message, rawPath, normalizedCanonical);
        if (expectedSha != null && expectedSha.isNotEmpty) {
          try {
            final actual = sha256
                .convert(await File(canonical).readAsBytes())
                .toString();
            if (actual != expectedSha) {
              final error = ToolImageError(
                'image_changed',
                canonical,
                'The file changed after the tool read it.',
              );
              messageErrors.add(error);
              allErrors.add(error);
              continue;
            }
          } catch (_) {
            final error = ToolImageError(
              'image_not_found',
              canonical,
              'The image file could not be read for verification.',
            );
            messageErrors.add(error);
            allErrors.add(error);
            continue;
          }
        }

        try {
          final encoded = await codec.normalize(
            path: canonical,
            target: target,
            maxRawBytes: policy.maxRawBytes,
          );
          messageImages.add(
            ToolImagePayload(
              path: canonical,
              encoded: encoded,
              displayName:
                  'image_${messageImages.length}.${_extensionFor(encoded.mime)}',
            ),
          );
          seenPaths.add(normalizedCanonical);
          attachedMarkers.add(marker);
          totalImages++;
        } on ToolImageCodecException catch (e) {
          final error = ToolImageError(e.code, canonical, e.message);
          messageErrors.add(error);
          allErrors.add(error);
        } catch (_) {
          final error = ToolImageError(
            'image_decode_failed',
            canonical,
            'The image could not be decoded.',
          );
          messageErrors.add(error);
          allErrors.add(error);
        }
      }

      if (messageImages.isEmpty) continue;

      if (target == ToolImageTarget.openAiChat) {
        tailImages.addAll(messageImages);
      } else {
        byMessageIndex[i] = ToolImageResolution(
          cleanText: _removeMarkers(text, attachedMarkers),
          images: messageImages,
          errors: messageErrors,
        );
      }
    }

    return ToolImagePlan(
      byMessageIndex: byMessageIndex,
      tailUserImages: tailImages,
      totalImages: totalImages,
      errors: allErrors,
    );
  }
}

/// Marker pattern used by both `file_view_image` and MCP screenshot markers.
/// Deliberately excludes `]`, CR and LF so a malformed marker cannot swallow
/// the rest of a tool result.
final RegExp _markerPattern = RegExp(r'\[image:([^\]\r\n]+)\]');

/// Extracts local image markers. Remote/data markers stay as text; Stage 2
/// only reads local files that passed the path policy.
List<ToolImageMarker> extractMarkers(String text) {
  final markers = <ToolImageMarker>[];
  for (final match in _markerPattern.allMatches(text)) {
    final rawPath = (match.group(1) ?? '').trim();
    if (rawPath.isEmpty) continue;
    if (rawPath.startsWith('data:')) continue;
    if (rawPath.startsWith('http://') || rawPath.startsWith('https://')) {
      continue;
    }
    // Protocol-relative / UNC paths are network locations. Probing them
    // (existsSync / stat) can stall for the SMB timeout on Windows, so the
    // marker stays plain text and never becomes an eligible tool image.
    if (MarkdownMediaSanitizer.isNetworkShapedPath(rawPath)) continue;
    if (rawPath.startsWith('<') && rawPath.endsWith('>')) continue;
    if (rawPath.contains('\u0000')) continue;
    markers.add(
      ToolImageMarker(
        path: rawPath,
        start: match.start,
        end: match.end,
        raw: match.group(0) ?? '',
      ),
    );
  }
  return markers;
}

String _toolContent(Map<String, dynamic> message) {
  final content = message['content'];
  if (content is String) return content;
  if (content is List) {
    final buffer = StringBuffer();
    for (final part in content) {
      if (part is String) {
        buffer.write(part);
      } else if (part is Map && part['text'] is String) {
        buffer.write(part['text']);
      }
    }
    return buffer.toString();
  }
  return '';
}

Future<String?> _canonicalExistingFile(String rawPath) async {
  if (rawPath.isEmpty ||
      rawPath.contains('\u0000') ||
      MarkdownMediaSanitizer.isNetworkShapedPath(rawPath)) {
    return null;
  }
  try {
    final file = File(rawPath);
    // Async probes: a misclassified network path must never block the UI
    // isolate (SMB timeouts measured 10-25s on Windows).
    if (!await file.exists()) return null;
    return await file.resolveSymbolicLinks();
  } catch (_) {
    return null;
  }
}

bool _isAllowed({
  required ResolvedToolImagePolicy policy,
  required String canonical,
  required String raw,
}) {
  // Root checks use the canonical target only: a symlink inside the workspace
  // that points outside must be rejected. The raw path is checked only against
  // the in-memory trusted ledger (an explicit user approval), never against a
  // persisted tool-event extra.
  if (policy.allowsRoot(canonical)) return true;
  final normalizedRaw = _normalize(raw);
  return policy.allowsTrusted(normalizedRaw) || policy.allowsTrusted(canonical);
}

String? _shaFor(
  Map<String, dynamic> message,
  String rawPath,
  String canonicalPath,
) {
  final raw = message['_tool_image_sha256'];
  if (raw is String && raw.trim().isNotEmpty) return raw.trim();
  if (raw is Map) {
    final byCanonical = raw[canonicalPath];
    if (byCanonical is String && byCanonical.trim().isNotEmpty) {
      return byCanonical.trim();
    }
    final byRaw = raw[rawPath];
    if (byRaw is String && byRaw.trim().isNotEmpty) return byRaw.trim();
  }
  return null;
}

String _removeMarkers(String text, List<ToolImageMarker> markers) {
  if (markers.isEmpty) return text;
  final sorted = List<ToolImageMarker>.of(markers)
    ..sort((a, b) => b.start.compareTo(a.start));
  var out = text;
  for (final marker in sorted) {
    if (marker.start < 0 || marker.end > out.length) continue;
    var start = marker.start;
    var end = marker.end;
    // If the marker occupied its own line, remove that line (including the
    // following newline). Otherwise remove only the marker span. Never run a
    // global whitespace regex: tool results can carry JSON strings whose
    // embedded newlines/trailing spaces are meaningful.
    final before = start > 0 ? out[start - 1] : '\n';
    final after = end < out.length ? out[end] : '\n';
    final ownLine =
        (before == '\n' || before == '\r') && (after == '\n' || after == '\r');
    if (ownLine) {
      while (start > 0 && (out[start - 1] == ' ' || out[start - 1] == '\t')) {
        start--;
      }
      if (end < out.length) {
        if (after == '\r' && end + 1 < out.length && out[end + 1] == '\n') {
          end += 2;
        } else {
          end += 1;
        }
      }
    }
    out = out.replaceRange(start, end, '');
  }
  return out.trim();
}

String _normalize(String path) {
  final normalized = p.normalize(path.trim()).replaceAll('\\', '/');
  // Windows paths are case-insensitive; the allow-list and ledger both use
  // this comparison form.
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

bool _isWithin(String root, String path) {
  if (root.isEmpty) return false;
  final normalizedRoot = root.endsWith('/')
      ? root.substring(0, root.length - 1)
      : root;
  if (normalizedRoot.isEmpty) return false;
  if (Platform.isWindows) {
    final r = normalizedRoot.toLowerCase();
    final candidate = path.toLowerCase();
    return candidate == r || candidate.startsWith('$r/');
  }
  return path == normalizedRoot || path.startsWith('$normalizedRoot/');
}

String _extensionFor(String mime) {
  switch (mime.toLowerCase()) {
    case 'image/jpeg':
    case 'image/jpg':
      return 'jpg';
    case 'image/png':
      return 'png';
    case 'image/webp':
      return 'webp';
    case 'image/gif':
      return 'gif';
    default:
      return 'img';
  }
}
