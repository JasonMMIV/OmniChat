import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../../l10n/app_localizations.dart';
import '../search_service.dart';

/// DeepSeek Search / Fetch API (separate from the DeepSeek chat provider).
class DeepSeekSearchService extends SearchService<DeepSeekSearchOptions> {
  DeepSeekSearchService({http.Client? client}) : _client = client;

  final http.Client? _client;

  @override
  String get name => 'DeepSeek';

  @override
  Widget description(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      l10n.searchProviderDeepSeekSearchDescription,
      style: const TextStyle(fontSize: 12),
    );
  }

  @override
  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required DeepSeekSearchOptions serviceOptions,
  }) async {
    try {
      final apiKey = serviceOptions.apiKey.trim();
      if (apiKey.isEmpty) {
        throw Exception('DeepSeek API key is required');
      }

      final response = await _post(
        Uri.parse(DeepSeekSearchOptions.searchEndpoint),
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'query': query,
          'count': commonOptions.resultSize.clamp(1, 50),
          'need_content': false,
        }),
      ).timeout(Duration(milliseconds: commonOptions.timeout));

      final body = utf8.decode(response.bodyBytes);
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: $body');
      }

      final data = jsonDecode(body) as Map<String, dynamic>;
      final results = (data['results'] as List?) ?? const <dynamic>[];
      final items = results.take(commonOptions.resultSize).map((item) {
        final result = (item as Map).cast<String, dynamic>();
        final summary = (result['summary'] ?? '').toString().trim();
        var text = summary.isNotEmpty
            ? summary
            : (result['snippet'] ?? '').toString();
        final rawDate = result['date'];
        final publishedAt = rawDate is String
            ? DateTime.tryParse(rawDate)
            : null;
        if (publishedAt != null && publishedAt.isUtc) {
          final date = publishedAt.toIso8601String().split('T').first;
          text = '[Published: $date] $text';
        }
        return SearchResultItem(
          title: (result['title'] ?? '').toString(),
          url: (result['url'] ?? '').toString(),
          text: text,
        );
      }).toList();

      return SearchResult(items: items);
    } catch (e) {
      throw Exception('DeepSeek search failed: $e');
    }
  }

  Future<http.Response> _post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  }) {
    final client = _client;
    return client == null
        ? http.post(uri, headers: headers, body: body)
        : client.post(uri, headers: headers, body: body);
  }
}
