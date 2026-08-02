import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import '../../../../l10n/app_localizations.dart';
import '../search_service.dart';

/// arXiv API provider — fully free, no API key required.
/// Docs: https://info.arxiv.org/help/api/user-manual.html
/// Rate limit: no more than 1 request every 3 seconds (single connection).
class ArxivSearchService extends SearchService<ArxivOptions> {
  static const _baseUrl = 'https://export.arxiv.org/api/query';

  // Global throttle to respect the arXiv 1 request / 3 seconds guideline.
  static DateTime _lastRequestAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  String get name => 'arXiv';

  @override
  Widget description(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      l10n.searchProviderArxivDescription,
      style: const TextStyle(fontSize: 12),
    );
  }

  @override
  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required ArxivOptions serviceOptions,
  }) async {
    try {
      await _throttle();

      final uri = Uri.parse(_baseUrl).replace(
        queryParameters: {
          'search_query': 'all:$query',
          'start': '0',
          'max_results': '${commonOptions.resultSize}',
          'sortBy': 'relevance',
          'sortOrder': 'descending',
        },
      );

      final response = await http
          .get(uri)
          .timeout(Duration(milliseconds: commonOptions.timeout));

      if (response.statusCode != 200) {
        throw Exception('Request failed with status ${response.statusCode}');
      }

      final document = XmlDocument.parse(response.body);
      final entries = document.findAllElements('entry');
      final items = <SearchResultItem>[];

      for (final entry in entries.take(commonOptions.resultSize)) {
        final title = entry.getElement('title')?.innerText.trim() ?? '';
        final summary = entry.getElement('summary')?.innerText.trim() ?? '';
        // The Atom <id> resolves to the abstract page.
        final idUri = entry.getElement('id')?.innerText.trim() ?? '';
        final primaryCategory = entry
            .findAllElements('category')
            .where((e) => e.getAttribute('term') != null)
            .map((e) => e.getAttribute('term')!)
            .firstOrNull;
        final published = entry.getElement('published')?.innerText.trim() ?? '';
        final year = published.length >= 4 ? published.substring(0, 4) : '';

        // Compose a snippet: abstract + category/year metadata.
        final metaParts = <String>[
          if (primaryCategory != null) primaryCategory,
          if (year.isNotEmpty) year,
        ];
        final text = summary.isEmpty
            ? metaParts.join(' · ')
            : (metaParts.isEmpty
                  ? summary
                  : '$summary\n\n${metaParts.join(' · ')}');

        if (title.isEmpty && idUri.isEmpty && summary.isEmpty) continue;
        items.add(SearchResultItem(
          title: title.isEmpty ? idUri : title,
          url: idUri,
          text: text,
          id: idUri,
        ));
      }

      return SearchResult(items: items);
    } catch (e) {
      throw Exception('arXiv search failed: $e');
    }
  }

  /// Enforce the arXiv guideline of at most one request every 3 seconds.
  static Future<void> _throttle() async {
    final now = DateTime.now();
    final elapsed = now.difference(_lastRequestAt).inMilliseconds;
    const minInterval = 3000;
    if (elapsed < minInterval) {
      await Future<void>.delayed(Duration(milliseconds: minInterval - elapsed));
    }
    _lastRequestAt = DateTime.now();
  }
}
