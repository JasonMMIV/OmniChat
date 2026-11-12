// Tool-result image codec (file_view_image Stage 2).
//
// Decodes a workspace image, bakes EXIF orientation, downscales it to the
// protocol's effective vision size and re-encodes it so every transport gets
// a predictable, bounded payload. Pure Dart (dart:io + package:image) so it
// can be unit-tested without Flutter bindings.
//
// Design notes:
//   - Images are re-encoded (never forwarded byte-for-byte) to strip EXIF
//     metadata and to bound the wire size. Alpha images keep PNG; opaque
//     images use JPEG q90 for a much smaller payload.
//   - The encoder is deterministic: same input + same target produce the same
//     bytes. This keeps Claude prompt-cache prefixes stable across rounds.
//   - A small in-memory LRU caches encoded payloads; the key includes the
//     file's mtime and size so edits naturally invalidate the entry.

import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Wire target that will carry the image.
enum ToolImageTarget { claude, responses, gemini, openAiChat }

extension ToolImageTargetLimits on ToolImageTarget {
  /// Encoded payload ceiling per image. Claude's documented API limit is 5 MB;
  /// the other native targets use the same ceiling. Chat Completions' synthetic
  /// user-message path is kept slightly tighter (4 MB).
  int get maxEncodedBytes => switch (this) {
    ToolImageTarget.claude => 5 * 1024 * 1024,
    ToolImageTarget.responses => 5 * 1024 * 1024,
    ToolImageTarget.gemini => 5 * 1024 * 1024,
    ToolImageTarget.openAiChat => 4 * 1024 * 1024,
  };

  /// Claude resizes images whose long edge exceeds 1568 px anyway; sending a
  /// larger image only burns upload bandwidth/tokens. OpenAI and Gemini use a
  /// 2048 px long edge, which keeps UI text legible.
  int get maxLongestEdge => switch (this) {
    ToolImageTarget.claude => 1568,
    _ => 2048,
  };

  int get maxImagesPerToolMessage => 4;

  /// Chat Completions only carries the tail group as a synthetic user message;
  /// keep it small. The native transports allow 8 images per request.
  int get maxImagesPerRequest => switch (this) {
    ToolImageTarget.openAiChat => 4,
    _ => 8,
  };
}

/// Result of decoding/resizing/encoding one image.
class ToolImageEncoded {
  const ToolImageEncoded({
    required this.bytes,
    required this.mime,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final String mime;
  final int width;
  final int height;

  int get byteLength => bytes.length;
}

/// Structured, non-fatal codec failure. The caller turns [code] into a
/// Stage 2 degrade (keep the text marker) — never into a failed turn.
class ToolImageCodecException implements Exception {
  const ToolImageCodecException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'ToolImageCodecException($code): $message';
}

/// In-memory LRU for encoded tool images.
///
/// This is intentionally process-local and bounded: image bytes are never
/// persisted. The key includes target + path + mtime + size, so a changed file
/// or a different transport cannot reuse a stale payload.
abstract final class ToolImageCache {
  ToolImageCache._();

  static const int maxEntries = 24;
  static const int maxBytes = 32 * 1024 * 1024;

  static final LinkedHashMap<String, ToolImageEncoded> _entries =
      LinkedHashMap<String, ToolImageEncoded>();
  static int _bytes = 0;

  static ToolImageEncoded? get(String key) {
    final value = _entries.remove(key);
    if (value == null) return null;
    // Re-insert to mark it as most recently used.
    _entries[key] = value;
    return value;
  }

  static void put(String key, ToolImageEncoded value) {
    // A single oversized payload can never fit the byte budget; caching it
    // would evict everything else without improving the next call.
    if (value.byteLength > maxBytes) return;
    final previous = _entries.remove(key);
    if (previous != null) _bytes -= previous.byteLength;
    _entries[key] = value;
    _bytes += value.byteLength;
    while (_entries.length > maxEntries ||
        (_bytes > maxBytes && _entries.length > 1)) {
      final oldestKey = _entries.keys.first;
      final oldest = _entries.remove(oldestKey);
      if (oldest != null) _bytes -= oldest.byteLength;
    }
  }

  static void clear() {
    _entries.clear();
    _bytes = 0;
  }
}

/// Decodes, resizes and re-encodes tool-result images.
class ToolImageCodec {
  const ToolImageCodec();

  /// Raw input ceiling before decoding (the file tools use 10 MB; MCP images
  /// may be a little larger). Bounded to keep memory predictable.
  static const int defaultMaxRawBytes = 12 * 1024 * 1024;

  Future<ToolImageEncoded> normalize({
    required String path,
    required ToolImageTarget target,
    int maxRawBytes = defaultMaxRawBytes,
  }) async {
    final file = File(path);
    final FileStat stat;
    try {
      stat = await file.stat();
    } catch (_) {
      throw const ToolImageCodecException(
        'image_not_found',
        'The image file could not be read.',
      );
    }
    if (stat.type != FileSystemEntityType.file) {
      throw const ToolImageCodecException(
        'image_not_found',
        'The image path is not a regular file.',
      );
    }
    if (stat.size <= 0) {
      throw const ToolImageCodecException(
        'image_unsupported_format',
        'The image file is empty.',
      );
    }
    if (stat.size > maxRawBytes) {
      throw ToolImageCodecException(
        'image_too_large',
        'The image is larger than ${maxRawBytes ~/ (1024 * 1024)} MB.',
      );
    }

    final normalizedPath = p.normalize(path);
    final cacheKey =
        '${normalizedPath.replaceAll('\\', '/')}|'
        '${stat.modified.millisecondsSinceEpoch}|${stat.size}|${target.name}';
    final cached = ToolImageCache.get(cacheKey);
    if (cached != null) return cached;

    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      throw const ToolImageCodecException(
        'image_not_found',
        'The image file could not be read.',
      );
    }

    final encoded = await _normalizeBytes(bytes, target);
    ToolImageCache.put(cacheKey, encoded);
    return encoded;
  }

  Future<ToolImageEncoded> _normalizeBytes(
    Uint8List bytes,
    ToolImageTarget target,
  ) async {
    // Decoding/resizing a 10 MB photo can take a noticeable amount of CPU.
    // Isolate.run keeps the UI responsive on native platforms. If isolates
    // are unavailable (web) or the transfer fails, fall back to the same
    // synchronous path.
    try {
      final result = await Isolate.run(
        () => _normalizeImageBytes(bytes, target),
      );
      return ToolImageEncoded(
        bytes: result.$1,
        mime: result.$2,
        width: result.$3,
        height: result.$4,
      );
    } on ToolImageCodecException {
      rethrow;
    } catch (_) {
      final result = _normalizeImageBytes(bytes, target);
      return ToolImageEncoded(
        bytes: result.$1,
        mime: result.$2,
        width: result.$3,
        height: result.$4,
      );
    }
  }
}

/// Top-level so it can run in an isolate. Returns a sendable record.
(Uint8List, String, int, int) _normalizeImageBytes(
  Uint8List bytes,
  ToolImageTarget target,
) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    throw const ToolImageCodecException(
      'image_unsupported_format',
      'The image format is not supported.',
    );
  }
  if (decoded == null) {
    throw const ToolImageCodecException(
      'image_unsupported_format',
      'The image format is not supported.',
    );
  }

  var image = decoded;
  try {
    image = img.bakeOrientation(image);
  } catch (_) {
    // Orientation metadata is best-effort; a decode failure below still
    // catches truly unusable images.
  }

  image = _downscaleTo(image, target.maxLongestEdge);
  var quality = 90;
  while (true) {
    final Uint8List encoded;
    try {
      encoded = image.hasAlpha
          ? img.encodePng(image)
          : img.encodeJpg(image, quality: quality);
    } catch (_) {
      throw const ToolImageCodecException(
        'image_encode_failed',
        'The image could not be re-encoded.',
      );
    }
    if (encoded.length <= target.maxEncodedBytes) {
      return (
        encoded,
        image.hasAlpha ? 'image/png' : 'image/jpeg',
        image.width,
        image.height,
      );
    }

    // PNG has no quality knob; go straight to downscaling for alpha images.
    if (!image.hasAlpha && quality > 60) {
      quality -= 10;
      continue;
    }
    final longest = math.max(image.width, image.height);
    if (longest <= 768) {
      throw ToolImageCodecException(
        'image_too_large',
        'The image could not be reduced below '
            '${target.maxEncodedBytes ~/ (1024 * 1024)} MB.',
      );
    }
    final nextEdge = math.max(768, (longest * 0.75).round());
    image = _downscaleTo(image, nextEdge);
    quality = 80;
  }
}

img.Image _downscaleTo(img.Image image, int maxEdge) {
  final longest = math.max(image.width, image.height);
  if (longest <= maxEdge || longest <= 0) return image;
  final scale = maxEdge / longest;
  final width = math.max(1, (image.width * scale).round());
  final height = math.max(1, (image.height * scale).round());
  return img.copyResize(
    image,
    width: width,
    height: height,
    interpolation: img.Interpolation.average,
  );
}
