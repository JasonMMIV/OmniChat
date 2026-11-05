import 'dart:io';
import 'package:http/http.dart' as http;
import './app_directories.dart';

class AvatarCache {
  AvatarCache._();

  static final Map<String, String?> _memo = <String, String?>{};
  static final Map<String, Future<String?>> _inFlight =
      <String, Future<String?>>{};
  static final Map<String, DateTime> _negativeUntil = <String, DateTime>{};

  /// Negative results are retried after a short TTL instead of being cached
  /// for the lifetime of the process (temporary network failures).
  static const Duration _negativeTtl = Duration(seconds: 30);

  static void clearMemory() {
    _memo.clear();
    _inFlight.clear();
    _negativeUntil.clear();
  }

  static Future<Directory> _cacheDir() async {
    return await AppDirectories.getAvatarCacheDirectory();
  }

  static String _safeName(String url) {
    // Use 64-bit FNV-1a hash to avoid collisions from common URL prefixes
    int h = 0xcbf29ce484222325; // FNV offset basis
    const int prime = 0x100000001b3; // FNV prime
    for (final c in url.codeUnits) {
      h ^= c;
      h = (h * prime) & 0xFFFFFFFFFFFFFFFF; // keep 64-bit
    }
    final hex = h.toRadixString(16).padLeft(16, '0');
    // Attempt to keep a reasonable extension (may help some platforms)
    final uri = Uri.tryParse(url);
    String ext = 'img';
    if (uri != null) {
      final seg = uri.pathSegments.isNotEmpty ? uri.pathSegments.last.toLowerCase() : '';
      final m = RegExp(r"\.(png|jpg|jpeg|webp|gif|bmp|ico)").firstMatch(seg);
      if (m != null) ext = m.group(1)!;
    }
    return 'av_$hex.$ext';
  }

  /// Ensures avatar at [url] is cached locally and returns the file path.
  /// On failure, returns null.
  static Future<String?> getPath(String url) async {
    if (url.isEmpty) return null;
    final inFlight = _inFlight[url];
    if (inFlight != null) return inFlight;
    final retryAfter = _negativeUntil[url];
    if (retryAfter != null) {
      if (DateTime.now().isBefore(retryAfter)) return null;
      _negativeUntil.remove(url);
    }
    final future = _resolve(url);
    _inFlight[url] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[url], future)) _inFlight.remove(url);
    }
  }

  static Future<String?> _resolve(String url) async {
    if (_memo.containsKey(url)) {
      final cached = _memo[url];
      if (cached == null) return null;
      try {
        final f = File(cached);
        if (await f.exists()) return cached;
      } catch (_) {}
      // Stale entry: file was deleted; re-resolve.
      _memo.remove(url);
    }
    try {
      final dir = await _cacheDir();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final name = _safeName(url);
      final file = File('${dir.path}/$name');
      if (await file.exists()) {
        _memo[url] = file.path;
        return file.path;
      }
      // Download and save
      final res = await http.get(Uri.parse(url));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        await file.writeAsBytes(res.bodyBytes, flush: true);
        _memo[url] = file.path;
        return file.path;
      }
    } catch (_) {}
    _negativeUntil[url] = DateTime.now().add(_negativeTtl);
    return null;
  }

  static Future<void> evict(String url) async {
    _negativeUntil.remove(url);
    try {
      final dir = await _cacheDir();
      if (!await dir.exists()) return;
      final name = _safeName(url);
      final file = File('${dir.path}/$name');
      if (await file.exists()) await file.delete();
    } catch (_) {}
    _memo.remove(url);
  }
}
