import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'package:html2md/html2md.dart' as html2md;
import 'package:mcp_client/mcp_client.dart' as mcp;

/// @kelivo/fetch — In-memory MCP server engine and transport (Flutter/Dart)
///
/// Provides four tools:
/// - fetch_html     → returns raw HTML text
/// - fetch_markdown → HTML converted to Markdown
/// - fetch_txt      → plain text (script/style removed, whitespace collapsed)
/// - fetch_json     → JSON stringified
///
/// The server implements a minimal subset of MCP over JSON-RPC 2.0:
/// initialize, tools/list, tools/call. It is intended to run in the same
/// isolate as the Flutter app and connect to a standard mcp.Client via an
/// in-memory ClientTransport.

class KelivoFetchRequestPayload {
  final Uri url;
  final Map<String, String> headers;

  KelivoFetchRequestPayload({required this.url, Map<String, String>? headers})
      : headers = headers ?? const {};

  static KelivoFetchRequestPayload parse(Object? args) {
    if (args is! Map) {
      throw ArgumentError('Invalid arguments: expected object with url[, headers]');
    }
    final map = args.cast<String, dynamic>();
    final urlRaw = (map['url'] ?? '').toString().trim();
    final uri = Uri.tryParse(urlRaw);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw ArgumentError('Invalid url: $urlRaw');
    }
    final headersAny = map['headers'];
    final headers = <String, String>{};
    if (headersAny is Map) {
      headersAny.forEach((k, v) {
        if (k == null || v == null) return;
        headers[k.toString()] = v.toString();
      });
    }
    return KelivoFetchRequestPayload(url: uri, headers: headers);
  }
}

class KelivoFetcher {
  static const _defaultUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// Maximum download size for a single fetch (2 MB).
  static const int _maxDownloadBytes = 2 * 1024 * 1024;

  /// Pre-clean HTML by stripping memory-heavy, unnecessary elements before
  /// DOM parsing or Markdown conversion. This can shrink raw HTML by 70–90%.
  static String _preCleanHtml(String html) {
    var cleaned = html;
    cleaned = cleaned.replaceAll(
        RegExp(r'<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>',
            caseSensitive: false),
        '');
    cleaned = cleaned.replaceAll(
        RegExp(r'<style\b[^<]*(?:(?!<\/style>)<[^<]*)*<\/style>',
            caseSensitive: false),
        '');
    cleaned = cleaned.replaceAll(
        RegExp(r'<head\b[^<]*(?:(?!<\/head>)<[^<]*)*<\/head>',
            caseSensitive: false),
        '');
    cleaned = cleaned.replaceAll(
        RegExp(r'<noscript\b[^<]*(?:(?!<\/noscript>)<[^<]*)*<\/noscript>',
            caseSensitive: false),
        '');
    cleaned = cleaned.replaceAll(
        RegExp(r'<svg\b[^<]*(?:(?!<\/svg>)<[^<]*)*<\/svg>',
            caseSensitive: false),
        '');
    cleaned = cleaned.replaceAll(
        RegExp(r'<iframe\b[^<]*(?:(?!<\/iframe>)<[^<]*)*<\/iframe>',
            caseSensitive: false),
        '');
    // Strip large inline data URIs (base64 images, etc.)
    cleaned = cleaned.replaceAll(
        RegExp(r"""src=["']data:[^"']*["']"""),
        'src=""');
    return cleaned;
  }

  /// Fetch with size limiting — reads the response stream chunk by chunk and
  /// throws if the body exceeds [_maxDownloadBytes].
  static Future<String> _fetchWithLimit(KelivoFetchRequestPayload payload) async {
    final merged = <String, String>{
      'User-Agent': _defaultUA,
      ...payload.headers,
    };
    final req = http.Request('GET', payload.url)..headers.addAll(merged);
    final client = http.Client();
    try {
      final streamed = await client.send(req);
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        throw Exception('HTTP ${streamed.statusCode}');
      }
      final builder = <int>[];
      await for (final chunk in streamed.stream) {
        builder.addAll(chunk);
        if (builder.length > _maxDownloadBytes) {
          throw Exception(
              'Response exceeded ${_maxDownloadBytes ~/ (1024 * 1024)}MB download limit');
        }
      }
      return utf8.decode(builder, allowMalformed: true);
    } finally {
      client.close();
    }
  }

  static Future<Map<String, dynamic>> html(KelivoFetchRequestPayload payload) async {
    try {
      final text = await _fetchWithLimit(payload);
      return _ok(text);
    } catch (e) {
      return _err(e.toString());
    }
  }

  static Future<Map<String, dynamic>> json(KelivoFetchRequestPayload payload) async {
    try {
      final raw = await _fetchWithLimit(payload);
      final dynamic data = jsonDecode(raw);
      return _ok(const JsonEncoder.withIndent('  ').convert(data));
    } catch (e) {
      return _err(e.toString());
    }
  }

  static Future<Map<String, dynamic>> txt(KelivoFetchRequestPayload payload) async {
    try {
      final html = _preCleanHtml(await _fetchWithLimit(payload));
      final dom.Document document = html_parser.parse(html);
      document.querySelectorAll('script,style').forEach((el) => el.remove());
      final text = document.body?.text ?? '';
      final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      return _ok(normalized);
    } catch (e) {
      return _err(e.toString());
    }
  }

  static Future<Map<String, dynamic>> markdown(KelivoFetchRequestPayload payload) async {
    try {
      final html = _preCleanHtml(await _fetchWithLimit(payload));
      final md = html2md.convert(html);
      return _ok(md);
    } catch (e) {
      return _err(e.toString());
    }
  }

  static Map<String, dynamic> _ok(String text) => {
        'content': [
          {'type': 'text', 'text': text}
        ],
        'isStreaming': false,
        'isError': false,
      };

  static Map<String, dynamic> _err(String message) => {
        'content': [
          {'type': 'text', 'text': message}
        ],
        'isStreaming': false,
        'isError': true,
      };
}

/// Minimal JSON-RPC server for MCP that serves @kelivo/fetch tools.
class KelivoFetchMcpServerEngine {
  bool _closed = false;

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
              'name': '@kelivo/fetch',
              'version': '0.1.0',
            },
            'protocolVersion': mcp.McpProtocol.defaultVersion,
            // Only tools capability is advertised for this minimal server
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

          KelivoFetchRequestPayload payload;
          try {
            payload = KelivoFetchRequestPayload.parse(arguments);
          } catch (e) {
            return _ok(id, result: KelivoFetcher._err(e.toString()));
          }

          if (name == 'fetch_html') {
            return _ok(id, result: await KelivoFetcher.html(payload));
          }
          if (name == 'fetch_markdown') {
            return _ok(id, result: await KelivoFetcher.markdown(payload));
          }
          if (name == 'fetch_txt') {
            return _ok(id, result: await KelivoFetcher.txt(payload));
          }
          if (name == 'fetch_json') {
            return _ok(id, result: await KelivoFetcher.json(payload));
          }
          return _error(id, code: -32101, message: 'Tool not found: $name');

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

  Map<String, dynamic> _error(dynamic id, {required int code, required String message}) {
    return {
      'jsonrpc': '2.0',
      if (id != null) 'id': id,
      'error': {'code': code, 'message': message},
    };
  }

  Map<String, dynamic> _noop() => {'jsonrpc': '2.0'};

  List<Map<String, dynamic>> _toolDefinitions() {
    Map<String, dynamic> schema() => {
          'type': 'object',
          'properties': {
            'url': {'type': 'string', 'description': 'URL of the website to fetch'},
            'headers': {'type': 'object', 'description': 'Optional headers to include in the request'},
          },
          'required': ['url']
        };

    return [
      {
        'name': 'fetch_html',
        'description': 'Fetch a website and return the content as HTML',
        'inputSchema': schema(),
      },
      {
        'name': 'fetch_markdown',
        'description': 'Fetch a website and return the content as Markdown',
        'inputSchema': schema(),
      },
      {
        'name': 'fetch_txt',
        'description': 'Fetch a website, return the content as plain text (no HTML)',
        'inputSchema': schema(),
      },
      {
        'name': 'fetch_json',
        'description': 'Fetch a JSON file from a URL',
        'inputSchema': schema(),
      },
    ];
  }
}

/// In-memory ClientTransport that directly invokes the local server engine.
class KelivoInMemoryClientTransport implements mcp.ClientTransport {
  final KelivoFetchMcpServerEngine _server;
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  bool _closed = false;

  KelivoInMemoryClientTransport(this._server);

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
