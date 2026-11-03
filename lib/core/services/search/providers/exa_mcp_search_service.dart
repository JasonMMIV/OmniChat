import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_client/mcp_client.dart' as mcp;

import '../../../../l10n/app_localizations.dart';
import '../search_service.dart';

/// Exa's hosted MCP server. One Streamable HTTP session per call; the same
/// endpoint serves `web_search_exa` and `web_fetch_exa`.
class ExaMcpSearchService extends SearchService<ExaMcpOptions>
    implements WebFetchCapable<ExaMcpOptions> {
  ExaMcpSearchService({http.Client? client}) : _client = client;

  static const int maxFetchCharacters = 100000;

  final http.Client? _client;

  @override
  String get name => 'Exa MCP';

  @override
  Widget description(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      l10n.searchProviderExaMcpDescription,
      style: const TextStyle(fontSize: 12),
    );
  }

  @override
  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required ExaMcpOptions serviceOptions,
  }) async {
    final limit = commonOptions.resultSize < 1 ? 1 : commonOptions.resultSize;
    try {
      final text = await _callTool(
        'web_search_exa',
        {'query': query, 'numResults': limit},
        commonOptions: commonOptions,
        serviceOptions: serviceOptions,
      );
      return SearchResult(items: _parseResults(text).take(limit).toList());
    } catch (error) {
      final detail = _errorDetail(error);
      throw Exception('Exa MCP search failed: $detail');
    }
  }

  @override
  Future<WebFetchPage> fetch({
    required String url,
    required SearchCommonOptions commonOptions,
    required ExaMcpOptions serviceOptions,
  }) async {
    try {
      final text = await _callTool(
        'web_fetch_exa',
        {
          'urls': <String>[url],
          'maxCharacters': maxFetchCharacters,
        },
        commonOptions: commonOptions,
        serviceOptions: serviceOptions,
      );
      return _parsePage(text);
    } catch (error) {
      final detail = _errorDetail(error);
      throw Exception('Exa MCP fetch failed: $detail');
    }
  }

  Future<String> _callTool(
    String tool,
    Map<String, dynamic> arguments, {
    required SearchCommonOptions commonOptions,
    required ExaMcpOptions serviceOptions,
  }) async {
    final configured = Duration(milliseconds: commonOptions.timeout);
    // MCP handshake + tool call needs more headroom than a plain search
    // request; the 5 s default search timeout is too tight for a hosted MCP
    // session. Keep user-configured values above the floor.
    final timeout = configured < const Duration(seconds: 30)
        ? const Duration(seconds: 30)
        : configured;
    final apiKey = serviceOptions.apiKey.trim();
    final injectedClient = _client;
    final transport = await mcp.StreamableHttpClientTransport.create(
      baseUrl: serviceOptions.resolvedUrl,
      headers: {if (apiKey.isNotEmpty) 'x-api-key': apiKey},
      timeout: timeout,
      httpClient: injectedClient == null
          ? null
          : _BorrowedHttpClient(injectedClient),
      terminateOnClose: false,
    );
    final client = mcp.Client(
      name: 'OmniChat',
      version: '1.0.0',
      requestTimeout: timeout,
    );
    try {
      await client.connect(transport).timeout(timeout);
      final result = await client.callTool(tool, arguments).timeout(timeout);
      final text = result.content
          .whereType<mcp.TextContent>()
          .map((content) => content.text)
          .where((value) => value.trim().isNotEmpty)
          .join('\n\n---\n\n');
      if (result.isError == true) {
        throw StateError(
          text.trim().isEmpty ? 'Exa MCP tool failed' : text.trim(),
        );
      }
      return text;
    } on TimeoutException {
      throw TimeoutException('Exa MCP $tool timed out', timeout);
    } finally {
      client.dispose();
      transport.close();
    }
  }

  static String _errorDetail(Object error) {
    final detail = error is StateError ? error.message : error.toString();
    final lower = detail.toLowerCase();
    if (detail.contains('403') || lower.contains('forbidden')) {
      return '$detail\n'
          'For keyless access, Exa requires a direct IPv4 connection. '
          'Disable the proxy/IPv6 path or add an Exa API key. '
          '(A keyed 403 usually means quota or permission denied.)';
    }
    return detail;
  }

  WebFetchPage _parsePage(String text) {
    final normalized = text.replaceAll('\r\n', '\n').trim();
    final header = RegExp(
      r'^#[ \t]*(.*)\nURL:[ \t]*(\S+)[ \t]*(?:\n|$)',
    ).firstMatch(normalized);
    if (header == null) {
      // Quota and crawl errors come back as plain text without isError.
      throw StateError(normalized.isEmpty ? 'no content returned' : normalized);
    }
    return WebFetchPage(
      url: header.group(2)!,
      title: header.group(1)!.trim(),
      content: normalized.substring(header.end).trim(),
    );
  }

  List<SearchResultItem> _parseResults(String text) {
    final normalized = text.replaceAll('\r\n', '\n').trim();
    if (normalized.isEmpty ||
        normalized.startsWith('No search results found.')) {
      return <SearchResultItem>[];
    }

    // Require Exa's complete metadata header: page bodies can themselves
    // contain horizontal rules followed by Title/URL examples.
    final headers = RegExp(
      r'(?:^|\n[ \t]*\n---[ \t]*\n[ \t]*\n)'
      r'Title:[ \t]*(.*)\nURL:[ \t]*(\S+)[ \t]*\n'
      r'Published:[^\n]*\nAuthor:[^\n]*(?=\n|$)',
    ).allMatches(normalized).toList();
    if (headers.isEmpty) {
      // The hosted server returns quota errors as plain text without isError.
      throw StateError(normalized);
    }

    final results = <SearchResultItem>[];
    for (var index = 0; index < headers.length; index++) {
      final header = headers[index];
      final url = header.group(2)!;
      final uri = Uri.tryParse(url);
      if (uri == null ||
          uri.host.isEmpty ||
          (uri.scheme != 'https' && uri.scheme != 'http')) {
        throw const FormatException('Exa MCP returned an invalid result URL');
      }
      final hasNext = index + 1 < headers.length;
      final body = normalized.substring(
        header.end,
        hasNext ? headers[index + 1].start : normalized.length,
      );
      final marker = RegExp(
        r'^(?:Highlights|Text):[ \t]*',
        multiLine: true,
      ).firstMatch(body);
      final title = header.group(1)!.trim();
      results.add(
        SearchResultItem(
          title: title.isEmpty || title == 'N/A' ? url : title,
          url: url,
          text: marker == null ? '' : body.substring(marker.end).trim(),
        ),
      );
    }
    return results;
  }
}

/// Keeps ownership of an injected test/client instance: transport.close()
/// must not close a client that the caller still owns.
class _BorrowedHttpClient extends http.BaseClient {
  _BorrowedHttpClient(this._delegate);

  final http.Client _delegate;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _delegate.send(request);

  @override
  void close() {}
}
