import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../../l10n/app_localizations.dart';
import '../search_service.dart';

class ParallelSearchService extends SearchService<ParallelOptions> {
  ParallelSearchService({http.Client? client}) : _client = client;

  final http.Client? _client;

  @override
  String get name => 'Parallel';

  @override
  Widget description(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      l10n.searchProviderParallelDescription,
      style: const TextStyle(fontSize: 12),
    );
  }

  @override
  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required ParallelOptions serviceOptions,
  }) async {
    try {
      final apiKey = serviceOptions.apiKey.trim();
      if (apiKey.isEmpty) {
        throw Exception('Parallel API key is required');
      }

      final response = await _post(
        Uri.parse(ParallelOptions.searchEndpoint),
        headers: {'x-api-key': apiKey, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'objective': query,
          'search_queries': <String>[query],
          'mode': serviceOptions.resolvedMode,
          'advanced_settings': {
            'max_results': commonOptions.resultSize.clamp(1, 20),
            'excerpt_settings': {'max_chars_per_result': 10000},
          },
        }),
      ).timeout(Duration(milliseconds: commonOptions.timeout));

      if (response.statusCode != 200) {
        throw Exception(
          'API request failed: ${response.statusCode} ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final results = (data['results'] as List?) ?? const <dynamic>[];
      final items = results.take(commonOptions.resultSize).map((item) {
        final result = (item as Map).cast<String, dynamic>();
        final excerpts = (result['excerpts'] as List?)
            ?.map((excerpt) => excerpt.toString().trim())
            .where((excerpt) => excerpt.isNotEmpty)
            .join('\n\n');
        return SearchResultItem(
          title: (result['title'] ?? '').toString(),
          url: (result['url'] ?? '').toString(),
          text: excerpts ?? '',
        );
      }).toList();

      return SearchResult(items: items);
    } catch (e) {
      throw Exception('Parallel search failed: $e');
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
