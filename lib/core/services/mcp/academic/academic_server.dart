import 'dart:async';
import 'dart:convert';

import 'package:mcp_client/mcp_client.dart' as mcp;
import '../../../providers/settings_provider.dart';
import '../../search/search_service.dart';
import '../../search/providers/pubmed_search_service.dart';
import '../../search/providers/arxiv_search_service.dart';
import '../../search/providers/semantic_scholar_search_service.dart';

/// Runtime bridge so the pure-Dart academic MCP server can read the user's
/// standalone academic config (PubMed / Semantic Scholar API keys) without a
/// BuildContext — [McpProvider] is a plain ChangeNotifier with no context.
///
/// Attached once from `MyApp` after the provider tree is ready; lookups read
/// `settings.academicConfig` lazily at each tool call, so edits made later in
/// the Academic_Search MCP server settings are picked up automatically.
class AcademicSearchOptionsResolver {
  static SettingsProvider? _settings;

  /// Wire the resolver to the app's [SettingsProvider]. Pass null to detach
  /// (used by tests to reset the static reference between cases).
  static void attach(SettingsProvider? settings) {
    _settings = settings;
  }

  /// Return the standalone academic config, or a default (all-empty) config
  /// when not attached (callers then use key-less mode, which still works for
  /// all three providers).
  static AcademicMcpConfig config() {
    try {
      return _settings?.academicConfig ?? const AcademicMcpConfig();
    } catch (_) {
      return const AcademicMcpConfig();
    }
  }

  /// The configured timeout (ms) for academic searches, falling back to 15s.
  /// Reuses the global web-search timeout from [SettingsProvider].
  static int get timeoutMs {
    try {
      return _settings?.searchCommonOptions.timeout ?? 15000;
    } catch (_) {
      return 15000;
    }
  }
}

/// Clamp the `max_results` tool argument to a safe range (1-15, default 10).
/// Accepts int, num, or stringified numbers defensively.
int clampAcademicMaxResults(dynamic raw) {
  int? n;
  if (raw is num) {
    n = raw.toInt();
  } else if (raw is String) {
    n = int.tryParse(raw.trim());
  }
  if (n == null) return 10;
  return n.clamp(1, 15);
}

/// Collapse whitespace and cap a single result snippet (abstract text can be
/// long; keep token usage bounded).
String _truncateSnippet(String s, int max) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.length <= max) return t;
  return '${t.substring(0, max)}…';
}

/// Render a [SearchResult] as a compact, model-friendly JSON string with
/// 1-based indexes so the model can cite individual results.
String renderAcademicSearchResult(String source, SearchResult result) {
  final items = <Map<String, dynamic>>[];
  for (int i = 0; i < result.items.length; i++) {
    final it = result.items[i];
    items.add({
      'index': i + 1,
      'title': it.title,
      'url': it.url,
      'snippet': _truncateSnippet(it.text, 800),
      if (it.id != null && it.id!.isNotEmpty) 'id': it.id,
    });
  }
  return jsonEncode({'source': source, 'items': items});
}  /// academic — In-memory MCP server engine exposing academic search tools
  /// (PubMed / arXiv / Semantic Scholar).
///
/// The server implements a minimal subset of MCP over JSON-RPC 2.0
/// (initialize, tools/list, tools/call) and runs in the same isolate as the
/// app via an in-memory [AcademicInMemoryClientTransport] — works on Android,
/// iOS, desktop, and web. It reuses the existing search service providers
/// (PubMed / arXiv / Semantic Scholar) with the user's configured options.
class AcademicMcpServerEngine {
  bool _closed = false;

  static const String serverName = 'Academic_Search';

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
            case 'pubmed_search':
              return _ok(id, result: await _searchPubMed(arguments));
            case 'arxiv_search':
              return _ok(id, result: await _searchArxiv(arguments));
            case 'semantic_scholar_search':
              return _ok(
                id,
                result: await _searchSemanticScholar(arguments),
              );
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

  // ---------------------------------------------------------------------------
  // Tool implementations (reuse the existing search service providers)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _searchPubMed(
    Map<String, dynamic> args,
  ) async {
    try {
      final query = _query(args);
      if (query.isEmpty) return _errResult('Error: query is required.');
      final svc = PubmedSearchService();
      final cfg = AcademicSearchOptionsResolver.config();
      final opts = PubMedOptions(
        id: 'default',
        apiKey: cfg.pubmedApiKey,
        tool: cfg.pubmedTool,
        email: cfg.pubmedEmail,
      );
      final result = await svc.search(
        query: query,
        commonOptions: SearchCommonOptions(
          resultSize: clampAcademicMaxResults(args['max_results']),
          timeout: AcademicSearchOptionsResolver.timeoutMs,
        ),
        serviceOptions: opts,
      );
      return _okResult(renderAcademicSearchResult('PubMed', result));
    } catch (e) {
      return _errResult('PubMed search failed: $e');
    }
  }

  Future<Map<String, dynamic>> _searchArxiv(Map<String, dynamic> args) async {
    try {
      final query = _query(args);
      if (query.isEmpty) return _errResult('Error: query is required.');
      final svc = ArxivSearchService();
      final opts = ArxivOptions(id: 'default');
      final result = await svc.search(
        query: query,
        commonOptions: SearchCommonOptions(
          resultSize: clampAcademicMaxResults(args['max_results']),
          timeout: AcademicSearchOptionsResolver.timeoutMs,
        ),
        serviceOptions: opts,
      );
      return _okResult(renderAcademicSearchResult('arXiv', result));
    } catch (e) {
      return _errResult('arXiv search failed: $e');
    }
  }

  Future<Map<String, dynamic>> _searchSemanticScholar(
    Map<String, dynamic> args,
  ) async {
    try {
      final query = _query(args);
      if (query.isEmpty) return _errResult('Error: query is required.');
      final svc = SemanticScholarSearchService();
      final cfg = AcademicSearchOptionsResolver.config();
      final opts = SemanticScholarOptions(
        id: 'default',
        apiKey: cfg.semanticScholarApiKey,
      );
      final result = await svc.search(
        query: query,
        commonOptions: SearchCommonOptions(
          resultSize: clampAcademicMaxResults(args['max_results']),
          timeout: AcademicSearchOptionsResolver.timeoutMs,
        ),
        serviceOptions: opts,
      );
      return _okResult(renderAcademicSearchResult('Semantic Scholar', result));
    } catch (e) {
      return _errResult('Semantic Scholar search failed: $e');
    }
  }

  List<Map<String, dynamic>> _toolDefinitions() {
    Map<String, dynamic> schema({required String queryDesc}) => {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': queryDesc},
            'max_results': {
              'type': 'integer',
              'description': 'Maximum number of results to return (1-15, '
                  'default 10).',
            },
          },
          'required': ['query'],
        };

    return [
      {
        'name': 'pubmed_search',
        'description':
            'Search PubMed (NCBI E-utilities) for biomedical and life-sciences '
            'literature: medicine, health, biology, pharmacology, clinical '
            'trials, genomics. Returns PMIDs with title, abstract snippet, '
            'journal, year and PubMed URL. Use when the question involves '
            'biomedical or clinical research.',
        'inputSchema': schema(
          queryDesc:
              'Biomedical literature query, e.g. "metformin diabetes" or '
              '"CRISPR sickle cell therapy".',
        ),
      },
      {
        'name': 'arxiv_search',
        'description':
            'Search arXiv for preprints in physics, mathematics, computer '
            'science, quantitative biology, quantitative finance and '
            'statistics. Returns title, abstract snippet, category, year and '
            'abstract page URL. Note: arXiv allows at most 1 request per '
            '3 seconds.',
        'inputSchema': schema(
          queryDesc:
              'arXiv query, e.g. "transformer attention" or "quantum error '
              'correction".',
        ),
      },
      {
        'name': 'semantic_scholar_search',
        'description':
            'Search Semantic Scholar (Academic Graph API) for academic papers '
            'across all disciplines. Returns title, abstract, venue, year, '
            'citation count, and paper URL, including open-access PDF when '
            'available.',
        'inputSchema': schema(
          queryDesc:
              'Academic paper query, e.g. "large language models reasoning" '
              'or "graph neural networks".',
        ),
      },
    ];
  }
}

/// In-memory ClientTransport that directly invokes the local server engine.
class AcademicInMemoryClientTransport implements mcp.ClientTransport {
  final AcademicMcpServerEngine _server;
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  bool _closed = false;

  AcademicInMemoryClientTransport(this._server);

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
