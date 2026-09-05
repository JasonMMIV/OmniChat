import 'dart:async';
import 'dart:convert';

import 'package:ddgs/ddgs.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_client/mcp_client.dart' as mcp;

/// image_search — In-memory MCP server engine exposing a real-photo image
/// search tool.
///
/// Purpose: let the model enrich answers with **real** images (a person's
/// photo, a product shot, a landmark) via `![alt](url)` markdown, using
/// hotlink-safe URLs without storing any file locally.
///
/// Backends (free, key-less):
///   1. DuckDuckGo image search via the bundled `ddgs` package (broad index:
///      news / general web real photos). Returns `image` (original),
///      `thumbnail` (Bing CDN proxy, ~stable), width/height and source page.
///   2. Wikimedia Commons (fallback when ddgs is empty / errors). Encyclo-
///      pedic real photos (people, landmarks, species, products) with
///      author + license metadata. Returns a `thumb` sized image on
///      `upload.wikimedia.org` which is hotlink-tolerant.
///
/// Every candidate URL is HEAD-validated (HTTP 200 + `content-type: image/*`)
/// before being returned, so dead / hotlink-protected URLs are filtered out
/// before the model ever sees them.
///
/// The server implements a minimal subset of MCP over JSON-RPC 2.0
/// (initialize, tools/list, tools/call) and runs in the same isolate via an
/// in-memory [ImageSearchInMemoryClientTransport] — works on Android, iOS,
/// desktop, and web.
class ImageSearchMcpServerEngine {
  ImageSearchMcpServerEngine({
    ImageSearchFetcher? ddgsOverride,
    http.Client? httpClient,
  })  : _ddgsOverride = ddgsOverride,
        _httpClient = httpClient;

  bool _closed = false;

  /// Optional seam for tests / future providers: replaces the real ddgs call.
  /// Signature mirrors `DDGS.images` (list of JSON maps).
  final ImageSearchFetcher? _ddgsOverride;
  final http.Client? _httpClient;

  static const String serverName = 'Image_Search';
  static const String toolName = 'image_search';

  Future<dynamic> handleMessage(dynamic message) async {
    if (_closed) return null;

    // Support batch arrays defensively (return array of responses)
    if (message is List) {
      final out = <dynamic>[];
      for (final m in message) {
        out.add(await _handleSingle(m));
      }
      return out;
    }
    return await _handleSingle(message);
  }

  Future<Map<String, dynamic>> _handleSingle(dynamic raw) async {
    try {
      if (raw is! Map) {
        return _error(null, code: -32600, message: 'Invalid Request');
      }
      final req = raw.cast<String, dynamic>();
      final id = req['id'];
      final method = (req['method'] ?? '').toString();
      final params = (req['params'] is Map)
          ? (req['params'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};

      switch (method) {
        case mcp.McpProtocol.methodInitialize:
          return _ok(id, result: {
            'serverInfo': {
              'name': serverName,
              'version': '0.1.0',
            },
            'protocolVersion': mcp.McpProtocol.defaultVersion,
            'capabilities': {
              'tools': {'listChanged': false},
            },
          });

        case mcp.McpProtocol.methodListTools:
          return _ok(id, result: {
            'tools': _toolDefinitions(),
          });

        case mcp.McpProtocol.methodCallTool:
          final name = (params['name'] ?? '').toString();
          final arguments = (params['arguments'] is Map)
              ? (params['arguments'] as Map).cast<String, dynamic>()
              : <String, dynamic>{};

          switch (name) {
            case toolName:
              return _ok(id, result: await _imageSearch(arguments));
            default:
              return _error(id, code: -32101, message: 'Tool not found: $name');
          }

        default:
          // Ignore common notifications; respond error for unknown requests
          if (id == null) {
            return _noop();
          }
          return _error(id, code: -32601, message: 'Method not found: $method');
      }
    } catch (e) {
      return _error(null, code: -32603, message: 'Internal error: $e');
    }
  }

  void close() {
    _closed = true;
  }

  Map<String, dynamic> _ok(dynamic id, {required Map<String, dynamic> result}) {
    return {
      'jsonrpc': '2.0',
      if (id != null) 'id': id,
      'result': result,
    };
  }

  Map<String, dynamic> _error(dynamic id,
      {required int code, required String message}) {
    return {
      'jsonrpc': '2.0',
      if (id != null) 'id': id,
      'error': {'code': code, 'message': message},
    };
  }

  Map<String, dynamic> _noop() => {'jsonrpc': '2.0'};

  static Map<String, dynamic> _okResult(String text) => {
        'content': [
          {'type': 'text', 'text': text}
        ],
        'isStreaming': false,
        'isError': false,
      };

  static Map<String, dynamic> _errResult(String message) => {
        'content': [
          {'type': 'text', 'text': message}
        ],
        'isStreaming': false,
        'isError': true,
      };

  static String _query(Map<String, dynamic> args) =>
      (args['query'] ?? '').toString().trim();

  // -------------------------------------------------------------------------
  // Tool implementation
  // -------------------------------------------------------------------------

  Future<Map<String, dynamic>> _imageSearch(
    Map<String, dynamic> args,
  ) async {
    try {
      final query = _query(args);
      if (query.isEmpty) return _errResult('Error: query is required.');
      final maxResults = clampImageMaxResults(args['max_results']);

      // --- Backend 1: DuckDuckGo (primary) ---
      List<Map<String, dynamic>> ddgRaw = const [];
      String? ddgError;
      try {
        ddgRaw = await _fetchDuckDuckGo(query, maxResults);
      } catch (e) {
        ddgError = e.toString();
      }

      // --- Backend 2: Wikimedia Commons (fallback only when ddgs is empty) ---
      List<Map<String, dynamic>> wikimediaRaw = const [];
      if (ddgRaw.isEmpty) {
        try {
          wikimediaRaw = await _fetchWikimedia(query, maxResults);
        } catch (_) {
          // Commons is best-effort; failure is surfaced only when no usable
          // image came from any backend.
        }
      }

      // Convert + validate. ddgs preferred; Commons fills gaps / acts as the
      // sole source when ddgs failed.
      final candidates = <ImageSearchHit>[
        for (final m in ddgRaw)
          ..._hitsFromDuckDuckGo(m),
        for (final m in wikimediaRaw)
          ..._hitsFromWikimedia(m),
      ];

      // Validate only the first few candidates (HEAD check is the slow part).
      const validateLimit = 5;
      final hits = await _validateHits(
        candidates.take(validateLimit).toList(),
      );

      if (hits.isEmpty) {
        final why = ddgRaw.isNotEmpty
            ? 'all candidates failed HTTP validation'
            : (ddgError ?? '').isNotEmpty
                ? 'DuckDuckGo failed ($ddgError)'
                : 'no results';
        return _errResult(
          'Image search failed: no usable image found ($why). '
          'Try a more specific query.',
        );
      }

      return _okResult(renderImageSearchResult(hits));
    } catch (e) {
      return _errResult('Image search failed: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _fetchDuckDuckGo(
    String query,
    int maxResults,
  ) async {
    final override = _ddgsOverride;
    if (override != null) {
      return override(query, maxResults);
    }
    final ddgs = DDGS(timeout: const Duration(seconds: 10));
    try {
      return await ddgs.images(
        query,
        maxResults: maxResults,
        safesearch: 'moderate',
        backend: 'duckduckgo',
      );
    } finally {
      ddgs.close();
    }
  }

  Future<List<Map<String, dynamic>>> _fetchWikimedia(
    String query,
    int maxResults,
  ) async {
    final client = _httpClient ?? http.Client();
    try {
      final uri = Uri.parse('https://commons.wikimedia.org/w/api.php').replace(
        queryParameters: {
          'action': 'query',
          'format': 'json',
          'formatversion': '2',
          'generator': 'search',
          'gsrsearch': query,
          'gsrnamespace': '6', // File: namespace
          'gsrlimit': '$maxResults',
          'prop': 'imageinfo',
          'iiprop': 'url|extmetadata',
          'iiurlwidth': '480', // request a thumb sized URL
        },
      );
      final resp = await client
          .get(uri)
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        throw Exception('Wikimedia API HTTP ${resp.statusCode}');
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final queryMap = data['query'];
      if (queryMap is! Map) return const [];
      final pages = queryMap['pages'];
      if (pages is! List) return const [];
      final out = <Map<String, dynamic>>[];
      for (final p in pages.whereType<Map>()) {
        final page = p.cast<String, dynamic>();
        final imageInfo = page['imageinfo'];
        if (imageInfo is! List || imageInfo.isEmpty) continue;
        final info = (imageInfo.first as Map).cast<String, dynamic>();
        out.add({
          'title': page['title'] ?? '',
          'url': info['url'] ?? '', // original file
          'thumburl': info['thumburl'] ?? '', // resized 480px
          'thumbwidth': info['thumbwidth'],
          'thumbheight': info['thumbheight'],
          'width': info['width'],
          'height': info['height'],
          'descriptionurl': info['descriptionurl'] ?? '', // Commons file page
          'extmetadata': info['extmetadata'],
        });
      }
      return out;
    } finally {
      if (_httpClient == null) client.close();
    }
  }

  /// Validate candidate image URLs with a HEAD request: accept only HTTP 200
  /// with a `content-type: image/*`. Sequential with a short per-URL timeout
  /// keeps concurrency bounded.
  Future<List<ImageSearchHit>> _validateHits(List<ImageSearchHit> candidates) async {
    final client = _httpClient ?? http.Client();
    try {
      final out = <ImageSearchHit>[];
      for (final hit in candidates) {
        final checkUrl = hit.thumbnailUrl.isNotEmpty
            ? hit.thumbnailUrl
            : hit.imageUrl;
        if (checkUrl.isEmpty) continue;
        if (!(await _isImageUrl(client, checkUrl))) continue;
        out.add(hit);
      }
      return out;
    } finally {
      if (_httpClient == null) client.close();
    }
  }

  Future<bool> _isImageUrl(http.Client client, String url) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
        return false;
      }
      final resp = await client.head(uri).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return false;
      final ct = (resp.headers['content-type'] ?? '').toLowerCase();
      return ct.startsWith('image/');
    } catch (_) {
      return false;
    }
  }

  /// Convert one ddgs image-result JSON map into hits.
  List<ImageSearchHit> _hitsFromDuckDuckGo(Map<String, dynamic> m) {
    final title = (m['title'] ?? '').toString();
    final image = (m['image'] ?? '').toString();
    final thumbnail = (m['thumbnail'] ?? '').toString();
    final width = (m['width'] ?? '').toString();
    final height = (m['height'] ?? '').toString();
    final sourceUrl = (m['url'] ?? '').toString();
    if (image.isEmpty && thumbnail.isEmpty) return const [];
    return [
      ImageSearchHit(
        title: title,
        imageUrl: image,
        thumbnailUrl: thumbnail,
        width: width,
        height: height,
        sourceUrl: sourceUrl,
        backend: 'duckduckgo',
      ),
    ];
  }

  /// Convert one Wikimedia API page map into hits.
  List<ImageSearchHit> _hitsFromWikimedia(Map<String, dynamic> m) {
    final title = (m['title'] ?? '').toString();
    final image = (m['url'] ?? '').toString();
    final thumbnail = (m['thumburl'] ?? '').toString();
    final sourceUrl = (m['descriptionurl'] ?? '').toString();

    String width = '';
    String height = '';
    final w = m['thumbwidth'];
    final h = m['thumbheight'];
    if (w is num) width = w.toInt().toString();
    if (h is num) height = h.toInt().toString();

    // extmetadata contains HTML-encoded Artist / LicenseShortName values.
    String attribution = '';
    String license = '';
    final meta = m['extmetadata'];
    if (meta is Map) {
      final mm = meta.cast<String, dynamic>();
      final artist = mm['Artist'];
      if (artist is Map) {
        attribution = _stripHtmlTags((artist['value'] ?? '').toString());
      }
      final lic = mm['LicenseShortName'];
      if (lic is Map) {
        license = _stripHtmlTags((lic['value'] ?? '').toString());
      }
    }

    if (image.isEmpty && thumbnail.isEmpty) return const [];
    return [
      ImageSearchHit(
        title: title,
        imageUrl: image,
        thumbnailUrl: thumbnail,
        width: width,
        height: height,
        sourceUrl: sourceUrl,
        attribution: attribution,
        license: license,
        backend: 'wikimedia',
      ),
    ];
  }

  String _stripHtmlTags(String s) {
    final noTags = s.replaceAll(RegExp(r'<[^>]*>'), '').trim();
    return noTags
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .trim();
  }

  List<Map<String, dynamic>> _toolDefinitions() {
    return [
      {
        'name': toolName,
        'description':
            'Search for real photographs on the web and return direct image '
            'URLs to embed in your reply as ![alt](url) markdown. Intended for '
            'illustrating concrete real-world subjects: a person, a product, a '
            'landmark, an animal, an artwork, a place, a notable object. '
            'Do NOT use for abstract concepts without a concrete referent, '
            'logos, icons, charts or stock-art filler.\n'
            'Usage rules:\n'
            '1. Call image_search with a concrete query (e.g. "Niels Bohr 1922" '
            'rather than "famous physicist").\n'
            '2. Embed the result as markdown immediately after the sentence it '
            'illustrates, e.g. ![Albert Einstein](<image_url>).\n'
            '3. Prefer thumbnail_url for embedding (faster, smaller, more '
            'reliable); the full image_url is for when the user wants to view '
            'the original.\n'
            '4. Each result carries source_url, and Wikimedia results carry '
            'author/license — mention the source when appropriate.\n'
            '5. Never invent an image URL: only use URLs returned by this tool.\n'
            '6. A maximum of 5 validated URLs are returned regardless of '
            'max_results.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description':
                  'Concrete search query for the real photo you need, e.g. '
                  '"Ada Lovelace portrait" or "iPhone 15 Pro product photo".',
            },
            'max_results': {
              'type': 'integer',
              'description': 'Maximum number of results to return (1-15, '
                  'default 10).',
            },
          },
          'required': ['query'],
        },
      },
    ];
  }
}

/// Unified internal image candidate (backend-agnostic).
class ImageSearchHit {
  final String title;
  final String imageUrl;
  final String thumbnailUrl;
  final String width;
  final String height;
  final String sourceUrl;
  final String attribution;
  final String license;
  final String backend;

  ImageSearchHit({
    required this.title,
    required this.imageUrl,
    required this.thumbnailUrl,
    this.width = '',
    this.height = '',
    this.sourceUrl = '',
    this.attribution = '',
    this.license = '',
    this.backend = '',
  });
}

/// Signature for pluggable DuckDuckGo image search (tests / providers).
typedef ImageSearchFetcher =
    Future<List<Map<String, dynamic>>> Function(String query, int maxResults);

/// Clamp the `max_results` tool argument to a safe range (1-15, default 10).
/// Accepts int, num, or stringified numbers defensively.
int clampImageMaxResults(dynamic raw) {
  int? n;
  if (raw is num) {
    n = raw.toInt();
  } else if (raw is String) {
    n = int.tryParse(raw.trim());
  }
  if (n == null) return 10;
  return n.clamp(1, 15);
}

/// Render validated hits as a compact, model-friendly JSON string with 1-based
/// indexes so the model can reference individual results.
String renderImageSearchResult(List<ImageSearchHit> hits) {
  final items = <Map<String, dynamic>>[];
  for (int i = 0; i < hits.length; i++) {
    final h = hits[i];
    items.add({
      'index': i + 1,
      'title': h.title,
      'image_url': h.imageUrl,
      'thumbnail_url': h.thumbnailUrl,
      if (h.width.isNotEmpty) 'width': h.width,
      if (h.height.isNotEmpty) 'height': h.height,
      if (h.sourceUrl.isNotEmpty) 'source_url': h.sourceUrl,
      if (h.attribution.isNotEmpty) 'author': h.attribution,
      if (h.license.isNotEmpty) 'license': h.license,
      'backend': h.backend,
    });
  }
  return jsonEncode({'items': items});
}

/// In-memory ClientTransport that directly invokes the local server engine.
class ImageSearchInMemoryClientTransport implements mcp.ClientTransport {
  final ImageSearchMcpServerEngine _server;
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  bool _closed = false;

  ImageSearchInMemoryClientTransport(this._server);

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    if (_closed) return;
    // Process asynchronously to mimic real transport
    Future.microtask(() async {
      final resp = await _server.handleMessage(message);
      if (_closed) return;
      if (resp != null) {
        _messageController.add(resp);
      }
    });
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _server.close();
    } catch (_) {}
    if (!_messageController.isClosed) _messageController.close();
    if (!_closeCompleter.isCompleted) _closeCompleter.complete();
  }
}
