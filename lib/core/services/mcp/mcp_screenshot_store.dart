import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../../utils/app_directories.dart';

/// P3-1 browser QA: persists base64 image content returned by MCP tools
/// (e.g. Playwright `browser_take_screenshot`) under the app-private cache
/// directory so the tool card can render what the model saw.
///
/// Zero-residue ruling (plan §0.2): nothing is written into the user's
/// workspace — screenshots live in `<cache>/mcp_screenshots/` and are pruned
/// to the newest [maxKept] files on every write.
abstract final class McpScreenshotStore {
  McpScreenshotStore._();

  /// How many screenshots to keep before pruning the oldest.
  static const int maxKept = 40;

  /// The app-private cache directory that holds MCP screenshots. Exposed so
  /// the Stage 2 tool-image planner can allow-list exactly this root.
  static Future<Directory> directory() async {
    return Directory(
      '${(await AppDirectories.getCacheDirectory()).path}/mcp_screenshots',
    );
  }

  static String _extensionFor(String mimeType) {
    switch (mimeType) {
      case 'image/jpeg':
      case 'image/jpg':
        return 'jpg';
      case 'image/webp':
        return 'webp';
      case 'image/gif':
        return 'gif';
      default:
        return 'png';
    }
  }

  /// Decodes [base64Data] and writes it into [into] (defaults to the app
  /// cache's `mcp_screenshots` folder). Returns the absolute file path, or
  /// null when the payload is not decodable / the write fails — screenshots
  /// are best-effort and must never break the tool result.
  static Future<String?> save({
    required String mimeType,
    required String base64Data,
    Directory? into,
  }) async {
    if (base64Data.trim().isEmpty) return null;
    final Uint8List bytes;
    try {
      bytes = base64.decode(base64Data.trim());
    } catch (_) {
      return null;
    }
    if (bytes.isEmpty) return null;
    try {
      final dir = into ?? await directory();
      await dir.create(recursive: true);
      final name =
          'mcp_shot_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1 << 32)}.${_extensionFor(mimeType)}';
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes, flush: true);
      unawaited(prune(into: into));
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Deletes the oldest screenshots beyond [keep] (best-effort; ignores
  /// missing directories and individual failures — including files that a
  /// concurrent prune already deleted between listing and stat).
  static Future<void> prune({int keep = maxKept, Directory? into}) async {
    try {
      final dir = into ?? await directory();
      if (!await dir.exists()) return;
      final entries = <(File, DateTime)>[];
      for (final entry in dir.listSync(followLinks: false)) {
        if (entry is! File) continue;
        try {
          entries.add((entry, entry.lastModifiedSync()));
        } catch (_) {}
      }
      if (entries.length <= keep) return;
      entries.sort((a, b) => b.$2.compareTo(a.$2));
      for (final (file, _) in entries.skip(keep)) {
        try {
          await file.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
