import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../file/file_tool_service.dart';
import 'dev_mime.dart';

/// One console message captured from the live preview page.
class DevConsoleEntry {
  DevConsoleEntry({
    required this.level,
    required this.message,
    this.source,
    this.line,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  /// Normalized level: `error`, `warn`, `log`, `info` or `debug`.
  final String level;

  /// Already truncated by the capture endpoint (4,000 characters).
  final String message;

  /// Page path (and query) that produced the message.
  final String? source;

  final int? line;
  final DateTime at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'level': level,
    'message': message,
    if (source != null && source!.isNotEmpty) 'source': source,
    if (line != null && line! > 0) 'line': line,
    'at': at.toIso8601String(),
  };

  static DevConsoleEntry? tryParse(dynamic value) {
    if (value is! Map) return null;
    final level = (value['level'] ?? '').toString().trim().toLowerCase();
    final message = (value['message'] ?? '').toString();
    if (message.isEmpty) return null;
    return DevConsoleEntry(
      level: _normalizeLevel(level),
      message: message.length > 4000 ? message.substring(0, 4000) : message,
      source: (value['source'] ?? '').toString(),
      line: value['line'] is num ? (value['line'] as num).toInt() : null,
    );
  }

  static String _normalizeLevel(String level) {
    switch (level) {
      case 'error':
      case 'warn':
      case 'warning':
      case 'log':
      case 'info':
      case 'debug':
        return level == 'warning' ? 'warn' : level;
      default:
        return 'log';
    }
  }
}

/// Events surfaced by a running preview session.
sealed class DevServerEvent {
  const DevServerEvent();
}

/// Fired after the workspace changed (file tools, shell runs, external edits).
class DevServerReloadEvent extends DevServerEvent {
  const DevServerReloadEvent(this.revision);
  final int revision;
}

/// Fired for every console message posted by an injected page.
class DevServerConsoleEvent extends DevServerEvent {
  const DevServerConsoleEvent(this.entry);
  final DevConsoleEntry entry;
}

/// Fired when the buffer is cleared for a reload — the page is about to run
/// again, so old errors must not masquerade as current ones.
class DevServerConsoleClearedEvent extends DevServerEvent {
  const DevServerConsoleClearedEvent();
}

/// A loopback-only static server for one workspace root.
///
/// Design contract (P2-4):
/// - Binds `127.0.0.1` on a random port; never a LAN interface.
/// - Serves the workspace tree with a small MIME table, rejects traversal,
///   symlink escapes, dotfiles and absolute paths.
/// - Injects a tiny bridge into every HTML document: live reload via SSE and
///   `console.*` / `window.onerror` capture via a POST endpoint.
/// - Keeps everything in memory — no persisted files, no port reuse.
class DevServerSession {
  DevServerSession._({required this.workspaceRoot, required HttpServer server})
    : _server = server;

  /// Canonical absolute workspace root (symlinks resolved).
  final String workspaceRoot;

  final HttpServer _server;

  final StreamController<DevServerEvent> _events =
      StreamController<DevServerEvent>.broadcast();

  final List<DevConsoleEntry> _console = <DevConsoleEntry>[];
  final Set<HttpResponse> _sseClients = <HttpResponse>{};

  StreamSubscription<FileSystemEvent>? _watchSubscription;
  Timer? _reloadDebounce;
  Timer? _heartbeat;
  bool _closed = false;
  int _revision = 0;

  /// True between a reload and the first console message of the new page;
  /// lets the tool explain an empty buffer instead of implying "no errors".
  bool _awaitingReloadConsole = false;

  static const int maxConsoleEntries = 200;
  static const int maxConsoleBodyBytes = 16 * 1024;
  static const int maxInjectedHtmlBytes = 16 * 1024 * 1024;

  /// Random loopback port assigned by the OS.
  int get port => _server.port;

  /// Origin used by the preview WebView, e.g. `http://127.0.0.1:51234`.
  String get baseUrl => 'http://127.0.0.1:$port';

  bool get isClosed => _closed;

  int get revision => _revision;

  List<DevConsoleEntry> get consoleEntries =>
      List<DevConsoleEntry>.unmodifiable(_console);

  Stream<DevServerEvent> get events => _events.stream;

  /// Absolute URL for a workspace-relative [relativePath].
  ///
  /// Empty paths and paths ending in `/` are directory URLs (trailing slash is
  /// preserved so relative asset references resolve like a normal web server).
  String urlFor(String relativePath) {
    final cleaned = relativePath.replaceAll('\\', '/');
    final segments = cleaned
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    final directory = cleaned.isEmpty || cleaned.endsWith('/');
    if (segments.isEmpty) return '$baseUrl/';
    return '$baseUrl/$segments${directory ? '/' : ''}';
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _reloadDebounce?.cancel();
    _reloadDebounce = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    try {
      await _watchSubscription?.cancel();
    } catch (_) {}
    _watchSubscription = null;
    for (final client in _sseClients.toList()) {
      try {
        await client.close();
      } catch (_) {}
    }
    _sseClients.clear();
    try {
      await _server.close(force: true);
    } catch (_) {}
    if (!_events.isClosed) await _events.close();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  static Future<DevServerSession> start({required String workspaceRoot}) async {
    final canonicalRoot = await FileToolService.prepareWorkspaceFor(
      workspaceRoot,
    );
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    final session = DevServerSession._(
      workspaceRoot: canonicalRoot,
      server: server,
    );
    session._listen();
    session._startWatcher();
    session._startHeartbeat();
    return session;
  }

  void _listen() {
    _server.listen(
      (request) => unawaited(_handle(request)),
      onError: (_) {},
      cancelOnError: false,
    );
  }

  void _startHeartbeat() {
    _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_closed) return;
      for (final client in _sseClients.toList()) {
        try {
          client.write(': ping\n\n');
          unawaited(client.flush().then<void>((_) {}, onError: (_) {}));
        } catch (_) {
          _sseClients.remove(client);
        }
      }
    });
  }

  /// Best-effort recursive watch so external edits (shell runs, editor saves)
  /// reload the page too. Explicit tool notifications are the reliable path;
  /// the watcher is a bonus and may be unavailable on some platforms.
  void _startWatcher() {
    try {
      _watchSubscription = Directory(workspaceRoot)
          .watch(recursive: true)
          .listen(
            (event) {
              if (_isNoisePath(event.path)) return;
              scheduleReload();
            },
            onError: (_) {},
            cancelOnError: false,
          );
    } catch (_) {
      _watchSubscription = null;
    }
  }

  /// Directories whose churn must not reload the preview (`npm install`,
  /// git operations, build caches). Explicit tool notifications still fire.
  static bool _isNoisePath(String filePath) {
    final normalized = filePath.replaceAll('\\', '/');
    const noisy = <String>[
      '/.git/',
      '/node_modules/',
      '/.dart_tool/',
      '/build/',
      '/.omnichat/',
      '/coverage/',
    ];
    return noisy.any(normalized.contains);
  }

  /// Debounced reload notification (used by file watchers and tool results).
  void scheduleReload() {
    if (_closed) return;
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 250), bumpRevision);
  }

  /// Immediate reload notification; exported for tests and direct UI actions.
  ///
  /// The console buffer is cleared here on purpose: after a file change the
  /// page is about to rerun, so `get_console_errors` must not keep returning
  /// the previous revision's errors (the model would think its fix failed).
  void bumpRevision() {
    if (_closed) return;
    _revision++;
    _console.clear();
    _awaitingReloadConsole = true;
    if (!_events.isClosed) _events.add(const DevServerConsoleClearedEvent());
    _broadcastReload();
    if (!_events.isClosed) _events.add(DevServerReloadEvent(_revision));
  }

  void _broadcastReload() {
    for (final client in _sseClients.toList()) {
      try {
        client.write('event: reload\ndata: $_revision\n\n');
        unawaited(client.flush().then<void>((_) {}, onError: (_) {}));
      } catch (_) {
        _sseClients.remove(client);
      }
    }
  }

  void _recordConsole(DevConsoleEntry entry) {
    if (_closed) return;
    _awaitingReloadConsole = false;
    _console.add(entry);
    if (_console.length > maxConsoleEntries) {
      _console.removeRange(0, _console.length - maxConsoleEntries);
    }
    if (!_events.isClosed) _events.add(DevServerConsoleEvent(entry));
  }

  /// Drops the captured console buffer (UI "clear" action / tests).
  void clearConsole() {
    _console.clear();
  }

  /// Model-facing JSON for the `get_console_errors` tool.
  String consoleErrorsJson({String levels = 'errors', int limit = 20}) {
    return buildConsoleErrorsJson(
      entries: _console,
      levels: levels,
      limit: limit,
      running: true,
      revision: _revision,
      awaitingReload: _awaitingReloadConsole,
    );
  }

  /// Pure JSON builder so the tool contract is testable without a server.
  static String buildConsoleErrorsJson({
    required List<DevConsoleEntry> entries,
    required String levels,
    required int limit,
    bool running = true,
    int revision = 0,
    bool awaitingReload = false,
  }) {
    final normalizedLevels = levels.trim().toLowerCase();
    final wanted = switch (normalizedLevels) {
      'all' => 'all',
      'warn' || 'warning' || 'warnings' => 'warn',
      _ => 'error',
    };
    final clampedLimit = limit.clamp(1, 100);
    bool matches(DevConsoleEntry entry) {
      if (wanted == 'all') return true;
      return entry.level == wanted;
    }

    final filtered = entries.where(matches).toList();
    final start = filtered.length > clampedLimit
        ? filtered.length - clampedLimit
        : 0;
    final visible = filtered.sublist(start);

    final counts = <String, int>{
      'error': 0,
      'warn': 0,
      'log': 0,
      'info': 0,
      'debug': 0,
    };
    for (final entry in entries) {
      counts[entry.level] = (counts[entry.level] ?? 0) + 1;
    }
    final total = entries.length;

    final payload = <String, dynamic>{
      'type': 'console_errors',
      'running': running,
      'revision': revision,
      'levels': wanted,
      'counts': <String, dynamic>{
        'error': counts['error'] ?? 0,
        'warn': counts['warn'] ?? 0,
        'log':
            (counts['log'] ?? 0) +
            (counts['info'] ?? 0) +
            (counts['debug'] ?? 0),
        'total': total,
      },
      'returned': visible.length,
      'omitted': filtered.length - visible.length,
      'entries': [for (final entry in visible) entry.toJson()],
    };
    if (visible.isEmpty) {
      if (total == 0 && awaitingReload) {
        payload['note'] =
            'The preview reloaded (revision $revision) and has not reported '
            'any console messages yet. The page may still be starting — wait '
            'a moment, then call this tool again.';
      } else {
        payload['note'] = total == 0
            ? 'No console messages captured yet. Reload the preview after reproducing the issue.'
            : 'No ${wanted == 'all' ? '' : '$wanted '}messages captured. '
                  'Use levels:"all" to include logs, or reload the preview.';
      }
    }
    return jsonEncode(payload);
  }

  // ---------------------------------------------------------------------------
  // HTTP handling
  // ---------------------------------------------------------------------------

  bool _isAllowedHost(String? host) {
    if (host == null || host.isEmpty) return true;
    final normalized = host.trim().toLowerCase();
    return normalized == '127.0.0.1:$port' ||
        normalized == 'localhost:$port' ||
        normalized == '[::1]:$port';
  }

  bool _isSameOrigin(HttpRequest request) {
    final origin = request.headers.value('origin');
    if (origin == null || origin.trim().isEmpty) return true;
    final uri = Uri.tryParse(origin.trim());
    if (uri == null || uri.scheme != 'http') return false;
    return _isAllowedHost(uri.authority);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      // DNS-rebinding guard: a foreign Origin/Host must never reach the
      // workspace tree, even though the socket is loopback-only.
      if (!_isAllowedHost(request.headers.value(HttpHeaders.hostHeader))) {
        await _writeText(request, HttpStatus.forbidden, 'Forbidden host.');
        return;
      }
      final path = request.uri.path;
      if (path == '/__omnichat/console') {
        if (request.method != 'POST') {
          await _writeText(request, HttpStatus.methodNotAllowed, 'POST only.');
          return;
        }
        await _handleConsolePost(request);
        return;
      }
      if (path == '/__omnichat/reload') {
        if (request.method != 'GET') {
          await _writeText(request, HttpStatus.methodNotAllowed, 'GET only.');
          return;
        }
        await _handleSse(request);
        return;
      }
      if (path.startsWith('/__omnichat/')) {
        await _writeText(request, HttpStatus.notFound, 'Unknown endpoint.');
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        await _writeText(
          request,
          HttpStatus.methodNotAllowed,
          'Read-only preview server.',
        );
        return;
      }
      await _serveStatic(request);
    } catch (_) {
      try {
        await _writeText(
          request,
          HttpStatus.internalServerError,
          'Preview server error.',
        );
      } catch (_) {}
    }
  }

  Future<void> _handleConsolePost(HttpRequest request) async {
    if (!_isSameOrigin(request)) {
      await _writeText(request, HttpStatus.forbidden, 'Forbidden origin.');
      return;
    }
    if (request.contentLength > maxConsoleBodyBytes) {
      await _writeText(
        request,
        HttpStatus.requestEntityTooLarge,
        'Console payload too large.',
      );
      return;
    }
    // Bounded read: a chunked request has no contentLength, so a local
    // process could otherwise stream unbounded data into memory.
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request) {
      bytes.add(chunk);
      if (bytes.length > maxConsoleBodyBytes) {
        await _writeText(
          request,
          HttpStatus.requestEntityTooLarge,
          'Console payload too large.',
        );
        return;
      }
    }
    final body = utf8.decode(bytes.takeBytes(), allowMalformed: true);
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      await _writeText(request, HttpStatus.badRequest, 'Invalid JSON.');
      return;
    }
    final entry = DevConsoleEntry.tryParse(decoded);
    if (entry == null) {
      await _writeText(request, HttpStatus.badRequest, 'Missing message.');
      return;
    }
    _recordConsole(entry);
    await _writeText(request, HttpStatus.noContent, '');
  }

  Future<void> _handleSse(HttpRequest request) async {
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.bufferOutput = false;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'text/event-stream; charset=utf-8',
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
    response.write('retry: 1000\n\n');
    response.write('event: hello\ndata: $_revision\n\n');
    await response.flush();
    _sseClients.add(response);
    // `done` completes with an error when the client drops mid-stream; consume
    // it explicitly so the preview never leaks an unhandled async error.
    unawaited(
      response.done.then<void>(
        (_) => _sseClients.remove(response),
        onError: (_) => _sseClients.remove(response),
      ),
    );
  }

  Future<void> _serveStatic(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    for (final segment in segments) {
      // `.` / `..` never reach the resolver; backslashes and NUL bytes would
      // be separator/terminator ambiguities on Windows.
      if (segment == '.' || segment == '..') {
        await _writeText(request, HttpStatus.forbidden, 'Forbidden path.');
        return;
      }
      // A decoded `%2F` can smuggle a separator into a segment; `:` is an
      // alternate-data-stream separator on Windows.
      if (segment.contains('/') ||
          segment.contains('\\') ||
          segment.contains('\u0000') ||
          (Platform.isWindows && segment.contains(':'))) {
        await _writeText(request, HttpStatus.forbidden, 'Forbidden path.');
        return;
      }
      // Dotfiles (.env, .git/config, .well-known/…) stay invisible to the
      // preview. Secret files must never be reachable from a page.
      if (segment.length > 1 && segment.startsWith('.')) {
        await _writeText(request, HttpStatus.notFound, 'Not found.');
        return;
      }
    }
    final cleanSegments = segments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    final relative = cleanSegments.join('/');
    String resolved;
    try {
      resolved = FileToolService.resolveSafePath(relative, workspaceRoot);
    } on FileToolSecurityException {
      await _writeText(request, HttpStatus.forbidden, 'Forbidden path.');
      return;
    } catch (_) {
      await _writeText(request, HttpStatus.notFound, 'Not found.');
      return;
    }

    final type = FileSystemEntity.typeSync(resolved, followLinks: true);
    if (type == FileSystemEntityType.directory) {
      if (!request.uri.path.endsWith('/')) {
        request.response.statusCode = HttpStatus.movedTemporarily;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '${request.uri.path}/',
        );
        await request.response.close();
        return;
      }
      final index = _findIndexFile(resolved);
      if (index != null) {
        await _serveFile(request, index);
        return;
      }
      final html = _directoryListingHtml(Directory(resolved), cleanSegments);
      await _writeHtml(request, html);
      return;
    }
    if (type == FileSystemEntityType.file) {
      await _serveFile(request, File(resolved));
      return;
    }
    await _writeText(request, HttpStatus.notFound, 'Not found.');
  }

  File? _findIndexFile(String directoryPath) {
    for (final name in const <String>['index.html', 'index.htm']) {
      final candidate = File(p.join(directoryPath, name));
      if (candidate.existsSync()) return candidate;
    }
    return null;
  }

  Future<void> _serveFile(HttpRequest request, File file) async {
    final length = await file.length();
    final contentType = devContentTypeForPath(file.path);
    final injectable =
        devIsHtmlPath(file.path) && length <= maxInjectedHtmlBytes;
    if (injectable) {
      final bytes = await file.readAsBytes();
      final html = utf8.decode(bytes, allowMalformed: true);
      await _writeHtml(request, injectBridge(html));
      return;
    }
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.set(HttpHeaders.contentTypeHeader, contentType);
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.contentLength = length;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    await response.addStream(file.openRead());
    await response.close();
  }

  Future<void> _writeHtml(HttpRequest request, String html) async {
    final body = utf8.encode(html);
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'text/html; charset=utf-8',
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.contentLength = body.length;
    if (request.method != 'HEAD') response.add(body);
    await response.close();
  }

  Future<void> _writeText(HttpRequest request, int status, String text) async {
    final body = utf8.encode(text);
    final response = request.response;
    response.statusCode = status;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'text/plain; charset=utf-8',
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.contentLength = body.length;
    if (request.method != 'HEAD' && status != HttpStatus.noContent) {
      response.add(body);
    }
    await response.close();
  }

  // ---------------------------------------------------------------------------
  // HTML bridge + directory listing
  // ---------------------------------------------------------------------------

  /// Injects the live-reload / console bridge as early as possible so errors
  /// thrown by head scripts are still captured.
  static String injectBridge(String html) {
    // `<head(?:\s…)?>` — a bare `<head[^>]*>` also matches `<header>`.
    final head = RegExp(
      r'<head(?:\s[^>]*)?>',
      caseSensitive: false,
    ).firstMatch(html);
    if (head != null) {
      return html.replaceRange(head.end, head.end, _devBridgeScript);
    }
    final htmlTag = RegExp(
      r'<html(?:\s[^>]*)?>',
      caseSensitive: false,
    ).firstMatch(html);
    if (htmlTag != null) {
      return html.replaceRange(
        htmlTag.end,
        htmlTag.end,
        '<head>$_devBridgeScript</head>',
      );
    }
    final doctype = RegExp(
      r'<!doctype[^>]*>',
      caseSensitive: false,
    ).firstMatch(html);
    if (doctype != null) {
      return html.replaceRange(doctype.end, doctype.end, _devBridgeScript);
    }
    return '$_devBridgeScript$html';
  }

  String _directoryListingHtml(Directory directory, List<String> segments) {
    // Display uses decoded names; hrefs must re-encode every segment so a
    // folder named `x y` / `100%` / `a#b` still links correctly.
    final displayBase = '/${segments.join('/')}${segments.isEmpty ? '' : '/'}';
    final encodedSegments = segments.map(Uri.encodeComponent).toList();
    final encodedBase =
        '/${encodedSegments.join('/')}${encodedSegments.isEmpty ? '' : '/'}';
    final entries = <FileSystemEntity>[];
    try {
      entries.addAll(directory.listSync(followLinks: false));
    } catch (_) {}
    entries.sort((a, b) {
      final aDir =
          FileSystemEntity.typeSync(a.path, followLinks: false) ==
          FileSystemEntityType.directory;
      final bDir =
          FileSystemEntity.typeSync(b.path, followLinks: false) ==
          FileSystemEntityType.directory;
      if (aDir != bDir) return aDir ? -1 : 1;
      return p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase());
    });
    final buffer = StringBuffer();
    buffer.writeln('<!doctype html><html><head><meta charset="utf-8"/>');
    buffer.writeln(
      '<meta name="viewport" content="width=device-width, initial-scale=1"/>',
    );
    buffer.writeln(
      '<style>body{font-family:system-ui,-apple-system,Segoe UI,sans-serif;'
      'margin:0;padding:24px;background:#0f1115;color:#e6e6e6}'
      'h1{font-size:16px;font-weight:600;margin:0 0 16px}'
      'ul{list-style:none;margin:0;padding:0}'
      'li{margin:2px 0}a{color:#8ab4ff;text-decoration:none;'
      'display:block;padding:6px 8px;border-radius:6px}'
      'a:hover{background:rgba(138,180,255,.12)}'
      '.dir{color:#ffd479}.meta{color:#8b93a1;font-size:12px;margin-top:16px}'
      '</style></head><body>',
    );
    buffer.writeln('<h1>${_escapeHtml(displayBase)}</h1><ul>');
    if (encodedSegments.isNotEmpty) {
      final parent = encodedSegments.length <= 1
          ? '/'
          : '/${encodedSegments.sublist(0, encodedSegments.length - 1).join('/')}/';
      buffer.writeln('<li><a href="${_escapeHtml(parent)}">../</a></li>');
    }
    const limit = 500;
    var shown = 0;
    for (final entity in entries) {
      if (shown >= limit) break;
      final name = p.basename(entity.path);
      if (name.length > 1 && name.startsWith('.')) continue;
      final isDir =
          FileSystemEntity.typeSync(entity.path, followLinks: false) ==
          FileSystemEntityType.directory;
      final href =
          '$encodedBase${Uri.encodeComponent(name)}${isDir ? '/' : ''}';
      buffer.writeln(
        '<li><a class="${isDir ? 'dir' : ''}" href="${_escapeHtml(href)}">'
        '${_escapeHtml(name)}${isDir ? '/' : ''}</a></li>',
      );
      shown++;
    }
    buffer.writeln('</ul>');
    if (entries.length > limit) {
      buffer.writeln('<p class="meta">Showing the first $limit entries.</p>');
    }
    buffer.writeln(
      '<p class="meta">Served by OmniChat site preview. '
      'Relative CSS, JS and images resolve from the workspace root.</p>',
    );
    buffer.writeln('</body></html>');
    return injectBridge(buffer.toString());
  }

  static String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }
}

/// Process-wide owner of the single active preview session.
///
/// A preview panel attaches on open and releases on close; the server never
/// outlives the panel (zero-residue contract).
class DevServerService {
  DevServerService._();

  static final DevServerService instance = DevServerService._();

  DevServerSession? _active;

  /// Open panels holding the session. The socket closes with the last lease;
  /// a second preview host must not yank the server from under the first.
  int _leases = 0;

  /// Single-flight guard: two panels opening together must not both bind and
  /// leak one socket.
  Future<DevServerSession>? _starting;

  DevServerSession? get activeSession => _active;

  Future<DevServerSession> start({required String workspaceRoot}) async {
    final canonicalRoot = await FileToolService.prepareWorkspaceFor(
      workspaceRoot,
    );
    final pending = _starting;
    if (pending != null) {
      // A failed concurrent start must not fail this caller: re-evaluate
      // `_active` and let this call retry independently.
      try {
        await pending;
      } catch (_) {}
    }
    final existing = _active;
    if (existing != null &&
        !existing.isClosed &&
        _samePath(existing.workspaceRoot, canonicalRoot)) {
      _leases++;
      return existing;
    }
    // Set the single-flight future synchronously (no await between the check
    // and the assignment) so a concurrent caller cannot start a second bind.
    final future = _startFresh(canonicalRoot);
    _starting = future;
    try {
      return await future;
    } finally {
      if (identical(_starting, future)) _starting = null;
    }
  }

  Future<DevServerSession> _startFresh(String canonicalRoot) async {
    await _forceStop();
    final session = await DevServerSession.start(workspaceRoot: canonicalRoot);
    _active = session;
    _leases = 1;
    return session;
  }

  /// Releases one lease (or force-closes when [session] is null).
  Future<void> stop([DevServerSession? session]) async {
    final current = _active;
    if (current == null) return;
    if (session == null) {
      await _forceStop();
      return;
    }
    if (!identical(session, current)) return;
    if (_leases > 1) {
      _leases--;
      return;
    }
    await _forceStop();
  }

  Future<void> _forceStop() async {
    final current = _active;
    _active = null;
    _leases = 0;
    await current?.close();
  }

  /// Called after a tool mutated the workspace so the open preview reloads.
  void notifyWorkspaceChanged([String? workspaceRoot]) {
    final session = _active;
    if (session == null || session.isClosed) return;
    if (workspaceRoot != null &&
        workspaceRoot.trim().isNotEmpty &&
        !_samePath(session.workspaceRoot, workspaceRoot)) {
      return;
    }
    session.scheduleReload();
  }

  static bool _samePath(String a, String b) {
    final na = p.normalize(a).replaceAll('\\', '/');
    final nb = p.normalize(b).replaceAll('\\', '/');
    if (Platform.isWindows) return na.toLowerCase() == nb.toLowerCase();
    return na == nb;
  }
}

/// The tiny script injected into every served HTML document.
const String _devBridgeScript = r'''
<script data-omnichat-dev-bridge="1">
(function () {
  if (window.__omnichatDevBridge) return;
  window.__omnichatDevBridge = true;
  function fmt(value) {
    try {
      if (typeof value === 'string') return value;
      if (value instanceof Error) return value.stack || (value.name + ': ' + value.message);
      var json = JSON.stringify(value);
      return json === undefined ? String(value) : json;
    } catch (error) {
      return String(value);
    }
  }
  function send(level, parts) {
    try {
      var text = Array.prototype.map.call(parts, fmt).join(' ');
      if (text.length > 4000) text = text.slice(0, 4000) + '\u2026';
      fetch('/__omnichat/console', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          level: level,
          message: text,
          source: location.pathname + location.search
        })
      });
    } catch (error) {}
  }
  ['error', 'warn', 'log', 'info', 'debug'].forEach(function (level) {
    var original = console[level];
    console[level] = function () {
      send(level, arguments);
      if (original) original.apply(console, arguments);
    };
  });
  window.addEventListener('error', function (event) {
    send('error', [
      event.message,
      event.filename ? (event.filename + ':' + event.lineno + ':' + event.colno) : ''
    ]);
  });
  window.addEventListener('unhandledrejection', function (event) {
    send('error', ['Unhandled promise rejection:', event.reason]);
  });
  try {
    var source = new EventSource('/__omnichat/reload');
    source.addEventListener('reload', function () { location.reload(); });
  } catch (error) {}
})();
</script>
''';
