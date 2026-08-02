import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../../l10n/app_localizations.dart';
import '../search_service.dart';

/// Semantic Scholar Academic Graph API provider.
/// - No API key required (shared public pool). Free key via email → 1 rps.
/// - JSON responses, `fields` param controls the payload.
class SemanticScholarSearchService extends SearchService<SemanticScholarOptions> {
  static const _baseUrl =
      'https://api.semanticscholar.org/graph/v1/paper/search';

  @override
  String get name => 'Semantic Scholar';

  @override
  Widget description(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      l10n.searchProviderSemanticScholarDescription,
      style: const TextStyle(fontSize: 12),
    );
  }

  @override
  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required SemanticScholarOptions serviceOptions,
  }) async {
    try {
      final uri = Uri.parse(_baseUrl).replace(
        queryParameters: {
          'query': query,
          'limit': '${commonOptions.resultSize}',
          'fields': 'title,abstract,url,year,venue,citationCount,openAccessPdf',
        },
      );
      final headers = <String, String>{
        'User-Agent': 'OmniChat/1.0',
        if (serviceOptions.apiKey.isNotEmpty)
          'x-api-key': serviceOptions.apiKey,
      };

      final response = await http
          .get(uri, headers: headers)
          .timeout(Duration(milliseconds: commonOptions.timeout));

      if (response.statusCode == 429) {
        throw Exception(
          'Semantic Scholar rate limit exceeded (429). '
          'Consider adding a free API key for more quota.',
        );
      }
      if (response.statusCode != 200) {
        throw Exception('Request failed with status ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final papers = (data['data'] as List?) ?? const [];
      final items = <SearchResultItem>[];

      for (final raw in papers) {
        if (raw is! Map) continue;
        final map = raw.cast<String, dynamic>();
        final title = map['title']?.toString() ?? '';
        // Abstract may be null on S2; fall back to venue/year/citation info.
        final abstract = map['abstract']?.toString() ?? '';
        final venue = map['venue']?.toString() ?? '';
        final year = map['year']?.toString() ?? '';
        final citationCount = map['citationCount']?.toString() ?? '';
        final url = map['url']?.toString() ?? '';

        final metaParts = <String>[
          if (venue.isNotEmpty) venue,
          if (year.isNotEmpty) year,
          if (citationCount.isNotEmpty) 'Cited $citationCount',
        ];
        final text = abstract.isEmpty
            ? metaParts.join(' · ')
            : (metaParts.isEmpty
                  ? abstract
                  : '$abstract\n\n${metaParts.join(' · ')}');

        if (title.isEmpty && url.isEmpty && abstract.isEmpty) continue;
        items.add(SearchResultItem(
          title: title.isEmpty ? url : title,
          url: url,
          text: text,
          id: map['paperId']?.toString(),
        ));
      }

      return SearchResult(items: items);
    } catch (e) {
      throw Exception('Semantic Scholar search failed: $e');
    }
  }
}
