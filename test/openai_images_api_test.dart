import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';

ProviderConfig _openAiConfig(
  String baseUrl, {
  bool useResponseApi = false,
  Map<String, dynamic> modelOverrides = const {},
}) {
  return ProviderConfig(
    id: 'OpenAITest',
    enabled: true,
    name: 'OpenAITest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
    useResponseApi: useResponseApi,
    modelOverrides: modelOverrides,
  );
}

String _baseUrl(HttpServer server) {
  return 'http://${server.address.address}:${server.port}/v1';
}

Future<List<int>> _readBytes(HttpRequest request) async {
  final chunks = <int>[];
  await for (final chunk in request) {
    chunks.addAll(chunk);
  }
  return chunks;
}

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

void main() {
  group('ChatApiService.shouldUseOpenAIImagesApi', () {
    test('routes image-output model ids (inferred from id)', () {
      final cfg = _openAiConfig('http://127.0.0.1:9/v1');
      for (final id in [
        'gpt-image-1',
        'chatgpt-image-1',
        'agnes-image-xl',
        'sensenova-u1-fast',
        'dall-e-2',
        'dall-e-3',
        'GPT-IMAGE-1',
      ]) {
        expect(
          ChatApiService.shouldUseOpenAIImagesApi(cfg, id),
          isTrue,
          reason: '$id should route via Images API',
        );
      }
    });

    test('does not route plain chat models', () {
      final cfg = _openAiConfig('http://127.0.0.1:9/v1');
      expect(
        ChatApiService.shouldUseOpenAIImagesApi(cfg, 'gpt-4o'),
        isFalse,
      );
    });

    test('output-modality override routes non-whitelist models', () {
      // Model basic-settings page marks output as image -> route via Images API.
      final cfg = _openAiConfig(
        'http://127.0.0.1:9/v1',
        modelOverrides: const {
          'flux-1': {'output': ['image']},
        },
      );
      expect(
        ChatApiService.shouldUseOpenAIImagesApi(cfg, 'flux-1'),
        isTrue,
      );
      // A model whose output is text-only stays off.
      final cfg2 = _openAiConfig(
        'http://127.0.0.1:9/v1',
        modelOverrides: const {
          'flux-1': {'output': ['text']},
        },
      );
      expect(
        ChatApiService.shouldUseOpenAIImagesApi(cfg2, 'flux-1'),
        isFalse,
      );
    });

    test('useImagesApi: false turns off routing for an image-output model', () {
      // Image-output model (e.g. hybrid, or provider serving images via chat
      // completions): user switches the "Use Images API" toggle off.
      final cfg = _openAiConfig(
        'http://127.0.0.1:9/v1',
        modelOverrides: const {
          'gpt-image-1': {'useImagesApi': false},
        },
      );
      expect(
        ChatApiService.shouldUseOpenAIImagesApi(cfg, 'gpt-image-1'),
        isFalse,
      );
    });

    test('image-output model defaults ON without an explicit toggle', () {
      final cfg = _openAiConfig(
        'http://127.0.0.1:9/v1',
        modelOverrides: const {
          'gpt-image-1': {'output': ['image']},
        },
      );
      expect(
        ChatApiService.shouldUseOpenAIImagesApi(cfg, 'gpt-image-1'),
        isTrue,
      );
    });

    test('non-image models cannot opt in via useImagesApi', () {
      // The toggle only exists for image-output models, so there is no opt-in.
      final cfg = _openAiConfig(
        'http://127.0.0.1:9/v1',
        modelOverrides: const {
          'gpt-4o': {'useImagesApi': true},
        },
      );
      expect(
        ChatApiService.shouldUseOpenAIImagesApi(cfg, 'gpt-4o'),
        isFalse,
      );
    });

    test('non-OpenAI providers never route via Images API', () {
      final cfg = ProviderConfig(
        id: 'GoogleTest',
        enabled: true,
        name: 'GoogleTest',
        apiKey: 'test-key',
        baseUrl: 'http://127.0.0.1:9/v1',
        providerType: ProviderKind.google,
        modelOverrides: const {
          'gemini-3-pro-image-preview': {'output': ['image']},
        },
      );
      expect(
        ChatApiService.shouldUseOpenAIImagesApi(
          cfg,
          'gemini-3-pro-image-preview',
        ),
        isFalse,
      );
    });
  });

  group('ChatApiService.isOpenAIImageOutputModel', () {
    test('image-output model ids are image models', () {
      final cfg = _openAiConfig('http://127.0.0.1:9/v1');
      for (final id in ['gpt-image-1', 'dall-e-3', 'GPT-IMAGE-1']) {
        expect(
          ChatApiService.isOpenAIImageOutputModel(cfg, id),
          isTrue,
          reason: '$id should be an image-output model',
        );
      }
    });

    test('plain chat models are not image models', () {
      final cfg = _openAiConfig('http://127.0.0.1:9/v1');
      expect(
        ChatApiService.isOpenAIImageOutputModel(cfg, 'gpt-4o'),
        isFalse,
      );
    });

    test('independent of the useImagesApi toggle', () {
      // The ratio button / guards judge by output modality, not by the route:
      // even with the toggle off the model may still emit images via chat
      // completions.
      final cfg = _openAiConfig(
        'http://127.0.0.1:9/v1',
        modelOverrides: const {
          'gpt-image-1': {'useImagesApi': false},
        },
      );
      expect(
        ChatApiService.isOpenAIImageOutputModel(cfg, 'gpt-image-1'),
        isTrue,
      );
    });
  });

  group('ChatApiService.isOpenAIImageEditModel', () {
    test('input+output image models are edit-capable', () {
      final cfg = _openAiConfig('http://127.0.0.1:9/v1');
      for (final id in ['gpt-image-1', 'chatgpt-image-1', 'dall-e-2']) {
        expect(
          ChatApiService.isOpenAIImageEditModel(cfg, id),
          isTrue,
          reason: '$id should support image edits',
        );
      }
    });

    test('text-to-image-only models are not edit-capable', () {
      final cfg = _openAiConfig('http://127.0.0.1:9/v1');
      for (final id in ['dall-e-3', 'sensenova-u1-fast']) {
        expect(
          ChatApiService.isOpenAIImageEditModel(cfg, id),
          isFalse,
          reason: '$id is text-to-image only',
        );
      }
    });

    test('plain chat models are not edit-capable', () {
      final cfg = _openAiConfig('http://127.0.0.1:9/v1');
      expect(
        ChatApiService.isOpenAIImageEditModel(cfg, 'gpt-4o'),
        isFalse,
      );
    });

    test('user-configured image input overrides inference', () {
      // User explicitly marks dall-e-3 as image-input capable -> edits allowed.
      final cfg = _openAiConfig(
        'http://127.0.0.1:9/v1',
        modelOverrides: const {
          'dall-e-3': {'input': ['image']},
        },
      );
      expect(
        ChatApiService.isOpenAIImageEditModel(cfg, 'dall-e-3'),
        isTrue,
      );
    });

    test('non-OpenAI providers are never edit-capable', () {
      final cfg = ProviderConfig(
        id: 'GoogleTest',
        enabled: true,
        name: 'GoogleTest',
        apiKey: 'test-key',
        baseUrl: 'http://127.0.0.1:9/v1',
        providerType: ProviderKind.google,
        modelOverrides: const {
          'gemini-3-pro-image-preview': {
            'input': ['image'],
            'output': ['image'],
          },
        },
      );
      expect(
        ChatApiService.isOpenAIImageEditModel(
          cfg,
          'gemini-3-pro-image-preview',
        ),
        isFalse,
      );
    });
  });

  group('OpenAI Images API', () {
    test('routes image model without input images to generations', () async {
      late Uri requestUri;
      late Map<String, dynamic> requestBody;
      late String? authorization;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestUri = request.uri;
        authorization = request.headers.value(HttpHeaders.authorizationHeader);
        requestBody =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'url': 'https://example.com/generated.png'},
            ],
            'usage': {'input_tokens': 3, 'output_tokens': 5},
          }),
        );
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _openAiConfig(_baseUrl(server)),
        modelId: 'gpt-image-2',
        messages: const [
          {'role': 'user', 'content': 'draw a tabby cat'},
        ],
      ).toList();

      expect(requestUri.path, '/v1/images/generations');
      expect(authorization, 'Bearer test-key');
      expect(requestBody['model'], 'gpt-image-2');
      expect(requestBody['prompt'], 'draw a tabby cat');
      expect(chunks, hasLength(1));
      expect(
        chunks.single.content,
        '![image](https://example.com/generated.png)',
      );
      expect(chunks.single.usage?.totalTokens, 8);
    });

    test(
      'routes image models to Images API even when Responses is enabled',
      () async {
        late Uri requestUri;
        late Map<String, dynamic> requestBody;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          requestUri = request.uri;
          requestBody =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>;
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'data': [
                {'url': 'https://example.com/generated.png'},
              ],
            }),
          );
          await request.response.close();
        });

        await ChatApiService.sendMessageStream(
          config: _openAiConfig(_baseUrl(server), useResponseApi: true),
          modelId: 'gpt-image-2',
          messages: const [
            {'role': 'user', 'content': 'generate an empty image'},
          ],
        ).toList();

        expect(requestUri.path, '/v1/images/generations');
        expect(requestBody['model'], 'gpt-image-2');
        expect(requestBody.containsKey('input'), isFalse);
        expect(requestBody.containsKey('stream'), isFalse);
      },
    );

    test('output-modality override routes a non-whitelist model', () async {
      late Uri requestUri;
      late Map<String, dynamic> requestBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestUri = request.uri;
        requestBody =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'url': 'https://example.com/flux.png'},
            ],
          }),
        );
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _openAiConfig(
          _baseUrl(server),
          modelOverrides: const {
            'flux-1': {'output': ['image']},
          },
        ),
        modelId: 'flux-1',
        messages: const [
          {'role': 'user', 'content': 'a cat, oil painting'},
        ],
      ).toList();

      expect(requestUri.path, '/v1/images/generations');
      expect(requestBody['model'], 'flux-1');
      expect(chunks.single.content, '![image](https://example.com/flux.png)');
    });

    test('injects size param from the aspect-ratio selector', () async {
      late Map<String, dynamic> requestBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestBody =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'url': 'https://example.com/wide.png'},
            ],
          }),
        );
        await request.response.close();
      });

      await ChatApiService.sendMessageStream(
        config: _openAiConfig(_baseUrl(server)),
        modelId: 'gpt-image-2',
        messages: const [
          {'role': 'user', 'content': 'a landscape'},
        ],
        imageAspectRatio: '16:9',
      ).toList();

      expect(requestBody['size'], '1792x1024');
    });

    test('custom body size wins over the automatic ratio conversion', () async {
      late Map<String, dynamic> requestBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestBody =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'url': 'https://example.com/custom.png'},
            ],
          }),
        );
        await request.response.close();
      });

      await ChatApiService.sendMessageStream(
        config: _openAiConfig(_baseUrl(server)),
        modelId: 'gpt-image-2',
        messages: const [
          {'role': 'user', 'content': 'a cat'},
        ],
        imageAspectRatio: '16:9',
        extraBody: const {'size': '640x480'},
      ).toList();

      expect(requestBody['size'], '640x480');
    });

    test('dall-e-3 falls back 3:4 to 1024x1792 and notes the reply',
        () async {
      late Map<String, dynamic> requestBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestBody =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'url': 'https://example.com/dalle.png'},
            ],
          }),
        );
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _openAiConfig(_baseUrl(server)),
        modelId: 'dall-e-3',
        messages: const [
          {'role': 'user', 'content': 'a portrait'},
        ],
        imageAspectRatio: '3:4',
      ).toList();

      expect(requestBody['size'], '1024x1792');
      expect(chunks.single.content, contains('dall-e-3 does not support 3:4'));
    });

    test('dall-e-3 falls back 2:3 to 1024x1792 and notes the reply',
        () async {
      late Map<String, dynamic> requestBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestBody =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'url': 'https://example.com/dalle-23.png'},
            ],
          }),
        );
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _openAiConfig(_baseUrl(server)),
        modelId: 'dall-e-3',
        messages: const [
          {'role': 'user', 'content': 'a portrait'},
        ],
        imageAspectRatio: '2:3',
      ).toList();

      expect(requestBody['size'], '1024x1792');
      expect(chunks.single.content, contains('dall-e-3 does not support 2:3'));
    });

    test('maps 2:3 and 3:2 to gpt-image sizes', () async {
      late List<Map<String, dynamic>> bodies;
      bodies = [];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        bodies.add(jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'url': 'https://example.com/size.png'},
            ],
          }),
        );
        await request.response.close();
      });

      await ChatApiService.sendMessageStream(
        config: _openAiConfig(_baseUrl(server)),
        modelId: 'gpt-image-1',
        messages: const [
          {'role': 'user', 'content': 'a cat'},
        ],
        imageAspectRatio: '2:3',
      ).toList();
      await ChatApiService.sendMessageStream(
        config: _openAiConfig(_baseUrl(server)),
        modelId: 'gpt-image-1',
        messages: const [
          {'role': 'user', 'content': 'a cat'},
        ],
        imageAspectRatio: '3:2',
      ).toList();

      expect(bodies, hasLength(2));
      expect(bodies[0]['size'], '1024x1536');
      expect(bodies[1]['size'], '1536x1024');
    });

    test('auto ratio sends size auto for gpt-image models', () async {
      late Map<String, dynamic> requestBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestBody =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'url': 'https://example.com/auto-gpt.png'},
            ],
          }),
        );
        await request.response.close();
      });

      await ChatApiService.sendMessageStream(
        config: _openAiConfig(
          _baseUrl(server),
          modelOverrides: const {
            'gpt-image-1': {'useAspectRatioParam': true},
          },
        ),
        modelId: 'gpt-image-1',
        messages: const [
          {'role': 'user', 'content': 'edit to match the source'},
        ],
        imageAspectRatio: 'auto',
      ).toList();

      expect(requestBody['size'], 'auto');
      expect(requestBody.containsKey('aspect_ratio'), isFalse);
    });

    test('auto ratio omits size for non-gpt-image models', () async {
      late Map<String, dynamic> requestBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestBody =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'url': 'https://example.com/auto-dalle.png'},
            ],
          }),
        );
        await request.response.close();
      });

      await ChatApiService.sendMessageStream(
        config: _openAiConfig(
          _baseUrl(server),
          modelOverrides: const {
            'dall-e-3': {'useAspectRatioParam': true},
          },
        ),
        modelId: 'dall-e-3',
        messages: const [
          {'role': 'user', 'content': 'a cat'},
        ],
        imageAspectRatio: 'auto',
      ).toList();

      expect(requestBody.containsKey('size'), isFalse);
      expect(requestBody.containsKey('aspect_ratio'), isFalse);
    });

    test('useAspectRatioParam override passes aspect_ratio through', () async {
      late Map<String, dynamic> requestBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestBody =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'url': 'https://example.com/nano.png'},
            ],
          }),
        );
        await request.response.close();
      });

      await ChatApiService.sendMessageStream(
        config: _openAiConfig(
          _baseUrl(server),
          modelOverrides: const {
            'nano-banana-2': {
              'output': ['image'],
              'useAspectRatioParam': true,
            },
          },
        ),
        modelId: 'nano-banana-2',
        messages: const [
          {'role': 'user', 'content': 'a cat'},
        ],
        imageAspectRatio: '9:16',
      ).toList();

      expect(requestBody['aspect_ratio'], '9:16');
      expect(requestBody.containsKey('size'), isFalse);
    });

    test('toggle off routes image model to chat completions with size',
        () async {
      // "Use Images API" turned off: the model still outputs images via chat
      // completions, so the selected ratio is injected as `size` there too.
      late Uri requestUri;
      late Map<String, dynamic> requestBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestUri = request.uri;
        requestBody =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': 'text reply',
                },
              },
            ],
          }),
        );
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _openAiConfig(
          _baseUrl(server),
          modelOverrides: const {
            'gpt-image-1': {'useImagesApi': false},
          },
        ),
        modelId: 'gpt-image-1',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        stream: false,
        imageAspectRatio: '16:9',
      ).toList();

      expect(requestUri.path, '/v1/chat/completions');
      expect(requestBody['size'], '1792x1024');
      expect(chunks.map((c) => c.content).join(), contains('text reply'));
    });

    test('routes image model with input image to edits multipart', () async {
      late Uri requestUri;
      late String contentType;
      late String requestBody;
      final tempDir = await Directory.systemTemp.createTemp(
        'kelivo_openai_image_edit_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final inputImage = File('${tempDir.path}/source.png');
      await inputImage.writeAsBytes(const [1, 2, 3, 4]);

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestUri = request.uri;
        contentType = request.headers.contentType?.mimeType ?? '';
        requestBody = latin1.decode(await _readBytes(request));
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'url': 'https://example.com/edited.png'},
            ],
          }),
        );
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _openAiConfig(_baseUrl(server)),
        modelId: 'gpt-image-2',
        messages: const [
          {'role': 'user', 'content': 'make the background blue'},
        ],
        userImagePaths: [inputImage.path],
      ).toList();

      expect(requestUri.path, '/v1/images/edits');
      expect(contentType, 'multipart/form-data');
      expect(requestBody, contains('name="model"'));
      expect(requestBody, contains('gpt-image-2'));
      expect(requestBody, contains('name="prompt"'));
      expect(requestBody, contains('make the background blue'));
      expect(requestBody, contains('name="image[]"'));
      expect(requestBody, contains('content-type: image/png'));
      expect(requestBody, contains('filename="source.png"'));
      expect(chunks.single.content, '![image](https://example.com/edited.png)');
    });

    test('routes Agnes host image input to generations with extra_body.image',
        () async {
      late Uri requestUri;
      late String contentType;
      late Map<String, dynamic> requestBody;
      final tempDir = await Directory.systemTemp.createTemp(
        'kelivo_agnes_edit_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final inputImage = File('${tempDir.path}/source.png');
      await inputImage.writeAsBytes(const [1, 2, 3, 4]);

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestUri = request.uri;
        contentType = request.headers.contentType?.mimeType ?? '';
        requestBody = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'url': 'https://example.com/agnes-edited.png'},
            ],
          }),
        );
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _openAiConfig(
          'http://127.0.0.1:${server.port}/agnes/v1',
        ),
        modelId: 'gpt-image-2',
        messages: const [
          {'role': 'user', 'content': 'make the background blue'},
        ],
        userImagePaths: [inputImage.path],
      ).toList();

      expect(requestUri.path, '/agnes/v1/images/generations');
      expect(contentType, 'application/json');
      expect(requestBody['model'], 'gpt-image-2');
      expect(requestBody['prompt'], 'make the background blue');
      expect(
        requestBody['extra_body'],
        {
          'image': ['data:image/png;base64,AQIDBA=='],
        },
      );
      expect(
        chunks.single.content,
        '![image](https://example.com/agnes-edited.png)',
      );
    });

    test('passes remote URL images through Agnes extra_body.image', () async {
      late Map<String, dynamic> requestBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestBody = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'url': 'https://example.com/agnes-url-edit.png'},
            ],
          }),
        );
        await request.response.close();
      });

      await ChatApiService.sendMessageStream(
        config: _openAiConfig(
          'http://127.0.0.1:${server.port}/agnes/v1',
        ),
        modelId: 'gpt-image-2',
        messages: const [
          {
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': 'restyle this'},
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'https://example.com/source.png',
                },
              },
            ],
          },
        ],
      ).toList();

      expect(
        requestBody['extra_body'],
        {
          'image': ['https://example.com/source.png'],
        },
      );
    });

    test('sets jpeg content type for jpg image edit uploads', () async {
      late String requestBody;
      final tempDir = await Directory.systemTemp.createTemp(
        'kelivo_openai_jpeg_edit_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final inputImage = File('${tempDir.path}/source.jpg');
      await inputImage.writeAsBytes(const [1, 2, 3, 4]);

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestBody = latin1.decode(await _readBytes(request));
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'url': 'https://example.com/edited.jpg'},
            ],
          }),
        );
        await request.response.close();
      });

      await ChatApiService.sendMessageStream(
        config: _openAiConfig(_baseUrl(server)),
        modelId: 'gpt-image-2',
        messages: const [
          {'role': 'user', 'content': 'make it cinematic'},
        ],
        userImagePaths: [inputImage.path],
      ).toList();

      expect(requestBody, contains('filename="source.jpg"'));
      expect(requestBody, contains('content-type: image/jpeg'));
    });

    test('routes structured user input images to edits multipart', () async {
      late Uri requestUri;
      late String contentType;
      late String requestBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestUri = request.uri;
        contentType = request.headers.contentType?.mimeType ?? '';
        requestBody = latin1.decode(await _readBytes(request));
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'url': 'https://example.com/structured-edit.png'},
            ],
          }),
        );
        await request.response.close();
      });

      await ChatApiService.sendMessageStream(
        config: _openAiConfig(_baseUrl(server)),
        modelId: 'gpt-image-2',
        messages: const [
          {
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': 'make the background blue'},
              {
                'type': 'input_image',
                'input_image': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': ['AQIDBA=='],
                },
              },
            ],
          },
        ],
      ).toList();

      expect(requestUri.path, '/v1/images/edits');
      expect(contentType, 'multipart/form-data');
      expect(requestBody, contains('name="prompt"'));
      expect(requestBody, contains('make the background blue'));
      expect(requestBody, contains('name="image[]"'));
      expect(requestBody, contains('content-type: image/png'));
    });

    test('rejects dall-e-3 edits before sending a request', () async {
      await expectLater(
        ChatApiService.sendMessageStream(
          config: _openAiConfig('http://127.0.0.1:9/v1'),
          modelId: 'dall-e-3',
          messages: const [
            {'role': 'user', 'content': 'edit this image'},
          ],
          userImagePaths: const ['/tmp/source.png'],
        ).toList(),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            contains('does not support image edits'),
          ),
        ),
      );
    });

    test('saves base64 image responses with requested output format', () async {
      late Map<String, dynamic> requestBody;
      final tempDir = await Directory.systemTemp.createTemp(
        'kelivo_openai_b64_output_',
      );
      final previousPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
      addTearDown(() async {
        PathProviderPlatform.instance = previousPathProvider;
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestBody =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {
                'b64_json': base64Encode(const [1, 2, 3, 4]),
              },
            ],
          }),
        );
        await request.response.close();
      });

      final chunks = await ChatApiService.sendMessageStream(
        config: _openAiConfig(_baseUrl(server)),
        modelId: 'gpt-image-2',
        messages: const [
          {'role': 'user', 'content': 'draw a tabby cat'},
        ],
        extraBody: const {'output_format': 'webp'},
      ).toList();

      final imagePath = RegExp(
        r'!\[image\]\(([^)]+)\)',
      ).firstMatch(chunks.single.content)!.group(1)!;
      expect(requestBody['output_format'], 'webp');
      expect(imagePath.endsWith('.webp'), isTrue);
      expect(await File(imagePath).readAsBytes(), const [1, 2, 3, 4]);
    });

    test(
      'throws instead of rendering null when base64 image save fails',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'kelivo_openai_b64_failure_',
        );
        final previousPathProvider = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
        addTearDown(() async {
          PathProviderPlatform.instance = previousPathProvider;
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          await request.drain<void>();
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'data': [
                {'b64_json': 'not valid base64'},
              ],
            }),
          );
          await request.response.close();
        });

        await expectLater(
          ChatApiService.sendMessageStream(
            config: _openAiConfig(_baseUrl(server)),
            modelId: 'gpt-image-2',
            messages: const [
              {'role': 'user', 'content': 'draw a tabby cat'},
            ],
          ).toList(),
          throwsA(
            isA<FileSystemException>().having(
              (error) => error.message,
              'message',
              contains('Failed to save OpenAI Images API base64 image'),
            ),
          ),
        );
      },
    );

    test(
      'uses the latest assistant image as edit input for follow-up turns',
      () async {
        late Uri requestUri;
        late String contentType;
        late String requestBody;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          requestUri = request.uri;
          contentType = request.headers.contentType?.mimeType ?? '';
          requestBody = latin1.decode(await _readBytes(request));
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'data': [
                {'url': 'https://example.com/follow-up-edit.png'},
              ],
            }),
          );
          await request.response.close();
        });

        final chunks = await ChatApiService.sendMessageStream(
          config: _openAiConfig(_baseUrl(server)),
          modelId: 'gpt-image-2',
          messages: const [
            {'role': 'user', 'content': 'draw a tabby cat'},
            {
              'role': 'assistant',
              'content': '![image](data:image/png;base64,AQIDBA==)',
            },
            {'role': 'user', 'content': 'make it realistic'},
          ],
        ).toList();

        expect(requestUri.path, '/v1/images/edits');
        expect(contentType, 'multipart/form-data');
        expect(requestBody, contains('name="image[]"'));
        expect(requestBody, contains('make it realistic'));
        expect(requestBody, isNot(contains('draw a tabby cat')));
        expect(requestBody, isNot(contains('Original image request:')));
        expect(requestBody, isNot(contains('Edit request:')));
        expect(
          chunks.single.content,
          '![image](https://example.com/follow-up-edit.png)',
        );
      },
    );

    test(
      'throws useful exception on non-success Images API response',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          await request.drain<void>();
          request.response.statusCode = HttpStatus.badRequest;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'bad image request'}));
          await request.response.close();
        });

        expect(
          ChatApiService.sendMessageStream(
            config: _openAiConfig(_baseUrl(server)),
            modelId: 'gpt-image-2',
            messages: const [
              {'role': 'user', 'content': 'draw'},
            ],
          ).toList(),
          throwsA(
            isA<HttpException>().having(
              (error) => error.message,
              'message',
              contains('HTTP 400'),
            ),
          ),
        );
      },
    );
  });
}
