import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Prepares the local Markdown preview bundle.
///
/// The preview HTML references `vendor/...` with relative paths. Android's
/// `loadHtmlString` and Windows' temp-HTML `loadUrl` cannot reliably resolve
/// Flutter assets, so we extract the vendor files once and write each Markdown
/// preview into its own `preview_*` subdirectory (with a `../` base href).
/// Raw workspace HTML/SVG uses a separate temp directory instead. All scripts
/// are classic UMD/IIFE; no ES modules or CDN.
class MarkdownPreviewAssets {
  MarkdownPreviewAssets._();

  static final MarkdownPreviewAssets instance = MarkdownPreviewAssets._();

  /// Bump when any file under `assets/html/vendor/` changes.
  static const int bundleVersion = 1;
  static const String _vendorPrefix = 'assets/html/vendor/';
  static const String _mermaidAsset = 'assets/mermaid.min.js';
  static const String _markerName = '.ready';
  static const String _markdownEntryScript = 'vendor/markdown-it.min.js';

  static final Map<String, Future<Directory>> _extractions = <String, Future<Directory>>{};

  Directory? _directory;
  Future<Directory>? _preparing;
  int _htmlSequence = 0;

  /// Extracts the vendor bundle if needed and returns its directory.
  ///
  /// [cacheDirectory] is injectable for tests; production callers should omit
  /// it so the app temporary directory is used.
  Future<Directory> ensureExtracted({Directory? cacheDirectory}) {
    if (cacheDirectory != null) {
      return _extractions.putIfAbsent(cacheDirectory.path, () {
        final future = _extract(cacheDirectory);
        unawaited(
          future.then<void>((_) {}, onError: (_) {}).whenComplete(() => _extractions.remove(cacheDirectory.path)),
        );
        return future;
      });
    }
    final existing = _directory;
    if (existing != null) return Future<Directory>.value(existing);
    return _preparing ??= _prepareDefault().whenComplete(() {
      _preparing = null;
    });
  }

  Future<Directory> _prepareDefault() async {
    final base = await getTemporaryDirectory();
    await _deleteOldVersions(base);
    final dir = Directory('${base.path}/markdown_preview_assets_v$bundleVersion');
    final ready = await _extract(dir);
    _directory = ready;
    return ready;
  }

  Future<void> _deleteOldVersions(Directory base) async {
    try {
      await for (final entity in base.list()) {
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith('markdown_preview_assets_v')) continue;
        final version = int.tryParse(name.substring('markdown_preview_assets_v'.length));
        if (version == null || version >= bundleVersion) continue;
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<Directory> _extract(Directory dir) async {
    final marker = File('${dir.path}/$_markerName');
    final entryPoint = File('${dir.path}/$_markdownEntryScript');
    if (await marker.exists() && await entryPoint.exists()) {
      final markerVersion = (await marker.readAsString()).trim();
      if (markerVersion == '$bundleVersion') return dir;
    }

    await dir.create(recursive: true);

    var vendorAssets = 0;
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    for (final assetKey in manifest.listAssets()) {
      if (!assetKey.startsWith(_vendorPrefix)) continue;
      final relative = assetKey.substring(_vendorPrefix.length);
      if (relative.isEmpty) continue;
      await _writeAsset(assetKey, File('${dir.path}/vendor/$relative'));
      vendorAssets++;
    }
    if (vendorAssets == 0) {
      throw StateError('Markdown preview vendor assets missing; check pubspec.yaml assets.');
    }

    // Mermaid is already shipped for the in-app diagram bridge; copy it into
    // the preview directory instead of duplicating 3 MB in the Flutter bundle.
    await _writeAsset(_mermaidAsset, File('${dir.path}/vendor/mermaid.min.js'));

    await marker.writeAsString('$bundleVersion', flush: true);
    return dir;
  }

  Future<void> _writeAsset(String assetKey, File destination) async {
    final data = await rootBundle.load(assetKey);
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
  }

  /// Writes [html] into an isolated `preview_*` subdirectory of the extracted
  /// vendor root. The HTML's `<base href="../">` resolves `vendor/...`.
  ///
  /// Callers should delete the returned file when the preview closes; the
  /// shared vendor directory is intentionally kept for the next preview.
  Future<File> writeHtml(String html, {Directory? cacheDirectory}) async {
    final dir = await ensureExtracted(cacheDirectory: cacheDirectory);
    await _pruneStalePreviews(dir);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final sequence = _htmlSequence++;
    final previewDir = Directory('${dir.path}/preview_${stamp}_$sequence');
    await previewDir.create(recursive: true);
    final file = File('${previewDir.path}/index.html');
    await file.writeAsString(html, flush: true);
    return file;
  }

  /// Best-effort cleanup for preview dirs whose WebView never released them
  /// (crash/kill). Only removes entries older than a week so a long-lived
  /// preview is not yanked from under the platform webview.
  Future<void> _pruneStalePreviews(Directory root) async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      await for (final entity in root.list()) {
        if (entity is! Directory) continue;
        if (!p.basename(entity.path).startsWith('preview_')) continue;
        try {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entity.delete(recursive: true);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Writes raw/untrusted HTML into an isolated temp directory (no vendor
  /// siblings), used for workspace `.html`/`.svg` previews.
  Future<File> writeStandaloneHtml(String html, {Directory? cacheDirectory}) async {
    final base = cacheDirectory ?? await getTemporaryDirectory();
    final dir = Directory('${base.path}/omnichat_html_preview');
    await dir.create(recursive: true);
    final file = File('${dir.path}/preview_${DateTime.now().microsecondsSinceEpoch}_${_htmlSequence++}.html');
    await file.writeAsString(html, flush: true);
    return file;
  }

  /// Writes HTML intended for an external browser into an `open_*` subdir and
  /// keeps the cache bounded to one such directory. The returned file is not
  /// tracked/deleted: the browser may still be reading it after the dialog
  /// closes.
  Future<File> writeExternalHtml(String html, {Directory? cacheDirectory}) async {
    final dir = await ensureExtracted(cacheDirectory: cacheDirectory);
    try {
      await for (final entity in dir.list()) {
        final name = p.basename(entity.path);
        if (!name.startsWith('open_')) continue;
        try {
          if (entity is Directory) {
            await entity.delete(recursive: true);
          } else if (entity is File) {
            await entity.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
    final sequence = _htmlSequence++;
    final openDir = Directory('${dir.path}/open_${DateTime.now().microsecondsSinceEpoch}_$sequence');
    await openDir.create(recursive: true);
    final file = File('${openDir.path}/index.html');
    await file.writeAsString(html, flush: true);
    return file;
  }

  Future<void> deleteHtml(File? file) async {
    if (file == null) return;
    try {
      final parent = file.parent;
      if (p.basename(parent.path).startsWith('preview_')) {
        if (await parent.exists()) {
          await parent.delete(recursive: true);
          return;
        }
      }
      if (await file.exists()) await file.delete();
    } catch (_) {
      // The WebView may still hold the file briefly; temp cleanup can miss it.
    }
  }
}
