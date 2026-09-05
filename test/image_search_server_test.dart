import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;

import 'package:OmniChat/core/services/mcp/image_search/image_search_server.dart';

http.Response _imageResponse({int status = 200, String contentType = 'image/jpeg'}) {
  return http.Response('', status, headers: {
    if (contentType.isNotEmpty) 'content-type': contentType,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('image_search in-memory MCP server', () {
    late ImageSearchMcpServerEngine engine;
    late http.Client headOk;

    setUp(() {
      headOk = MockClient((request) async => _imageResponse());
      engine = ImageSearchMcpServerEngine(httpClient: headOk);
    });

    tearDown(() {
      engine.close();
      headOk.close();
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
      expect((result['serverInfo'] as Map)['name'], 'Image_Search');
      expect((result['capabilities'] as Map).containsKey('tools'), isTrue);
    });

    test('listTools exposes image_search with schema', () async {
      final resp = await engine.handleMessage({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/list',
        'params': {},
      });
      final map = (resp as Map).cast<String, dynamic>();
      final tools =
          ((map['result'] as Map)['tools'] as List).cast<Map<String, dynamic>>();
      expect(tools, hasLength(1));
      expect(tools.first['name'], 'image_search');
      final schema = (tools.first['inputSchema'] as Map).cast<String, dynamic>();
      expect(schema['required'], contains('query'));
      expect((schema['properties'] as Map).containsKey('max_results'), isTrue);
      final desc = tools.first['description'] as String;
      expect(desc, contains('![alt](url)'));
      expect(desc, contains('thumbnail_url'));
      expect(desc, isNotEmpty);
    });

    test('callTool with missing query returns an error result', () async {
      final resp = await engine.handleMessage({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {'name': 'image_search', 'arguments': {}},
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

    test('callTool runs ddgs path and HEAD-validates results', () async {
      // 5 ddgs results >= the fallback threshold, so Wikimedia must NOT be
      // consulted. headOnly client throws on any GET to prove that.
      final headOnly = MockClient((request) async {
        if (request.method == 'GET') {
          throw StateError('Wikimedia should not be queried when ddgs has results');
        }
        return _imageResponse();
      });
      final engine2 = ImageSearchMcpServerEngine(
        ddgsOverride: (query, max) async {
          expect(query, 'Albert Einstein portrait');
          expect(max, 5);
          return List.generate(5, (i) {
            return {
              'title': 'Albert Einstein $i',
              'image': 'https://cdn.example.com/einstein_$i.jpg',
              'thumbnail': 'https://thumb.example.com/einstein_${i}_t.jpg',
              'width': '1200',
              'height': '1500',
              'url': 'https://page.example.com/einstein_$i',
            };
          });
        },
        httpClient: headOnly,
      );
      final resp = await engine2.handleMessage({
        'jsonrpc': '2.0',
        'id': 6,
        'method': 'tools/call',
        'params': {
          'name': 'image_search',
          'arguments': {'query': 'Albert Einstein portrait', 'max_results': 5},
        },
      });
      final map = (resp as Map).cast<String, dynamic>();
      final result = (map['result'] as Map).cast<String, dynamic>();
      expect(result['isError'], isFalse);
      final text = (result['content'] as List).first['text'] as String;
      final data = jsonDecode(text) as Map<String, dynamic>;
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      expect(items, hasLength(5));
      expect(items.first['image_url'], 'https://cdn.example.com/einstein_0.jpg');
      expect(items.first['thumbnail_url'], 'https://thumb.example.com/einstein_0_t.jpg');
      expect(items.first['backend'], 'duckduckgo');
      expect(items.first['index'], 1);
      expect(items.last['index'], 5);
      engine2.close();
      headOnly.close();
    });

    test('callTool returns error when ddgs succeeds but HEAD validation rejects', () async {
      final rejecting = MockClient((request) async => _imageResponse(status: 403));
      final engine2 = ImageSearchMcpServerEngine(
        ddgsOverride: (query, max) async => [
          {
            'title': 'x',
            'image': 'https://cdn.example.com/x.jpg',
            'thumbnail': 'https://thumb.example.com/x_t.jpg',
            'url': 'https://page.example.com/x',
          },
        ],
        httpClient: rejecting,
      );
      final resp = await engine2.handleMessage({
        'jsonrpc': '2.0',
        'id': 7,
        'method': 'tools/call',
        'params': {
          'name': 'image_search',
          'arguments': {'query': 'dead image'},
        },
      });
      final map = (resp as Map).cast<String, dynamic>();
      final result = (map['result'] as Map).cast<String, dynamic>();
      expect(result['isError'], isTrue);
      expect(
        (result['content'] as List).first['text'] as String,
        contains('no usable image'),
      );
      engine2.close();
      rejecting.close();
    });

    test('callTool falls back to Wikimedia when ddgs fails', () async {
      final wikimedia = MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'query': {
                'pages': [
                  {
                    'pageid': 10,
                    'title': 'File:Albert Einstein Head.jpg',
                    'imageinfo': [
                      {
                        'url': 'https://upload.wikimedia.org/wikipedia/commons/8/8d/Einstein.jpg',
                        'descriptionurl':
                            'https://commons.wikimedia.org/wiki/File:Albert_Einstein_Head.jpg',
                        'width': 1600,
                        'height': 2000,
                        'thumburl':
                            'https://upload.wikimedia.org/wikipedia/commons/thumb/8/8d/Einstein.jpg/480px-Einstein.jpg',
                        'thumbwidth': 480,
                        'thumbheight': 600,
                        'extmetadata': {
                          'Artist': {
                            'value': '<a href="//commons.wikimedia.org/wiki/User:Foo">Foo</a>'
                          },
                          'LicenseShortName': {'value': 'CC BY-SA 4.0'},
                        },
                      },
                    ],
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        // HEAD validation of the thumb URL
        return _imageResponse(contentType: 'image/webp');
      });
      final engine2 = ImageSearchMcpServerEngine(
        ddgsOverride: (query, max) async => throw Exception('ddgs down'),
        httpClient: wikimedia,
      );
      final resp = await engine2.handleMessage({
        'jsonrpc': '2.0',
        'id': 8,
        'method': 'tools/call',
        'params': {
          'name': 'image_search',
          'arguments': {'query': 'Albert Einstein'},
        },
      });
      final map = (resp as Map).cast<String, dynamic>();
      final result = (map['result'] as Map).cast<String, dynamic>();
      expect(result['isError'], isFalse);
      final text = (result['content'] as List).first['text'] as String;
      final data = jsonDecode(text) as Map<String, dynamic>;
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      expect(items, hasLength(1));
      expect(items.first['backend'], 'wikimedia');
      expect(items.first['license'], 'CC BY-SA 4.0');
      expect(items.first['author'], 'Foo');
      expect(items.first['thumbnail_url'], contains('480px-Einstein.jpg'));
      expect(items.first['source_url'], contains('File:Albert_Einstein_Head.jpg'));
      engine2.close();
      wikimedia.close();
    });

    test('callTool strips HTML entities from Wikimedia metadata', () async {
      final wikimedia = MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'query': {
                'pages': [
                  {
                    'title': 'File:Test &amp; Co.jpg',
                    'imageinfo': [
                      {
                        'url': 'https://upload.wikimedia.org/test.jpg',
                        'thumburl': 'https://upload.wikimedia.org/thumb/test.jpg',
                        'extmetadata': {
                          'Artist': {'value': 'Jane &amp; John &lt;3'},
                          'LicenseShortName': {'value': 'CC0'},
                        },
                      },
                    ],
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return _imageResponse();
      });
      final engine2 = ImageSearchMcpServerEngine(
        ddgsOverride: (query, max) async => const [],
        httpClient: wikimedia,
      );
      final resp = await engine2.handleMessage({
        'jsonrpc': '2.0',
        'id': 9,
        'method': 'tools/call',
        'params': {
          'name': 'image_search',
          'arguments': {'query': 'something'},
        },
      });
      final map = (resp as Map).cast<String, dynamic>();
      final result = (map['result'] as Map).cast<String, dynamic>();
      expect(result['isError'], isFalse);
      final text = (result['content'] as List).first['text'] as String;
      final data = jsonDecode(text) as Map<String, dynamic>;
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      expect(items, hasLength(1));
      expect(items.first['author'], 'Jane & John <3');
      engine2.close();
      wikimedia.close();
    });
  });

  group('clampImageMaxResults', () {
    test('clamps to 1-15 with default 10', () {
      expect(clampImageMaxResults(null), 10);
      expect(clampImageMaxResults(0), 1);
      expect(clampImageMaxResults(5), 5);
      expect(clampImageMaxResults(99), 15);
      expect(clampImageMaxResults('7'), 7);
      expect(clampImageMaxResults('abc'), 10);
    });
  });

  group('renderImageSearchResult', () {
    test('renders 1-based index and includes optional fields only when set', () {
      final json = renderImageSearchResult([
        ImageSearchHit(
          title: 'A',
          imageUrl: 'https://x/a.jpg',
          thumbnailUrl: 'https://x/a_t.jpg',
          width: '100',
          height: '200',
          sourceUrl: 'https://x/',
          backend: 'duckduckgo',
        ),
        ImageSearchHit(
          title: 'B',
          imageUrl: 'https://x/b.jpg',
          thumbnailUrl: '',
          backend: 'wikimedia',
          attribution: 'Foo',
          license: 'CC0',
        ),
      ]);
      final data = jsonDecode(json) as Map<String, dynamic>;
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      expect(items, hasLength(2));
      expect(items[0]['index'], 1);
      expect(items[0]['width'], '100');
      expect(items[1]['index'], 2);
      expect(items[1].containsKey('width'), isFalse);
      expect(items[1]['author'], 'Foo');
      expect(items[1]['license'], 'CC0');
      expect(items[1]['backend'], 'wikimedia');
    });
  });
}
