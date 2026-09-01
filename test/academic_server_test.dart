import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/mcp/academic/academic_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    // Reset the static resolver so tests don't leak settings across cases.
    AcademicSearchOptionsResolver.attach(null);
  });

  group('academic in-memory MCP server', () {
    late AcademicMcpServerEngine engine;

    setUp(() {
      engine = AcademicMcpServerEngine();
    });

    tearDown(() {
      engine.close();
    });

    test('initialize returns server info with tools capability', () async {
      final resp = await engine.handleMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': mcp.McpProtocol.defaultVersion,
          'capabilities': {},
          'clientInfo': {'name': 'test', 'version': '1.0'},
        },
      });
      final map = (resp as Map).cast<String, dynamic>();
      expect(map['id'], 1);
      final result = (map['result'] as Map).cast<String, dynamic>();
      expect(
        (result['serverInfo'] as Map)['name'],
        'Academic_Search',
      );
      expect(
        (result['capabilities'] as Map).containsKey('tools'),
        isTrue,
      );
    });

    test('listTools exposes pubmed/arxiv/semantic_scholar with schemas',
        () async {
      final resp = await engine.handleMessage({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/list',
        'params': {},
      });
      final map = (resp as Map).cast<String, dynamic>();
      final tools =
          ((map['result'] as Map)['tools'] as List).cast<Map<String, dynamic>>();
      final names = tools.map((t) => t['name']).toSet();
      expect(names, containsAll(['pubmed_search', 'arxiv_search', 'semantic_scholar_search']));

      final pubmed = tools.firstWhere((t) => t['name'] == 'pubmed_search');
      final schema = (pubmed['inputSchema'] as Map).cast<String, dynamic>();
      expect(schema['required'], contains('query'));
      expect(
        (schema['properties'] as Map).containsKey('max_results'),
        isTrue,
      );
      expect((pubmed['description'] as String), isNotEmpty);
    });

    test('callTool with missing query returns an error result', () async {
      final resp = await engine.handleMessage({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {'name': 'pubmed_search', 'arguments': {}},
      });
      final map = (resp as Map).cast<String, dynamic>();
      final result = (map['result'] as Map).cast<String, dynamic>();
      expect(result['isError'], isTrue);
      expect((result['content'] as List).first['text'], contains('query is required'));
    });

    test('callTool with unknown tool name returns JSON-RPC error', () async {
      final resp = await engine.handleMessage({
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/call',
        'params': {'name': 'nope', 'arguments': {}},
      });
      final map = (resp as Map).cast<String, dynamic>();
      expect(map.containsKey('error'), isTrue);
      expect((map['error'] as Map)['code'], -32101);
    });

    test('batch array messages are handled', () async {
      final resp = await engine.handleMessage([
        {
          'jsonrpc': '2.0',
          'id': 5,
          'method': 'tools/list',
          'params': {},
        },
      ]);
      expect(resp, isA<List>());
    });
  });

  group('clampAcademicMaxResults', () {
    test('clamps to 1-15 with default 10', () {
      expect(clampAcademicMaxResults(null), 10);
      expect(clampAcademicMaxResults(0), 1);
      expect(clampAcademicMaxResults(5), 5);
      expect(clampAcademicMaxResults(99), 15);
      expect(clampAcademicMaxResults('7'), 7);
      expect(clampAcademicMaxResults('abc'), 10);
    });
  });

  group('AcademicSearchOptionsResolver', () {
    test('config returns defaults when not attached', () {
      expect(
        AcademicSearchOptionsResolver.config().pubmedApiKey,
        isEmpty,
      );
      expect(
        AcademicSearchOptionsResolver.config().semanticScholarApiKey,
        isEmpty,
      );
      expect(AcademicSearchOptionsResolver.timeoutMs, 15000);
    });

    test('attach + config reads standalone academic config', () async {
      // Build a real SettingsProvider with mocked prefs, then configure the
      // standalone academic MCP config (independent from web search).
      final sp = await _loadedProvider();
      await sp.setAcademicConfig(
        const AcademicMcpConfig(
          pubmedApiKey: 'key',
          pubmedTool: 'OmniChat',
          pubmedEmail: 'dev@example.com',
          semanticScholarApiKey: 'sk',
        ),
      );
      AcademicSearchOptionsResolver.attach(sp);

      final cfg = AcademicSearchOptionsResolver.config();
      expect(cfg.pubmedApiKey, 'key');
      expect(cfg.pubmedTool, 'OmniChat');
      expect(cfg.pubmedEmail, 'dev@example.com');
      expect(cfg.semanticScholarApiKey, 'sk');
      expect(cfg.hasPubMedKey, isTrue);
      expect(cfg.hasSemanticScholarKey, isTrue);
    });

    test('setAcademicConfig persists and loads back', () async {
      final sp = await _loadedProvider();
      await sp.setAcademicConfig(
        const AcademicMcpConfig(pubmedApiKey: 'pk', semanticScholarApiKey: 's2k'),
      );
      // A fresh provider should read the persisted config.
      final sp2 = await _loadedProvider();
      expect(sp2.academicConfig.pubmedApiKey, 'pk');
      expect(sp2.academicConfig.semanticScholarApiKey, 's2k');
    });

    test('legacy search-service academic entries migrate into config', () async {
      // Seed prefs with legacy web-search entries containing academic providers.
      SharedPreferences.setMockInitialValues({
        'search_services_v1': jsonEncode([
          {'type': 'bing_local', 'id': 'b1', 'acceptLanguage': 'en-US'},
          {
            'type': 'pubmed',
            'id': 'p1',
            'apiKey': 'pmk',
            'tool': 'MyTool',
            'email': 'me@x.com',
          },
          {'type': 'semantic_scholar', 'id': 's1', 'apiKey': 's2k'},
          {'type': 'arxiv', 'id': 'a1'},
        ]),
      });
      final sp = await _loadedProvider();
      // Academic providers are stripped from the web search list.
      final webTypes = sp.searchServices
          .map((e) => e.runtimeType.toString())
          .toList();
      expect(
        webTypes.any((t) => t.contains('PubMed')),
        isFalse,
      );
      // Keys were moved into the standalone academic config.
      expect(sp.academicConfig.pubmedApiKey, 'pmk');
      expect(sp.academicConfig.pubmedTool, 'MyTool');
      expect(sp.academicConfig.pubmedEmail, 'me@x.com');
      expect(sp.academicConfig.semanticScholarApiKey, 's2k');
    });
  });

}


/// Build a loaded real SettingsProvider (mirrors the pattern used by
/// settings_provider tests).
Future<SettingsProvider> _loadedProvider() async {
  final sp = SettingsProvider();
  final done = Completer<void>();
  void listener() {
    if (!done.isCompleted) done.complete();
  }

  sp.addListener(listener);
  await done.future.timeout(const Duration(seconds: 10));
  sp.removeListener(listener);
  return sp;
}
