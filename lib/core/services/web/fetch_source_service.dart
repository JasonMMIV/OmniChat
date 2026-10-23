// Tier-2 web fetch source service (WEB_FETCH_PLAN.md §5.9–5.10).
//
// `local` is always available. A provider extract API is an explicit,
// billable upgrade; any failure (or 429 cooldown) falls back to the local
// fetch and reports the escalation error.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../providers/settings_provider.dart';
import '../search/search_dispatch.dart';
import '../search/search_service.dart';
import 'fetch_core.dart';
import 'provider_adapters.dart';

class ResolvedFetchSource {
  const ResolvedFetchSource({
    required this.source,
    required this.displayName,
    this.adapter,
    this.options,
  });

  const ResolvedFetchSource.local()
    : source = 'local',
      displayName = 'Local',
      adapter = null,
      options = null;

  final String source;
  final String displayName;
  final ProviderFetchAdapter? adapter;
  final SearchServiceOptions? options;

  bool get isLocal => adapter == null || options == null;
}

class WebFetchOutcome {
  const WebFetchOutcome({
    required this.result,
    required this.source,
    required this.sourceName,
    this.escalated = false,
    this.escalationError,
  });

  final FetchResult result;
  final String source;
  final String sourceName;

  /// True when a provider was attempted (or configured) but the local fetch
  /// produced the result instead.
  final bool escalated;
  final String? escalationError;
}

class FetchSourceService {
  FetchSourceService({
    http.Client? client,
    ProviderCooldown? cooldown,
  }) : _client = client,
       _cooldown = cooldown ?? ProviderCooldown.shared;

  static const Duration providerTimeout = Duration(seconds: 30);
  static const int maxContentChars = 200000;

  final http.Client? _client;
  final ProviderCooldown _cooldown;

  http.Client get _httpClient {
    final client = _client;
    if (client != null) return client;
    _sharedClient ??= http.Client();
    return _sharedClient!;
  }

  static http.Client? _sharedClient;

  /// Resolves the configured source. `follow` is deterministic: the first
  /// selected provider (selection order) that has an extract adapter wins —
  /// round-robin never applies to fetch.
  ResolvedFetchSource resolve(SettingsProvider settings) {
    final mode = settings.webFetchSource;
    if (mode == 'local') return const ResolvedFetchSource.local();

    final services = settings.searchServices;
    if (mode == 'follow') {
      for (final id in settings.searchSelectedProviders) {
        final options = _findById(services, id);
        if (options == null) continue;
        final adapter = providerFetchAdapterFor(
          (options.toJson()['type'] ?? '').toString(),
        );
        if (adapter != null) {
          return ResolvedFetchSource(
            source: adapter.type,
            displayName: adapter.displayName,
            adapter: adapter,
            options: options,
          );
        }
      }
      return const ResolvedFetchSource.local();
    }

    final options = _findById(services, mode);
    if (options == null) return const ResolvedFetchSource.local();
    final adapter = providerFetchAdapterFor(
      (options.toJson()['type'] ?? '').toString(),
    );
    if (adapter == null) return const ResolvedFetchSource.local();
    return ResolvedFetchSource(
      source: adapter.type,
      displayName: adapter.displayName,
      adapter: adapter,
      options: options,
    );
  }

  /// Fetches [request] from the resolved source, falling back to the local
  /// core on any provider failure.
  Future<WebFetchOutcome> fetch({
    required FetchRequest request,
    required SettingsProvider settings,
    required FetchCore localCore,
    bool allowEscalation = true,
  }) async {
    final resolved = resolve(settings);
    final provider = resolved.adapter;
    final options = resolved.options;

    if (allowEscalation &&
        provider != null &&
        options != null &&
        !_cooldown.isCoolingDown(resolved.source)) {
      try {
        final page = await _fetchViaProvider(provider, options, request);
        return WebFetchOutcome(
          result: _toResult(request, page),
          source: resolved.source,
          sourceName: resolved.displayName,
        );
      } catch (e) {
        if (e is _ProviderRateLimited) {
          _cooldown.mark(resolved.source);
        }
        final local = await localCore.fetch(request);
        return WebFetchOutcome(
          result: local,
          source: 'local',
          sourceName: 'Local',
          escalated: true,
          escalationError: e.toString(),
        );
      }
    }

    final local = await localCore.fetch(request);
    return WebFetchOutcome(
      result: local,
      source: 'local',
      sourceName: 'Local',
      escalated: resolved.adapter != null,
      escalationError: resolved.adapter != null
          ? '${resolved.displayName} is rate limited; used the local fetch.'
          : null,
    );
  }

  Future<WebFetchPage> _fetchViaProvider(
    ProviderFetchAdapter adapter,
    SearchServiceOptions options,
    FetchRequest request,
  ) async {
    final uri = adapter.uriBuilder(request.url.toString(), options);
    final headers = adapter.headersBuilder(options);
    final http.Request providerRequest;
    if (adapter.method == 'GET') {
      providerRequest = http.Request('GET', uri)..headers.addAll(headers);
    } else {
      providerRequest = http.Request('POST', uri)
        ..headers.addAll(headers)
        ..bodyBytes = utf8.encode(
          encodeAdapterBody(
            adapter.bodyBuilder?.call(request.url.toString(), options) ??
                <String, dynamic>{'url': request.url.toString()},
          ),
        );
    }

    final http.StreamedResponse response;
    try {
      response = await _httpClient.send(providerRequest).timeout(providerTimeout);
    } on TimeoutException {
      throw _ProviderFailure('provider timed out');
    } on http.ClientException catch (e) {
      throw _ProviderFailure(e.message);
    }

    final bodyBytes = await response.stream.toBytes();
    final bodyText = utf8.decode(bodyBytes, allowMalformed: true);

    if (response.statusCode == 429) {
      throw const _ProviderRateLimited();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _ProviderFailure(
        'provider returned HTTP ${response.statusCode}',
        status: response.statusCode,
      );
    }

    dynamic payload = bodyText;
    if (!adapter.plainTextResponse) {
      try {
        payload = jsonDecode(bodyText);
      } on FormatException {
        throw _ProviderFailure('provider returned invalid JSON');
      }
    }

    final content = adapter.contentExtractor(payload).trim();
    if (content.isEmpty) {
      throw _ProviderFailure('provider returned an empty page');
    }
    final title = adapter.titleExtractor?.call(payload).trim() ?? '';
    return WebFetchPage(
      url: request.url.toString(),
      title: title,
      content: content,
    );
  }

  FetchResult _toResult(FetchRequest request, WebFetchPage page) {
    var content = page.content;
    var truncated = false;
    if (content.length > maxContentChars) {
      var end = maxContentChars;
      if (end < content.length) {
        final unit = content.codeUnitAt(end);
        if (unit >= 0xDC00 && unit <= 0xDFFF) end--;
      }
      content = content.substring(0, end);
      truncated = true;
    }
    return FetchResult(
      url: request.url,
      finalUrl: request.url,
      status: 200,
      contentType: 'text/markdown',
      charset: 'utf-8',
      charsetFallback: false,
      content: content,
      metadata: FetchMetadata(title: page.title.isEmpty ? null : page.title),
      truncated: truncated,
      bytes: page.content.length,
    );
  }

  static SearchServiceOptions? _findById(
    List<SearchServiceOptions> services,
    String id,
  ) {
    for (final service in services) {
      if (service.id == id) return service;
    }
    return null;
  }
}

class _ProviderFailure implements Exception {
  const _ProviderFailure(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => message;
}

class _ProviderRateLimited implements Exception {
  const _ProviderRateLimited();

  @override
  String toString() => 'provider rate limited (HTTP 429)';
}
