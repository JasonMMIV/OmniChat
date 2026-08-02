import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import '../../../../l10n/app_localizations.dart';
import '../search_service.dart';

/// PubMed (NCBI E-utilities) provider — search + abstracts only (no full text).
/// - No API key required (3 rps). With a free My NCBI key: 10 rps.
/// - Two-step flow: esearch (get PMIDs) → efetch (title + abstract).
/// - Optional `tool` / `email` params recommended by NCBI.
class PubmedSearchService extends SearchService<PubMedOptions> {
  static const _baseUrl = 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/';

  @override
  String get name => 'PubMed';

  @override
  Widget description(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      l10n.searchProviderPubMedDescription,
      style: const TextStyle(fontSize: 12),
    );
  }

  Map<String, String> _authParams(PubMedOptions serviceOptions) => {
    if (serviceOptions.apiKey.isNotEmpty) 'api_key': serviceOptions.apiKey,
    if (serviceOptions.tool.isNotEmpty) 'tool': serviceOptions.tool,
    if (serviceOptions.email.isNotEmpty) 'email': serviceOptions.email,
  };

  @override
  Future<SearchResult> search({
    required String query,
    required SearchCommonOptions commonOptions,
    required PubMedOptions serviceOptions,
  }) async {
    try {
      // Step 1: esearch — find matching PMIDs (JSON).
      final esearchUri = Uri.parse('${_baseUrl}esearch.fcgi').replace(
        queryParameters: {
          'db': 'pubmed',
          'term': query,
          'retmode': 'json',
          'retmax': '${commonOptions.resultSize}',
          'sort': 'relevance',
          ..._authParams(serviceOptions),
        },
      );
      final esearchResp = await http
          .get(esearchUri)
          .timeout(Duration(milliseconds: commonOptions.timeout));
      if (esearchResp.statusCode != 200) {
        throw Exception('esearch failed with status ${esearchResp.statusCode}');
      }
      final esearchData = jsonDecode(esearchResp.body) as Map<String, dynamic>;
      final idList =
          (esearchData['esearchresult']?['idlist'] as List?)?.cast<String>() ??
          const <String>[];
      if (idList.isEmpty) return SearchResult(items: []);

      // Step 2: efetch — retrieve title + abstract as XML.
      final efetchUri = Uri.parse('${_baseUrl}efetch.fcgi').replace(
        queryParameters: {
          'db': 'pubmed',
          'id': idList.join(','),
          'retmode': 'xml',
          'rettype': 'abstract',
          ..._authParams(serviceOptions),
        },
      );
      final efetchResp = await http
          .get(efetchUri)
          .timeout(Duration(milliseconds: commonOptions.timeout));
      if (efetchResp.statusCode != 200) {
        throw Exception('efetch failed with status ${efetchResp.statusCode}');
      }

      final document = XmlDocument.parse(efetchResp.body);
      final articles = document.findAllElements('PubmedArticle');
      final items = <SearchResultItem>[];

      for (final article in articles) {
        final pmid =
            article.getElement('PMID')?.innerText.trim() ?? '';
        final title =
            article.getElement('ArticleTitle')?.innerText.trim() ?? '';
        // Abstract may have multiple structured sections (AbstractText).
        final abstractParts = article
            .findAllElements('AbstractText')
            .map((e) => e.innerText.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        final journal =
            article.getElement('JournalIssue')?.getElement('Title')?.innerText
                .trim() ??
            '';
        final year = article
                .getElement('PubDate')
                ?.getElement('Year')
                ?.innerText
                .trim() ??
            '';
        final text = abstractParts.isEmpty
            ? [journal, year].where((s) => s.isNotEmpty).join(' · ')
            : abstractParts.join('\n');
        if (title.isEmpty && pmid.isEmpty && text.isEmpty) continue;
        items.add(SearchResultItem(
          title: title.isEmpty ? pmid : title,
          url: pmid.isNotEmpty ? 'https://pubmed.ncbi.nlm.nih.gov/$pmid/' : '',
          text: text,
          id: pmid,
        ));
      }

      return SearchResult(items: items);
    } catch (e) {
      throw Exception('PubMed search failed: $e');
    }
  }
}
