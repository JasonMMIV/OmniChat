import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../search_service.dart';

class GoogleSearchService extends SearchService<GoogleOptions> {
  @override
  String get name => 'Google';

  @override
  Widget description(BuildContext context) {
    return const Text(
      'Google Custom Search JSON API. Requires an API key and Programmable Search Engine ID.',
      style: TextStyle(fontSize: 12),
    );
  }

  @override
  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required GoogleOptions serviceOptions,
  }) async {
    try {
      final uri = Uri.https('customsearch.googleapis.com', '/customsearch/v1', {
        'key': serviceOptions.apiKey,
        'cx': serviceOptions.searchEngineId,
        'q': query,
        'num': commonOptions.resultSize.clamp(1, 10).toString(),
      });

      final response = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(Duration(milliseconds: commonOptions.timeout));

      if (response.statusCode != 200) {
        throw Exception('API request failed: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final items = (data['items'] as List? ?? const <dynamic>[])
          .map((item) => item as Map<String, dynamic>)
          .map(
            (item) => SearchResultItem(
              title: (item['title'] ?? '').toString(),
              url: (item['link'] ?? '').toString(),
              text: (item['snippet'] ?? '').toString(),
            ),
          )
          .toList();

      return SearchResult(items: items);
    } catch (e) {
      throw Exception('Google search failed: $e');
    }
  }
}
