// Stage 2 wire-shape tests: a tool result carrying `[image:<path>]` must be
// promoted to the provider's native vision shape (or, for Chat Completions,
// the synthetic user-message fallback). Each test captures the real request
// body from `ChatApiService.sendMessageStream`.

import 'dart:convert';
import 'dart:io';

import 'package:OmniChat/core/providers/model_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:OmniChat/core/services/api/tool_result_images.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

class _CaptureServer {
  late HttpServer server;
  late String baseUrl;
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];
  int failNextWith400 = 0;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen(_handle);
  }

  Future<void> stop() async {
    await server.close(force: true);
  }

  void _handle(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    try {
      bodies.add(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      bodies.add(<String, dynamic>{'__raw': raw});
    }
    if (failNextWith400 > 0) {
      failNextWith400--;
      req.response.statusCode = 400;
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'error': {'message': 'image_url is not supported by this relay'},
        }),
      );
      await req.response.close();
      return;
    }
    req.response.headers.contentType = ContentType.json;
    if (req.uri.path.contains('/messages')) {
      req.response.write(
        jsonEncode({
          'content': [
            {'type': 'text', 'text': 'ok'},
          ],
          'stop_reason': 'end_turn',
          'usage': {'input_tokens': 5, 'output_tokens': 5},
        }),
      );
    } else if (req.uri.path.contains('streamGenerateContent')) {
      req.response.headers.contentType = ContentType('text', 'event-stream');
      req.response.write(
        'data: ${jsonEncode({
          'candidates': [
            {
              'content': {
                'role': 'model',
                'parts': [
                  {'text': 'ok'},
                ],
              },
              'finishReason': 'STOP',
            },
          ],
          'usageMetadata': {'promptTokenCount': 5, 'candidatesTokenCount': 5, 'totalTokenCount': 10},
        })}\n\n',
      );
    } else if (req.uri.path.contains('generateContent')) {
      req.response.write(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'role': 'model',
                'parts': [
                  {'text': 'ok'},
                ],
              },
              'finishReason': 'STOP',
            },
          ],
        }),
      );
    } else if (req.uri.path.contains('/responses')) {
      req.response.write(
        jsonEncode({
          'id': 'resp_1',
          'output': [
            {'type': 'output_text', 'text': 'ok'},
          ],
          'usage': {'input_tokens': 5, 'output_tokens': 5, 'total_tokens': 10},
        }),
      );
    } else {
      req.response.write(
        jsonEncode({
          'id': 'chat_1',
          'choices': [
            {
              'index': 0,
              'message': {'role': 'assistant', 'content': 'ok'},
              'finish_reason': 'stop',
            },
          ],
          'usage': {
            'prompt_tokens': 5,
            'completion_tokens': 5,
            'total_tokens': 10,
          },
        }),
      );
    }
    await req.response.close();
  }
}

void main() {
  late _CaptureServer server;
  late Directory workspace;
  late String imagePath;

  setUp(() async {
    server = _CaptureServer();
    await server.start();
    workspace = await Directory.systemTemp.createTemp('omnichat_wire_img');
    imagePath = p.join(workspace.path, 'shot.png');
    final image = img.Image(width: 32, height: 24, numChannels: 3);
    img.fill(image, color: img.ColorRgb8(200, 20, 20));
    await File(imagePath).writeAsBytes(img.encodePng(image));
  });

  tearDown(() async {
    await server.stop();
    await workspace.delete(recursive: true);
  });

  ToolImagePolicy policy() => ToolImagePolicy(workspaceRoot: workspace.path);

  List<Map<String, dynamic>> messages() => [
    {'role': 'user', 'content': 'inspect the screenshot'},
    {
      'role': 'assistant',
      'content': '\n\n',
      'tool_calls': [
        {
          'id': 'call_1',
          'type': 'function',
          'function': {
            'name': 'file_view_image',
            'arguments': jsonEncode({'path': 'shot.png'}),
          },
        },
      ],
    },
    {
      'role': 'tool',
      'name': 'file_view_image',
      'tool_call_id': 'call_1',
      'content': '[image:$imagePath]\nFormat: PNG; Size: 1 KB',
    },
  ];

  ProviderConfig config({
    required ProviderKind kind,
    required String modelId,
    bool? useResponseApi,
  }) {
    return ProviderConfig(
      id: 'stage2-${kind.name}',
      enabled: true,
      name: 'stage2-${kind.name}',
      apiKey: 'key',
      baseUrl: server.baseUrl,
      providerType: kind,
      useResponseApi: useResponseApi,
      models: [modelId],
      modelOverrides: <String, dynamic>{
        modelId: <String, dynamic>{
          'input': ['text', 'image'],
          'inputV': 2,
          'abilities': ['tool'],
        },
      },
    );
  }

  Future<void> send(
    ProviderConfig cfg,
    String modelId, {
    bool stream = false,
  }) async {
    await ChatApiService.sendMessageStream(
      config: cfg,
      modelId: modelId,
      messages: messages(),
      toolImagePolicy: policy(),
      requestId: 'stage2-${cfg.id}',
      stream: stream,
    ).toList();
  }

  test('Chat Completions retries once without images after HTTP 400', () async {
    server.failNextWith400 = 1;
    const modelId = 'gpt-test-model';
    final cfg = config(kind: ProviderKind.openai, modelId: modelId);
    final chunks = await ChatApiService.sendMessageStream(
      config: cfg,
      modelId: modelId,
      messages: messages(),
      toolImagePolicy: policy(),
      requestId: 'stage2-fallback',
      stream: false,
    ).toList();

    expect(server.bodies, hasLength(2));
    bool hasImagePart(Map<String, dynamic> body) {
      final raw = body['messages'];
      if (raw is! List) return false;
      for (final message in raw) {
        if (message is! Map) continue;
        final content = message['content'];
        if (content is! List) continue;
        if (content.any((part) => part is Map && part['type'] == 'image_url')) {
          return true;
        }
      }
      return false;
    }

    expect(hasImagePart(server.bodies[0]), isTrue);
    expect(hasImagePart(server.bodies[1]), isFalse);
    final statuses = chunks
        .expand((chunk) => chunk.toolImageStatuses ?? const [])
        .toList();
    expect(
      statuses.any(
        (status) => status.state == ToolImageSendState.providerRejected,
      ),
      isTrue,
    );
  });

  test('a rejected provider is remembered across agent rounds', () async {
    server.failNextWith400 = 1;
    const modelId = 'gpt-test-model';
    final cfg = config(kind: ProviderKind.openai, modelId: modelId);
    final sharedPolicy = policy();

    await ChatApiService.sendMessageStream(
      config: cfg,
      modelId: modelId,
      messages: messages(),
      toolImagePolicy: sharedPolicy,
      requestId: 'stage3-run-1',
      stream: false,
    ).toList();
    expect(sharedPolicy.providerRejectedThisRun, isTrue);
    expect(server.bodies, hasLength(2));

    server.bodies.clear();
    final secondChunks = await ChatApiService.sendMessageStream(
      config: cfg,
      modelId: modelId,
      messages: messages(),
      toolImagePolicy: sharedPolicy,
      requestId: 'stage3-run-2',
      stream: false,
    ).toList();

    expect(server.bodies, hasLength(1));
    final rawMessages = server.bodies.single['messages'];
    final hasImage =
        rawMessages is List &&
        rawMessages.any((message) {
          if (message is! Map) return false;
          final content = message['content'];
          return content is List &&
              content.any((part) => part is Map && part['type'] == 'image_url');
        });
    expect(hasImage, isFalse);
    final statuses = secondChunks
        .expand((chunk) => chunk.toolImageStatuses ?? const [])
        .toList();
    expect(
      statuses.any(
        (status) => status.state == ToolImageSendState.providerRejected,
      ),
      isTrue,
    );
  });

  test('a second 400 after the fallback surfaces', () async {
    server.failNextWith400 = 2;
    const modelId = 'gpt-test-model';
    final cfg = config(kind: ProviderKind.openai, modelId: modelId);

    await expectLater(
      ChatApiService.sendMessageStream(
        config: cfg,
        modelId: modelId,
        messages: messages(),
        toolImagePolicy: policy(),
        requestId: 'stage3-second-400',
        stream: false,
      ).toList(),
      throwsA(anything),
    );
    expect(server.bodies, hasLength(2));
  });

  test('Claude: tool_result carries text + image blocks', () async {
    const modelId = 'claude-test-model';
    final cfg = config(kind: ProviderKind.claude, modelId: modelId);
    await send(cfg, modelId);

    final body = server.bodies.single;
    final msgs = body['messages'] as List;
    final toolResult = msgs
        .cast<Map>()
        .expand((m) => (m['content'] is List) ? m['content'] as List : const [])
        .cast<Map>()
        .firstWhere((block) => block['type'] == 'tool_result');
    final content = toolResult['content'] as List;
    expect(content, isNotEmpty);
    expect(content.first['type'], 'text');
    final imageBlock = content.firstWhere((b) => b['type'] == 'image') as Map;
    expect(imageBlock['source']['type'], 'base64');
    expect(imageBlock['source']['media_type'], 'image/jpeg');
    expect((imageBlock['source']['data'] as String), isNotEmpty);
  });

  test(
    'Responses: function_call_output carries input_text + input_image',
    () async {
      const modelId = 'gpt-test-model';
      final cfg = config(
        kind: ProviderKind.openai,
        modelId: modelId,
        useResponseApi: true,
      );
      await send(cfg, modelId);

      final body = server.bodies.single;
      final input = body['input'] as List;
      final output = input.cast<Map>().firstWhere(
        (item) => item['type'] == 'function_call_output',
      );
      final parts = output['output'] as List;
      expect(parts.first['type'], 'input_text');
      final imagePart =
          parts.firstWhere((p) => p['type'] == 'input_image') as Map;
      expect(imagePart['image_url'], startsWith('data:image/jpeg;base64,'));
    },
  );

  test('Gemini 3: functionResponse.parts carries inlineData + id', () async {
    const modelId = 'gemini-3-pro-test';
    final cfg = config(kind: ProviderKind.google, modelId: modelId);
    await send(cfg, modelId);

    final body = server.bodies.single;
    final contents = body['contents'] as List;
    final functionResponse = contents
        .cast<Map>()
        .expand((c) => (c['parts'] is List) ? c['parts'] as List : const [])
        .cast<Map>()
        .map((part) => part['functionResponse'])
        .whereType<Map>()
        .first;
    expect(functionResponse['id'], 'call_1');
    final parts = functionResponse['parts'] as List;
    final inline = (parts.single as Map)['inlineData'] as Map;
    expect(inline['mimeType'], 'image/jpeg');
    expect((inline['data'] as String), isNotEmpty);
  });
  test(
    'Gemini 3 streaming: functionResponse.parts carries inlineData',
    () async {
      const modelId = 'gemini-3-pro-test';
      final cfg = config(kind: ProviderKind.google, modelId: modelId);
      await send(cfg, modelId, stream: true);

      final body = server.bodies.single;
      final contents = body['contents'] as List;
      final functionResponse = contents
          .cast<Map>()
          .expand((c) => (c['parts'] is List) ? c['parts'] as List : const [])
          .cast<Map>()
          .map((part) => part['functionResponse'])
          .whereType<Map>()
          .first;
      expect(functionResponse['id'], 'call_1');
      final parts = functionResponse['parts'] as List;
      final inline = (parts.single as Map)['inlineData'] as Map;
      expect(inline['mimeType'], 'image/jpeg');
      expect((inline['data'] as String), isNotEmpty);
    },
  );

  test(
    'Chat Completions: tool stays text and a synthetic user image follows',
    () async {
      const modelId = 'gpt-test-model';
      final cfg = config(
        kind: ProviderKind.openai,
        modelId: modelId,
        useResponseApi: false,
      );
      await send(cfg, modelId);

      final body = server.bodies.single;
      final msgs = body['messages'] as List;
      final toolMessage = msgs.cast<Map>().firstWhere(
        (m) => m['role'] == 'tool',
      );
      expect(toolMessage['content'], isA<String>());
      final last = msgs.last as Map;
      expect(last['role'], 'user');
      final parts = last['content'] as List;
      expect(parts.first['type'], 'text');
      final imagePart =
          parts.firstWhere((p) => p['type'] == 'image_url') as Map;
      expect(
        imagePart['image_url']['url'],
        startsWith('data:image/jpeg;base64,'),
      );
    },
  );

  test('non-vision Claude model keeps the text marker', () async {
    const modelId = 'claude-test-model';
    final cfg = ProviderConfig(
      id: 'stage2-no-vision',
      enabled: true,
      name: 'stage2-no-vision',
      apiKey: 'key',
      baseUrl: server.baseUrl,
      providerType: ProviderKind.claude,
      models: const [modelId],
      modelOverrides: <String, dynamic>{
        modelId: <String, dynamic>{
          'input': ['text'],
          'inputV': 2,
          'abilities': ['tool'],
        },
      },
    );
    await send(cfg, modelId);

    final body = server.bodies.single;
    final msgs = body['messages'] as List;
    final toolResult = msgs
        .cast<Map>()
        .expand((m) => (m['content'] is List) ? m['content'] as List : const [])
        .cast<Map>()
        .firstWhere((block) => block['type'] == 'tool_result');
    expect(toolResult['content'], isA<String>());
    expect(toolResult['content'], contains('[image:'));
  });
}
