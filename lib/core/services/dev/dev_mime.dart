/// Minimal MIME table for the workspace dev server.
///
/// The table intentionally stays small: a preview only needs the asset types a
/// hand-written or model-generated site actually references. Anything unknown
/// is served as a binary stream (`application/octet-stream`) instead of being
/// sniffed — the browser must not execute a file because its content looked
/// like HTML.
const Map<String, String> _constMimeTypes = <String, String>{
  // Documents
  'html': 'text/html; charset=utf-8',
  'htm': 'text/html; charset=utf-8',
  'xhtml': 'application/xhtml+xml; charset=utf-8',
  'css': 'text/css; charset=utf-8',
  'js': 'text/javascript; charset=utf-8',
  'mjs': 'text/javascript; charset=utf-8',
  'cjs': 'text/javascript; charset=utf-8',
  'map': 'application/json; charset=utf-8',
  'json': 'application/json; charset=utf-8',
  'txt': 'text/plain; charset=utf-8',
  'md': 'text/markdown; charset=utf-8',
  'csv': 'text/csv; charset=utf-8',
  'tsv': 'text/tab-separated-values; charset=utf-8',
  'xml': 'application/xml; charset=utf-8',
  'svg': 'image/svg+xml',
  'yaml': 'text/yaml; charset=utf-8',
  'yml': 'text/yaml; charset=utf-8',
  'toml': 'text/plain; charset=utf-8',
  'wasm': 'application/wasm',
  'pdf': 'application/pdf',
  'webmanifest': 'application/manifest+json; charset=utf-8',
  // Images
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'avif': 'image/avif',
  'ico': 'image/x-icon',
  'bmp': 'image/bmp',
  // Fonts
  'woff': 'font/woff',
  'woff2': 'font/woff2',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  // Media
  'mp4': 'video/mp4',
  'webm': 'video/webm',
  'ogv': 'video/ogg',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'm4a': 'audio/mp4',
  'flac': 'audio/flac',
};

/// Extension of [path] (lower-case, without the dot), or an empty string.
String devFileExtension(String path) {
  final slash = path.lastIndexOf(RegExp(r'[/\\]'));
  final dot = path.lastIndexOf('.');
  if (dot <= slash || dot == path.length - 1) return '';
  return path.substring(dot + 1).toLowerCase();
}

/// Content type for [path], including `charset=utf-8` for text types.
String devContentTypeForPath(String path) {
  return _constMimeTypes[devFileExtension(path)] ?? 'application/octet-stream';
}

/// True when [path] should get the live-reload / console bridge injected.
bool devIsHtmlPath(String path) {
  final ext = devFileExtension(path);
  return ext == 'html' || ext == 'htm' || ext == 'xhtml';
}
