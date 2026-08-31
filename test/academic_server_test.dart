import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/mcp/academic/academic_server.dart';
import 'package:OmniChat/core/services/search/search_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
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
        'academic',
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
    test('lookup returns null when not attached', () {
      expect(AcademicSearchOptionsResolver.lookup('pubmed'), isNull);
    });

    test('attach + lookup finds configured options by type', () async {
      // Build a real SettingsProvider with mocked prefs, then configure
      // the three academic search services.
      final sp = await _loadedProvider();
      await sp.updateSettings(
        sp.copyWith(
          searchServices: [
            PubMedOptions(id: 'p1', apiKey: 'key'),
            ArxivOptions(id: 'a1'),
            SemanticScholarOptions(id: 's1', apiKey: 'sk'),
          ],
        ),
      );
      AcademicSearchOptionsResolver.attach(sp);

      final p = AcademicSearchOptionsResolver.lookup('pubmed');
      expect(p, isA<PubMedOptions>());
      expect((p as PubMedOptions).apiKey, 'key');

      expect(
        AcademicSearchOptionsResolver.lookup('arxiv'),
        isA<ArxivOptions>(),
      );
      expect(
        AcademicSearchOptionsResolver.lookup('semantic_scholar'),
        isA<SemanticScholarOptions>(),
      );
      // Unknown types resolve to null
      expect(AcademicSearchOptionsResolver.lookup('bogus'), isNull);
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
