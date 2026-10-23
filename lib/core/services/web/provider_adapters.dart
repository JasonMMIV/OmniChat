// Tier-2 provider extract adapters (WEB_FETCH_PLAN.md §5.10).
//
// One declarative table instead of N near-identical `fetch()` methods: each
// entry only declares its endpoint, body, headers and response paths.

import 'dart:convert';

import '../search/search_service.dart';

typedef ProviderUriBuilder = Uri Function(
  String url,
  SearchServiceOptions options,
);
typedef ProviderHeadersBuilder =
    Map<String, String> Function(SearchServiceOptions options);
typedef ProviderBodyBuilder =
    Map<String, dynamic> Function(String url, SearchServiceOptions options);

class ProviderFetchAdapter {
  const ProviderFetchAdapter({
    required this.type,
    required this.displayName,
    this.method = 'POST',
    required this.uriBuilder,
    required this.headersBuilder,
    this.bodyBuilder,
    required this.contentExtractor,
    this.titleExtractor,
    this.plainTextResponse = false,
  });

  /// `SearchServiceOptions.toJson()['type']`.
  final String type;
  final String displayName;
  final String method;
  final ProviderUriBuilder uriBuilder;
  final ProviderHeadersBuilder headersBuilder;
  final ProviderBodyBuilder? bodyBuilder;
  final String Function(dynamic payload) contentExtractor;
  final String Function(dynamic payload)? titleExtractor;

  /// Jina Reader answers with Markdown text, everything else with JSON.
  final bool plainTextResponse;
}

/// Returns the adapter for a provider [type], or null when the provider has
/// no extract API.
ProviderFetchAdapter? providerFetchAdapterFor(String type) =>
    _adapters[type];

List<ProviderFetchAdapter> get providerFetchAdapters =>
    List<ProviderFetchAdapter>.unmodifiable(_adapters.values);

/// Replaces the trailing [searchPath] of [searchUrl] with [fetchPath].
///
/// Returns null when the URL does not end with [searchPath] — custom gateways
/// with an unexpected shape are simply treated as "no Tier 2 support", never
/// as an error.
Uri? siblingFetchEndpoint(
  String searchUrl,
  String searchPath,
  String fetchPath,
) {
  final trimmed = searchUrl.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  final path = uri.path;
  if (!path.endsWith(searchPath)) return null;
  final nextPath = '${path.substring(0, path.length - searchPath.length)}'
      '$fetchPath';
  return uri.replace(path: nextPath);
}

String _apiKey(SearchServiceOptions options) {
  final dynamic value = options;
  try {
    final key = value.apiKey;
    return key is String ? key.trim() : '';
  } catch (_) {
    return '';
  }
}

Map<String, String> _jsonHeaders(SearchServiceOptions options) => {
  'Content-Type': 'application/json',
  if (_apiKey(options).isNotEmpty)
    'Authorization': 'Bearer ${_apiKey(options)}',
};

dynamic _walk(dynamic payload, String path) {
  dynamic current = payload;
  for (final part in path.split('.')) {
    if (current is Map) {
      current = current[part];
    } else if (current is List) {
      final index = int.tryParse(part);
      if (index == null || index < 0 || index >= current.length) return null;
      current = current[index];
    } else {
      return null;
    }
  }
  return current;
}

String _firstString(dynamic payload, List<String> paths) {
  for (final path in paths) {
    final value = _walk(payload, path);
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return '';
}

Uri _tavilyUri(String url, SearchServiceOptions options) =>
    Uri.parse('https://api.tavily.com/extract');

Uri _exaUri(String url, SearchServiceOptions options) =>
    Uri.parse('https://api.exa.ai/contents');

Uri _firecrawlUri(String url, SearchServiceOptions options) {
  final base = options is FirecrawlOptions && options.url.trim().isNotEmpty
      ? options.url.trim()
      : FirecrawlOptions.defaultUrl;
  return siblingFetchEndpoint(base, '/search', '/scrape') ??
      Uri.parse('https://api.firecrawl.dev/v2/scrape');
}

Uri _jinaUri(String url, SearchServiceOptions options) =>
    Uri.parse('https://r.jina.ai/$url');

Uri _linkupUri(String url, SearchServiceOptions options) =>
    Uri.parse('https://api.linkup.so/v1/fetch');

Uri _metasoUri(String url, SearchServiceOptions options) =>
    Uri.parse('https://metaso.cn/api/v1/reader');

Uri _queritUri(String url, SearchServiceOptions options) =>
    Uri.parse('https://api.querit.ai/v1/fetch');

Uri _tinyfishUri(String url, SearchServiceOptions options) =>
    Uri.https('api.search.tinyfish.ai', '/fetch', {'url': url});

Uri _ollamaUri(String url, SearchServiceOptions options) =>
    Uri.parse('https://ollama.com/api/web_fetch');

Map<String, dynamic> _urlBody(String url, SearchServiceOptions options) => {
  'url': url,
};

final Map<String, ProviderFetchAdapter> _adapters =
    <String, ProviderFetchAdapter>{
      'tavily': ProviderFetchAdapter(
        type: 'tavily',
        displayName: 'Tavily',
        uriBuilder: _tavilyUri,
        headersBuilder: _jsonHeaders,
        bodyBuilder: (url, options) => {
          'urls': <String>[url],
          'extract_depth': 'basic',
        },
        contentExtractor: (payload) => _firstString(payload, [
          'results.0.raw_content',
          'results.0.content',
        ]),
        titleExtractor: (payload) =>
            _firstString(payload, ['results.0.title']),
      ),
      'exa': ProviderFetchAdapter(
        type: 'exa',
        displayName: 'Exa',
        uriBuilder: _exaUri,
        headersBuilder: _jsonHeaders,
        bodyBuilder: (url, options) => {
          'urls': <String>[url],
          'text': true,
        },
        contentExtractor: (payload) =>
            _firstString(payload, ['results.0.text', 'results.0.content']),
        titleExtractor: (payload) =>
            _firstString(payload, ['results.0.title']),
      ),
      'firecrawl': ProviderFetchAdapter(
        type: 'firecrawl',
        displayName: 'Firecrawl',
        uriBuilder: _firecrawlUri,
        headersBuilder: _jsonHeaders,
        bodyBuilder: (url, options) => {
          'url': url,
          'formats': <String>['markdown'],
          'onlyMainContent': true,
        },
        contentExtractor: (payload) => _firstString(payload, [
          'data.markdown',
          'data.content',
          'markdown',
        ]),
        titleExtractor: (payload) =>
            _firstString(payload, ['data.metadata.title', 'metadata.title']),
      ),
      'jina': ProviderFetchAdapter(
        type: 'jina',
        displayName: 'Jina',
        method: 'GET',
        plainTextResponse: true,
        uriBuilder: _jinaUri,
        headersBuilder: (options) => {
          'Accept': 'text/plain',
          if (_apiKey(options).isNotEmpty)
            'Authorization': 'Bearer ${_apiKey(options)}',
        },
        contentExtractor: (payload) => payload is String ? payload : '',
      ),
      'linkup': ProviderFetchAdapter(
        type: 'linkup',
        displayName: 'LinkUp',
        uriBuilder: _linkupUri,
        headersBuilder: _jsonHeaders,
        bodyBuilder: (url, options) => {
          'url': url,
          'extractDepth': 'standard',
        },
        contentExtractor: (payload) => _firstString(payload, [
          'markdown',
          'content',
          'data.markdown',
          'data.content',
        ]),
        titleExtractor: (payload) =>
            _firstString(payload, ['title', 'data.title']),
      ),
      'metaso': ProviderFetchAdapter(
        type: 'metaso',
        displayName: 'Metaso',
        uriBuilder: _metasoUri,
        headersBuilder: _jsonHeaders,
        bodyBuilder: _urlBody,
        contentExtractor: (payload) => _firstString(payload, [
          'data.text',
          'data.content',
          'text',
          'content',
          'raw_content',
        ]),
      ),
      'querit': ProviderFetchAdapter(
        type: 'querit',
        displayName: 'Querit',
        uriBuilder: _queritUri,
        headersBuilder: _jsonHeaders,
        bodyBuilder: _urlBody,
        contentExtractor: (payload) => _firstString(payload, [
          'data.content',
          'data.text',
          'content',
          'text',
        ]),
      ),
      'tinyfish': ProviderFetchAdapter(
        type: 'tinyfish',
        displayName: 'Tinyfish',
        method: 'GET',
        uriBuilder: _tinyfishUri,
        headersBuilder: (options) => {
          if (_apiKey(options).isNotEmpty) 'X-API-Key': _apiKey(options),
        },
        contentExtractor: (payload) => _firstString(payload, [
          'content',
          'data.content',
          'text',
        ]),
      ),
      'ollama': ProviderFetchAdapter(
        type: 'ollama',
        displayName: 'Ollama',
        uriBuilder: _ollamaUri,
        headersBuilder: _jsonHeaders,
        bodyBuilder: _urlBody,
        contentExtractor: (payload) => _firstString(payload, [
          'content',
          'data.content',
          'text',
        ]),
      ),
    };

/// Encodes [body] for the adapter's request.
String encodeAdapterBody(Map<String, dynamic> body) => jsonEncode(body);
