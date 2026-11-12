import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import './app_directories.dart';

class MarkdownMediaSanitizer {
  static final Uuid _uuid = const Uuid();
  static final RegExp _windowsDrivePathRe =
      RegExp(r'^[A-Za-z]:[\\/]');
  static final RegExp _imgRe = RegExp(
    r'!\[[^\]]*\]\((data:image\/[a-zA-Z0-9.+-]+;base64,[a-zA-Z0-9+/=\r\n]+)\)',
    multiLine: true,
  );

  static final RegExp _angleBracketImageRe =
      RegExp(r'!\[([^\]]*)\]\(\s*<([^>]*)>\s*\)', multiLine: true);

  /// gpt_markdown 1.3.0 does not strip CommonMark angle brackets around image
  /// destinations (`![alt](<https://...>)`) and hands `<https://...>` to
  /// `NetworkImage`, which renders every such image as broken. Normalize the
  /// angle-bracket form before parsing so both new and already-persisted
  /// assistant messages display.
  static String stripImageDestinationAngleBrackets(String markdown) {
    if (!markdown.contains('](') || !markdown.contains('<')) return markdown;
    return markdown.replaceAllMapped(
      _angleBracketImageRe,
      (match) => '![${match.group(1)}](${match.group(2)})',
    );
  }

  static Future<String> replaceInlineBase64Images(String input) async {
    final markdown = stripImageDestinationAngleBrackets(input);
    // // Fast path: only proceed when it's clearly a base64 data image
    // if (!(markdown.contains('data:image/') && markdown.contains(';base64,'))) {
    //   return markdown;
    // }
    if (!markdown.contains('data:image')) return markdown;

    final matches = _imgRe.allMatches(markdown).toList();
    if (matches.isEmpty) return markdown;

    // Ensure target directory
    final dir = await AppDirectories.getImagesDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final sb = StringBuffer();
    int last = 0;
    for (final m in matches) {
      sb.write(markdown.substring(last, m.start));
      final dataUrl = m.group(1)!;
      String ext = _extFromMime(_mimeOf(dataUrl));

      // Extract base64 payload
      final b64Index = dataUrl.indexOf('base64,');
      if (b64Index < 0) {
        sb.write(markdown.substring(m.start, m.end));
        last = m.end;
        continue;
      }
      final payload = dataUrl.substring(b64Index + 7);

      // // Skip very small payloads to avoid overhead (likely tiny icons)
      // if (payload.length < 4096) {
      //   sb.write(markdown.substring(m.start, m.end));
      //   last = m.end;
      //   continue;
      // }

      // Decode in a background isolate (pure Dart decode)
      final normalized = payload.replaceAll('\n', '');
      List<int> bytes;
      try {
        bytes = await compute(_decodeBase64, normalized);
      } catch (_) {
        // Skip malformed base64 to avoid crashing streaming responses; keep original markup.
        sb.write(markdown.substring(m.start, m.end));
        last = m.end;
        continue;
      }

      // Deterministic filename by content hash to prevent duplicates
      // Same base64 -> same filename across runs
      final digest = _uuid.v5(Uuid.NAMESPACE_URL, normalized);
      final file = File('${dir.path}/img_$digest.$ext');
      if (!await file.exists()) {
        await file.writeAsBytes(bytes, flush: true);
      }

      // Replace only the URL part inside the parentheses
      final replaced = markdown.substring(m.start, m.end).replaceFirst(dataUrl, file.path);
      sb.write(replaced);
      last = m.end;
    }
    sb.write(markdown.substring(last));
    return sb.toString();
  }

  /// Whether [value] names a network location rather than a local file.
  ///
  /// Protocol-relative (`//host/path`) and UNC (`\\host\share`) paths resolve
  /// to SMB shares on Windows, where a filesystem probe (`existsSync()` and
  /// even an awaited `stat`) can stall until the SMB timeout (measured 10-25s
  /// per host). Remote `file://host/...` URIs are network locations too.
  /// Windows extended-length local paths (`\\?\C:\...`) and local
  /// `file:///C:/...` URIs stay local.
  static bool isNetworkShapedPath(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.startsWith('//')) return true;
    // Extended-length UNC (`\\?\UNC\server\share`) is still a network path.
    if (trimmed.toUpperCase().startsWith(r'\\?\UNC\')) return true;
    // Other extended-length Windows paths are local.
    if (trimmed.startsWith(r'\\?\')) return false;
    if (trimmed.startsWith(r'\\')) return true;
    if (trimmed.startsWith('file://')) {
      final uri = Uri.tryParse(trimmed);
      // A non-empty host turns the URI into a UNC/remote path.
      return uri != null && uri.host.isNotEmpty;
    }
    return false;
  }

  /// Whether [url] should be treated as a local file path. Also used by the
  /// backup attachment preflight (plan §3 Phase 2) to pick filesystem
  /// references out of chat contents.
  ///
  /// Protocol-relative (`//host/path`) and UNC (`\\host\share`) URLs are
  /// web/network locations. On Windows they resolve to SMB paths, and a
  /// synchronous existence check blocks the UI isolate until the SMB timeout
  /// (measured 10-25s per host). Remote `file://host/...` URIs are rejected
  /// for the same reason; only local absolute paths (and local `file://`
  /// URIs) are accepted.
  static bool isLikelyLocalImagePath(String url) {
    final value = url.trim();
    if (value.isEmpty) return false;
    if (value.startsWith('data:')) return false;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return false;
    }
    if (isNetworkShapedPath(value)) return false;
    if (value.startsWith('file://')) {
      final uri = Uri.tryParse(value);
      return uri != null && uri.path.isNotEmpty;
    }
    if (_windowsDrivePathRe.hasMatch(value)) return true;
    // POSIX/Android/macOS absolute path. On Windows a leading `/` is not a
    // local absolute path (it would probe the current drive root, e.g.
    // C:\front\assets\logo.png), so root-relative web paths are rejected.
    if (value.startsWith('/')) return !Platform.isWindows;
    return false;
  }

  // Replace Markdown image links pointing to local file paths with inline base64 data URLs.
  // Example: "![image](/data/user/0/.../images/xxx.png)" -> "![image](data:image/png;base64,...)"
  static Future<String> inlineLocalImagesToBase64(String input) async {
    final markdown = stripImageDestinationAngleBrackets(input);
    // Quick check: contains a Markdown image and looks like a local path
    if (!(markdown.contains('![') && markdown.contains(']('))) return markdown;

    final re = RegExp(r'!\[[^\]]*\]\(([^)]+)\)', multiLine: true);
    final matches = re.allMatches(markdown).toList();
    if (matches.isEmpty) return markdown;

    final sb = StringBuffer();
    int last = 0;
    for (final m in matches) {
      sb.write(markdown.substring(last, m.start));
      final url = (m.group(1) ?? '').trim();
      // Only convert true local file paths; remote, protocol-relative, UNC and
      // data URLs stay untouched. See [isLikelyLocalImagePath].
      final isFileUri = url.startsWith('file://');

      if (!isLikelyLocalImagePath(url)) {
        // Keep original
        sb.write(markdown.substring(m.start, m.end));
        last = m.end;
        continue;
      }

      try {
        // Resolve file:// URIs to a real path (decodes %20 and keeps Windows
        // drive letters intact). The classifier already rejected file:// URIs
        // with a remote host.
        final fixed = isFileUri ? Uri.parse(url).toFilePath() : url;
        final f = File(fixed);
        // Async existence check: even a misclassified network path must never
        // block the UI isolate.
        if (!await f.exists()) {
          // Fallback to original if missing
          sb.write(markdown.substring(m.start, m.end));
          last = m.end;
          continue;
        }
        final bytes = await f.readAsBytes();
        final b64 = base64Encode(bytes);
        final mime = _guessMimeFromPath(fixed);
        final dataUrl = 'data:$mime;base64,$b64';
        final replaced = markdown.substring(m.start, m.end).replaceFirst(url, dataUrl);
        sb.write(replaced);
      } catch (_) {
        // On failure, keep original
        sb.write(markdown.substring(m.start, m.end));
      }
      last = m.end;
    }
    sb.write(markdown.substring(last));
    return sb.toString();
  }

  static String _guessMimeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/png';
  }

  static List<int> _decodeBase64(String b64) => base64Decode(b64.replaceAll('\n', ''));

  static String _mimeOf(String dataUrl) {
    try {
      final start = dataUrl.indexOf(':');
      final semi = dataUrl.indexOf(';');
      if (start >= 0 && semi > start) {
        return dataUrl.substring(start + 1, semi);
      }
    } catch (_) {}
    return 'image/png';
  }

  static String _extFromMime(String mime) {
    switch (mime.toLowerCase()) {
      case 'image/jpeg':
      case 'image/jpg':
        return 'jpg';
      case 'image/webp':
        return 'webp';
      case 'image/gif':
        return 'gif';
      case 'image/png':
      default:
        return 'png';
    }
  }
}
