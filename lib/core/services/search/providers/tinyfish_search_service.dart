import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../../l10n/app_localizations.dart';
import '../search_service.dart';

class TinyfishSearchService extends SearchService<TinyfishOptions> {
  @override
  String get name => 'Tinyfish';

  @override
  Widget description(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      l10n.searchProviderTinyfishDescription,
      style: const TextStyle(fontSize: 12),
    );
  }

  @override
  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required TinyfishOptions serviceOptions,
  }) async {
    try {
      final uri = Uri.https('api.search.tinyfish.ai', '/', {
        'query': query,
      });

      final response = await http
          .get(
            uri,
            headers: {'X-API-Key': serviceOptions.apiKey},
          )
          .timeout(Duration(milliseconds: commonOptions.timeout));

      if (response.statusCode != 200) {
        throw Exception('API request failed: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final rawResults = (data['results'] as List?) ?? const <dynamic>[];

      final results = rawResults.take(commonOptions.resultSize).map((item) {
        final m = (item as Map).cast<String, dynamic>();
        return SearchResultItem(
          title: (m['title'] ?? '').toString(),
          url: (m['url'] ?? '').toString(),
          text: (m['snippet'] ?? '').toString(),
        );
      }).where((item) {
        return item.title.trim().isNotEmpty || item.url.trim().isNotEmpty;
      }).toList();

      return SearchResult(items: results);
    } catch (e) {
      throw Exception('Tinyfish search failed: $e');
    }
  }
}
