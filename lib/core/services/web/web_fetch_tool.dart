// Single built-in web fetch tool (WEB_FETCH_PLAN.md §5.1–5.9, §5.14).
//
// Public name: `web_fetch`. Legacy names are accepted by the handler's name
// resolver only — they are never registered as tools.
//
// One entry point, two intents: readable content (raw=false) or the exact
// server response (raw=true). Local first; provider extract is an explicit,
// billable upgrade.

import 'dart:convert';
import 'dart:math' as math;

import '../../providers/settings_provider.dart';
import '../network/dio_http_client.dart';
import 'fetch_cache.dart';
import 'fetch_core.dart';
import 'fetch_source_service.dart';
import 'provider_adapters.dart';
import 'ssrf_guard.dart';

class WebFetchToolResult {
  const WebFetchToolResult({
    required this.text,
    required this.source,
    required this.sourceName,
    this.escalated = false,
    this.escalationError,
  });

  final String text;
  final String source;
  final String sourceName;
  final bool escalated;
  final String? escalationError;
}

class WebFetchTool {
  WebFetchTool({
    required SettingsProvider settings,
    FetchCore? core,
    FetchSourceService? sourceService,
    FetchCache? cache,
  }) : _settings = settings,
       _core = core,
       _sourceService = sourceService ?? FetchSourceService(),
       _cache = cache ?? sharedCache;

  static const String toolName = 'web_fetch';
  static const int defaultMaxLength = 5000;
  static const int maximumMaxLength = 20000;

  /// Process-wide cache (TTL / capacity are part of the cache itself).
  static final FetchCache sharedCache = FetchCache();

  /// Legacy handler names → `web_fetch`. Never exposed in tool definitions.
  static const Map<String, String> aliases = <String, String>{
    'read_page': toolName,
    'fetch_url': toolName,
    'fetch_html': toolName,
    'fetch_markdown': toolName,
    'fetch_txt': toolName,
    'fetch_json': toolName,
  };

  /// Returns the canonical handler name for [name].
  static String canonicalToolName(String name) => aliases[name] ?? name;

  static Map<String, dynamic> getToolDefinition() {
    Map<String, dynamic> param(
      String type,
      String description, {
      Map<String, dynamic>? properties,
      List<String>? required,
      List<dynamic>? enumValues,
    }) => <String, dynamic>{
      'type': type,
      'description': description,
      if (properties != null) 'properties': properties,
      if (required != null) 'required': required,
      if (enumValues != null) 'enum': enumValues,
    };

    return <String, dynamic>{
      'type': 'function',
      'function': {
        'name': toolName,
        'description':
            'Fetch a URL over HTTP and return its content.\n\n'
            'Default behaviour (raw=false) reads a web page and returns its main content as\n'
            'Markdown: scripts, navigation, headers, footers and other boilerplate are\n'
            'removed, the response charset is honoured (UTF-8, Big5, GBK, Shift-JIS), and\n'
            'the result includes the page title and metadata. Long pages are returned in\n'
            'windows; when the response contains next_start_index, call again with that\n'
            'value as start_index to continue.\n\n'
            'Use raw=true only when you need the exact bytes the server returned (debugging,\n'
            'source inspection). Use method=POST with a body only when the user explicitly\n'
            'asks you to call an API endpoint. Use selector to restrict extraction to a CSS\n'
            'selector.\n\n'
            'Safety rules that always apply:\n'
            '- Requests with a custom header, a body, raw=true, or a selector are fetched\n'
            '  locally only: they are never cached, never sent to a third-party reader, and\n'
            '  never rendered by a browser engine.\n'
            '- POST requests cannot be continued with start_index (that would repeat a\n'
            '  request that may have side effects).\n'
            '- Only http:// and https:// URLs are supported. Private, loopback, and\n'
            '  link-local addresses are refused unless the user enabled them in settings.\n'
            '- Only fetch URLs that already appear in the conversation: given by the user or\n'
            '  returned by search_web or a previous web_fetch.',
        'parameters': {
          'type': 'object',
          'properties': {
            'url': param('string', 'Complete http/https URL to fetch.'),
            'method': param(
              'string',
              'HTTP method. POST must be enabled in settings.',
              enumValues: <String>['GET', 'POST'],
            ),
            'headers': param(
              'object',
              'Optional request headers.',
              properties: {
                'authorization': param('string', 'Authorization header value.'),
                'cookie': param('string', 'Cookie header value.'),
                'accept': param('string', 'Accept header value.'),
                'accept-language': param('string', 'Accept-Language value.'),
                'referer': param('string', 'Referer header value.'),
              },
            ),
            'body': param(
              'string',
              'Request body. Only valid with method=POST. Pass JSON as a string.',
            ),
            'raw': param(
              'boolean',
              'true returns the exact server response instead of extracted content.',
            ),
            'selector': param(
              'string',
              'CSS selector limiting extraction. Only valid with raw=false.',
            ),
            'max_length': param(
              'integer',
              'Maximum characters returned in this call (1–20000, default 5000).',
            ),
            'start_index': param(
              'integer',
              'Character offset to continue from (default 0). Not valid with POST.',
            ),
          },
          'required': <String>['url'],
        },
      },
    };
  }

  final SettingsProvider _settings;
  FetchCore? _core;
  final FetchSourceService _sourceService;
  final FetchCache _cache;

  FetchCore get _localCore => _core ??= _buildCore();

  FetchCore _buildCore() {
    final guard = SsrfGuard(allowPrivateHosts: _settings.webFetchAllowPrivateHosts);
    if (_settings.globalProxyEnabled) {
      final port = int.tryParse(_settings.globalProxyPort) ?? 0;
      final host = _settings.globalProxyHost.trim();
      if (host.isNotEmpty && port > 0) {
        final client = DioHttpClient(
          proxy: NetworkProxyConfig(
            enabled: true,
            host: host,
            port: port,
            username: _settings.globalProxyUsername.trim().isEmpty
                ? null
                : _settings.globalProxyUsername.trim(),
            password: _settings.globalProxyPassword.isEmpty
                ? null
                : _settings.globalProxyPassword,
          ),
        );
        return FetchCore(client: client, guard: guard);
      }
    }
    return FetchCore(guard: guard);
  }

  /// Executes one tool call and returns the text handed to the model.
  ///
  /// [invokedName] lets the legacy `fetch_html` alias keep its raw-HTML
  /// semantics without registering a second tool.
  Future<String> execute(
    Map<String, dynamic> args, {
    String? invokedName,
  }) async {
    final outcome = await executeWithTrace(args, invokedName: invokedName);
    return outcome.text;
  }

  Future<WebFetchToolResult> executeWithTrace(
    Map<String, dynamic> args, {
    String? invokedName,
  }) async {
    _Args parsed;
    try {
      parsed = _Args.parse(
        args,
        defaultRaw: invokedName == 'fetch_html',
      );
    } on _ToolFailure catch (failure) {
      return _failure(failure);
    }

    final policy = _Policy.from(parsed);

    if (parsed.method == 'POST' && !_settings.webFetchAllowPost) {
      return _failure(
        const _ToolFailure(
          'post_disabled',
          'POST requests are disabled in the Web Fetch settings.',
          instruction:
              'Ask the user to enable "Allow POST" in settings, or use GET.',
        ),
      );
    }

    if (!_settings.webFetchEnabled) {
      return _failure(
        const _ToolFailure(
          'tool_disabled',
          'Web fetch is disabled in settings.',
          instruction: 'Ask the user to enable Web Fetch in settings.',
        ),
      );
    }

    if (!policy.continuable && parsed.startIndex > 0) {
      return _failure(
        const _ToolFailure(
          'invalid_arguments',
          'start_index cannot be used with POST.',
          instruction:
              'POST requests cannot be continued; re-run from start_index=0 '
              'only if repeating the request is safe.',
        ),
      );
    }

    final cacheKey = parsed.url.toString();

    // Continuations of a cacheable GET must follow the source that served
    // the first window.
    if (policy.cacheable && parsed.startIndex > 0) {
      final cached = _cache.lookup(cacheKey);
      if (cached != null) {
        return _render(
          _resultFromCache(cached, parsed.url),
          source: cached.source,
          sourceName: _displayNameFor(cached.source),
          startIndex: parsed.startIndex,
          maxLength: parsed.maxLength,
        );
      }
      final stale = _cache.staleLookup(cacheKey);
      if (stale != null) {
        final resolved = _sourceService.resolve(_settings);
        if (resolved.source != stale.source) {
          return _failure(
            const _ToolFailure(
              'source_changed',
              'The page was originally read from a different source that is '
                  'no longer available.',
              instruction:
                  'Re-read the page from start_index=0 to get a consistent '
                  'version.',
            ),
          );
        }
      }
    }

    if (policy.cacheable && parsed.startIndex == 0) {
      final cached = _cache.lookup(cacheKey);
      if (cached != null) {
        return _render(
          _resultFromCache(cached, parsed.url),
          source: cached.source,
          sourceName: _displayNameFor(cached.source),
          startIndex: 0,
          maxLength: parsed.maxLength,
        );
      }
    }

    final request = FetchRequest(
      url: parsed.url,
      method: parsed.method,
      headers: parsed.headers,
      body: parsed.body,
      raw: parsed.raw,
      selector: parsed.selector,
    );

    final WebFetchOutcome outcome;
    try {
      if (policy.cacheable && parsed.startIndex == 0) {
        outcome = await _cache.dedupe(cacheKey, () async {
          final value = await _sourceService.fetch(
            request: request,
            settings: _settings,
            localCore: _localCore,
          );
          _cache.store(
            url: cacheKey,
            content: value.result.content,
            metadata: value.result.metadata,
            source: value.source,
            canonicalUrl: value.result.finalUrl.toString(),
          );
          return value.result;
        }).then((result) {
          // A deduped result was stored by the creating call; rebuild its
          // outcome from the cached entry so the header still names the
          // source.
          final entry = _cache.lookup(cacheKey);
          final source = entry?.source ?? 'local';
          return WebFetchOutcome(
            result: result,
            source: source,
            sourceName: _displayNameFor(source),
          );
        });
      } else {
        outcome = await _sourceService.fetch(
          request: request,
          settings: _settings,
          localCore: _localCore,
          allowEscalation: policy.upgradeable,
        );
      }
    } on FetchException catch (failure) {
      return _failure(_fromFetchException(failure));
    } catch (e) {
      return _failure(
        _ToolFailure(
          'network_error',
          e.toString(),
          instruction: 'Check the URL and try again.',
        ),
      );
    }

    return _render(
      outcome.result,
      source: outcome.source,
      sourceName: outcome.sourceName,
      startIndex: parsed.startIndex,
      maxLength: parsed.maxLength,
      escalated: outcome.escalated,
      escalationError: outcome.escalationError,
    );
  }

  static String _displayNameFor(String source) {
    if (source == 'local') return 'Local';
    for (final adapter in providerFetchAdapters) {
      if (adapter.type == source) return adapter.displayName;
    }
    return source;
  }

  FetchResult _resultFromCache(FetchCacheEntry entry, Uri url) {
    return FetchResult(
      url: url,
      finalUrl: url,
      status: 200,
      contentType: null,
      charset: 'utf-8',
      charsetFallback: false,
      content: entry.content,
      metadata: entry.metadata,
      truncated: false,
      bytes: entry.content.length,
    );
  }

  WebFetchToolResult _render(
    FetchResult result, {
    required String source,
    required String sourceName,
    required int startIndex,
    required int maxLength,
    bool escalated = false,
    String? escalationError,
  }) {
    final content = result.content;
    final total = content.length;

    if (total == 0 && startIndex > 0) {
      return _failure(
        const _ToolFailure(
          'no_more_content',
          'start_index is past the end of the content.',
          instruction: 'Start again from start_index=0 if needed.',
        ),
      );
    }
    if (startIndex >= total && total > 0) {
      return _failure(
        const _ToolFailure(
          'no_more_content',
          'start_index is past the end of the content.',
          instruction: 'Start again from start_index=0 if needed.',
        ),
      );
    }

    var start = startIndex;
    if (start > 0 && _isLowSurrogate(content.codeUnitAt(start))) {
      start--;
    }
    var end = math.min(start + maxLength, total);
    if (end < total && end > start && _isHighSurrogate(content.codeUnitAt(end - 1))) {
      if (end - start <= 1) {
        end = math.min(end + 1, total);
      } else {
        end--;
      }
    }

    final window = content.substring(start, end);
    final next = end < total ? end : null;
    final buffer = StringBuffer()
      ..writeln('URL: ${result.url}')
      ..writeln('Final URL: ${result.finalUrl}')
      ..writeln('Status: ${result.status}');
    if ((result.contentType ?? '').isNotEmpty) {
      buffer.writeln('Content-Type: ${result.contentType}');
    }
    if ((result.charset).isNotEmpty) {
      buffer.writeln(
        'Charset: ${result.charset}'
        '${result.charsetFallback ? ' (fallback)' : ''}',
      );
    }
    if ((result.metadata.title ?? '').isNotEmpty) {
      buffer.writeln('Title: ${result.metadata.title}');
    }
    if ((result.metadata.description ?? '').isNotEmpty) {
      buffer.writeln('Description: ${result.metadata.description}');
    }
    if ((result.metadata.siteName ?? '').isNotEmpty) {
      buffer.writeln('Site: ${result.metadata.siteName}');
    }
    if ((result.metadata.language ?? '').isNotEmpty) {
      buffer.writeln('Language: ${result.metadata.language}');
    }
    if ((result.metadata.publishedTime ?? '').isNotEmpty) {
      buffer.writeln('Published: ${result.metadata.publishedTime}');
    }
    buffer
      ..writeln('Source: $source')
      ..writeln('Total length: $total')
      ..writeln('Showing: $start-${total == 0 ? 0 : end - 1}');
    if (next != null) buffer.writeln('Next start_index: $next');
    if (result.truncated) {
      buffer.writeln('Truncated: content was capped at 200000 characters');
    }
    buffer
      ..writeln()
      ..writeln('---')
      ..writeln()
      ..write(window);

    return WebFetchToolResult(
      text: buffer.toString(),
      source: source,
      sourceName: sourceName,
      escalated: escalated,
      escalationError: escalationError,
    );
  }

  WebFetchToolResult _failure(_ToolFailure failure) {
    final payload = <String, dynamic>{
      'type': 'tool_error',
      'error': failure.code,
      'message': failure.message,
      'tool': toolName,
      if ((failure.instruction ?? '').isNotEmpty)
        'instruction': failure.instruction,
      ...failure.extra,
    };
    return WebFetchToolResult(
      text: jsonEncode(payload),
      source: 'local',
      sourceName: 'Local',
    );
  }

  _ToolFailure _fromFetchException(FetchException failure) {
    switch (failure.code) {
      case 'blocked_private_address':
        return _ToolFailure(
          failure.code,
          failure.message,
          instruction:
              'Only public URLs can be fetched. Ask the user for a public '
              'link, or ask them to enable private hosts in settings.',
        );
      case 'redirect_method_change':
        return _ToolFailure(
          failure.code,
          failure.message,
          instruction:
              'Retry against the redirect target with method=GET if that is '
              'what the API expects.',
          extra: {
            if (failure.uri != null) 'location': failure.uri.toString(),
            if (failure.status != null) 'status': failure.status,
          },
        );
      case 'http_error':
        return _ToolFailure(
          failure.code,
          failure.message,
          instruction:
              'Check the URL and HTTP status. Do not retry the same request '
              'blindly.',
          extra: {
            if (failure.status != null) 'status': failure.status,
            if ((failure.bodySnippet ?? '').isNotEmpty)
              'body': failure.bodySnippet,
          },
        );
      case 'response_too_large':
        return _ToolFailure(
          failure.code,
          failure.message,
          instruction: 'Fetch a smaller page or a different URL.',
        );
      case 'timeout':
        return _ToolFailure(
          failure.code,
          failure.message,
          instruction: 'Try again later or fetch a different URL.',
        );
      case 'unsupported_binary':
        return _ToolFailure(
          failure.code,
          failure.message,
          instruction:
              'This URL is not text. Do not retry; report the limitation to '
              'the user.',
        );
      case 'no_readable_content':
        return _ToolFailure(
          failure.code,
          failure.message,
          instruction:
              'The page had no extractable text. Try raw=true to inspect the '
              'raw response, or use a different URL.',
        );
      case 'selector_not_found':
        return _ToolFailure(
          failure.code,
          failure.message,
          instruction:
              'Fix the CSS selector or omit it to extract the whole page.',
        );
      case 'network_error':
        return _ToolFailure(
          failure.code,
          failure.message,
          instruction: 'Check the URL and network connection, then try again.',
        );
      default:
        return _ToolFailure(
          failure.code,
          failure.message,
          instruction: 'Check the arguments and try a different URL.',
        );
    }
  }

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
}

class _Args {
  const _Args({
    required this.url,
    required this.method,
    required this.headers,
    required this.body,
    required this.raw,
    required this.selector,
    required this.maxLength,
    required this.startIndex,
  });

  final Uri url;
  final String method;
  final Map<String, String> headers;
  final String? body;
  final bool raw;
  final String? selector;
  final int maxLength;
  final int startIndex;

  static _Args parse(Map<String, dynamic> args, {required bool defaultRaw}) {
    final urlRaw = args['url'];
    if (urlRaw is! String) {
      throw const _ToolFailure(
        'invalid_arguments',
        'The "url" argument is required and must be a string.',
      );
    }
    final urlText = urlRaw.trim();
    final uri = Uri.tryParse(urlText);
    if (uri == null ||
        !uri.hasScheme ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.trim().isEmpty) {
      throw _ToolFailure(
        'invalid_url',
        'Invalid URL: "$urlText". A complete http:// or https:// URL is '
            'required.',
        instruction: 'Provide a full URL including the scheme.',
      );
    }

    final methodRaw = args['method'];
    final method = (methodRaw == null ? 'GET' : methodRaw.toString())
        .trim()
        .toUpperCase();
    if (method != 'GET' && method != 'POST') {
      throw const _ToolFailure(
        'invalid_arguments',
        'method must be GET or POST.',
      );
    }

    final headers = <String, String>{};
    final headersRaw = args['headers'];
    if (headersRaw != null) {
      if (headersRaw is! Map) {
        throw const _ToolFailure(
          'invalid_arguments',
          'headers must be an object.',
        );
      }
      headersRaw.forEach((key, value) {
        if (key == null || value == null) return;
        headers[key.toString()] = value.toString();
      });
    }

    final bodyRaw = args['body'];
    String? body;
    if (bodyRaw != null) {
      if (bodyRaw is String) {
        body = bodyRaw;
      } else if (bodyRaw is Map || bodyRaw is List) {
        body = jsonEncode(bodyRaw);
      } else {
        throw const _ToolFailure(
          'invalid_arguments',
          'body must be a string, object or array.',
        );
      }
    }

    final raw = _parseBool(args['raw'], defaultValue: defaultRaw);

    final selectorRaw = args['selector'];
    String? selector;
    if (selectorRaw != null) {
      if (selectorRaw is! String) {
        throw const _ToolFailure(
          'invalid_arguments',
          'selector must be a string.',
        );
      }
      final trimmed = selectorRaw.trim();
      selector = trimmed.isEmpty ? null : trimmed;
    }

    final maxLength = _parseInt(
      args['max_length'],
      defaultValue: WebFetchTool.defaultMaxLength,
      name: 'max_length',
    );
    if (maxLength < 1 || maxLength > WebFetchTool.maximumMaxLength) {
      throw const _ToolFailure(
        'invalid_arguments',
        'max_length must be between 1 and 20000.',
      );
    }

    final startIndex = _parseInt(
      args['start_index'],
      defaultValue: 0,
      name: 'start_index',
    );
    if (startIndex < 0) {
      throw const _ToolFailure(
        'invalid_arguments',
        'start_index must be zero or positive.',
      );
    }

    if (body != null && method != 'POST') {
      throw const _ToolFailure(
        'invalid_arguments',
        'A body can only be sent with method=POST.',
      );
    }
    if (method == 'POST' && startIndex > 0) {
      throw const _ToolFailure(
        'invalid_arguments',
        'start_index cannot be used with POST.',
      );
    }
    if (raw && selector != null) {
      throw const _ToolFailure(
        'invalid_arguments',
        'selector can only be used with raw=false.',
      );
    }

    return _Args(
      url: uri,
      method: method,
      headers: headers,
      body: body,
      raw: raw,
      selector: selector,
      maxLength: maxLength,
      startIndex: startIndex,
    );
  }

  static int _parseInt(
    dynamic value, {
    required int defaultValue,
    required String name,
  }) {
    if (value == null) return defaultValue;
    if (value is int) return value;
    if (value is num && value == value.roundToDouble()) return value.toInt();
    throw _ToolFailure(
      'invalid_arguments',
      '$name must be an integer.',
    );
  }

  static bool _parseBool(dynamic value, {required bool defaultValue}) {
    if (value == null) return defaultValue;
    if (value is bool) return value;
    if (value is String) {
      final lower = value.trim().toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
    }
    throw const _ToolFailure(
      'invalid_arguments',
      'raw must be true or false.',
    );
  }
}

class _Policy {
  const _Policy({
    required this.cacheable,
    required this.upgradeable,
    required this.continuable,
  });

  factory _Policy.from(_Args args) {
    final plainGet =
        args.method == 'GET' &&
        args.headers.isEmpty &&
        args.body == null &&
        args.selector == null &&
        !args.raw;
    return _Policy(
      cacheable: plainGet,
      upgradeable: plainGet,
      continuable: args.method != 'POST',
    );
  }

  final bool cacheable;
  final bool upgradeable;
  final bool continuable;
}

class _ToolFailure implements Exception {
  const _ToolFailure(
    this.code,
    this.message, {
    this.instruction,
    this.extra = const <String, dynamic>{},
  });

  final String code;
  final String message;
  final String? instruction;
  final Map<String, dynamic> extra;
}
