import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../../l10n/app_localizations.dart';
import '../search_service.dart';

class YouSearchService extends SearchService<YouSearchOptions> {
  YouSearchService({http.Client? client}) : _client = client;

  final http.Client? _client;

  @override
  String get name => 'You.com';

  @override
  Widget description(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      l10n.searchProviderYouDescription,
      style: const TextStyle(fontSize: 12),
    );
  }

  @override
  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required YouSearchOptions serviceOptions,
  }) async {
    try {
      final apiKey = serviceOptions.apiKey.trim();
      if (apiKey.isEmpty) {
        throw Exception('You.com API key is required');
      }

      final body = <String, dynamic>{
        'query': query,
        'count': commonOptions.resultSize.clamp(1, 100),
      };
      if (serviceOptions.resolvedContentMode ==
          YouSearchOptions.highlightsMode) {
        body['extraction'] = {'extraction_mode': 'highlights'};
      }

      final response = await _post(
        Uri.parse(YouSearchOptions.searchEndpoint),
        headers: {'X-API-Key': apiKey, 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ).timeout(Duration(milliseconds: commonOptions.timeout));

      if (response.statusCode != 200) {
        throw Exception(
          'API request failed: ${response.statusCode} ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final results = (data['results'] as Map?)?.cast<String, dynamic>();
      final merged = <dynamic>[
        ...?results?['web'] as List?,
        ...?results?['news'] as List?,
      ];
      final items = merged.take(commonOptions.resultSize).map((item) {
        final result = (item as Map).cast<String, dynamic>();
        return SearchResultItem(
          title: (result['title'] ?? '').toString(),
          url: (result['url'] ?? '').toString(),
          text: _resultText(result),
        );
      }).toList();

      return SearchResult(items: items);
    } catch (e) {
      throw Exception('You.com search failed: $e');
    }
  }

  static String _resultText(Map<String, dynamic> result) {
    final contents = (result['contents'] as Map?)?.cast<String, dynamic>();
    final highlights = _joinTexts(contents?['highlights']);
    if (highlights.isNotEmpty) return highlights;
    final snippets = _joinTexts(result['snippets']);
    if (snippets.isNotEmpty) return snippets;
    return (result['description'] ?? '').toString();
  }

  static String _joinTexts(dynamic value) {
    if (value is List) {
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .join('\n\n');
    }
    return (value ?? '').toString().trim();
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
