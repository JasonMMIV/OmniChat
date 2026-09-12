// Regression tests for the DeepSeek v4.1 Flash HTTP 400
// `param: messages.N.content` failure (wire-capture 2026-09-12, Android):
// chat-completions requests carried a `content` array whose only block was
// `image_url` (no text block) and role:'tool' / assistant content could be
// non-strings. Strict OpenAI-compatible validators reject both shapes; the
// transport now normalizes them before encoding (chat-completions path only).
//
// The normalizer itself is private, so these tests exercise it end-to-end
// through [ChatApiService.sendMessageStream] against a local HTTP server
// that captures the wire body and asserts the DeepSeek-visible shape.

import 'dart:convert';
import 'dart:io';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderConfig _deepseekConfig(String baseUrl) => ProviderConfig(
  id: 'deepseek-test',
  enabled: true,
  name: 'deepseek-test',
  apiKey: 'test-key',
  baseUrl: baseUrl,
  providerType: ProviderKind.openai,
  models: const ['deepseek-v4.1-flash'],
  modelOverrides: const {
    'deepseek-v4.1-flash': {
      // Reasoning ability on: exercises the DeepSeek echo knob path too.
      'abilities': ['tool', 'reasoning'],
      'input': ['text', 'image'],
      'output': ['text'],
    },
  },
);

class _Server {
  final List<Map<String, dynamic>> bodies = [];
  late HttpServer server;
  late String baseUrl;

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
    req.response.headers.contentType = ContentType.parse('text/event-stream');
    req.response.write(
      [
        'data: ${jsonEncode({
          'id': '1',
          'object': 'chat.completion.chunk',
          'choices': [
            {
              'index': 0,
              'delta': {'content': 'ok'},
              'finish_reason': 'stop',
            },
          ],
        })}',
        'data: [DONE]',
        '',
      ].join('\n'),
    );
    await req.response.close();
  }
}

void main() {
  late _Server fix;

  setUp(() async {
    fix = _Server();
    await fix.start();
  });

  tearDown(() async {
    await fix.stop();
  });

  test('image-only content array gains a text block (DeepSeek 400 fix)', () async {
    // Shape produced by the multimodal parts builder when a message contains
    // images but its text part is empty: an image_url-only array.
    await ChatApiService.sendMessageStream(
      config: _deepseekConfig(fix.baseUrl),
      modelId: 'deepseek-v4.1-flash',
      messages: const [
        {'role': 'user', 'content': 'describe the image'},
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,aGVsbG8='},
            },
          ],
        },
      ],
      requestId: 'ds-image-only',
    ).toList();

    expect(fix.bodies, hasLength(1));
    final msgs = fix.bodies.single['messages'] as List;
    final content = (msgs.last as Map)['content'] as List;
    expect(content, isNotEmpty);
    expect(
      content.every((b) => b is Map && (b['type'] ?? '') == 'text'),
      isFalse,
      reason: 'the image block must survive normalization',
    );
    expect(
      content.any((b) => b is Map && (b['type'] ?? '') == 'text'),
      isTrue,
      reason: 'a text block must exist so strict validators accept the array',
    );
  });

  test('assistant and tool messages always carry string content', () async {
    await ChatApiService.sendMessageStream(
      config: _deepseekConfig(fix.baseUrl),
      modelId: 'deepseek-v4.1-flash',
      messages: const [
        {'role': 'user', 'content': 'hi'},
        {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'thinking out loud'},
            {
              'type': 'image_url',
              'image_url': {'url': 'https://example.com/a.png'},
            },
          ],
          'reasoning_content': '(no reasoning content)',
        },
        {
          'role': 'tool',
          'tool_call_id': 'call_1',
          'name': 'file_read',
          'content': [
            {'type': 'text', 'text': 'file body'},
          ],
        },
      ],
      requestId: 'ds-string-content',
    ).toList();

    expect(fix.bodies, hasLength(1));
    final msgs = fix.bodies.single['messages'] as List;
    for (final m in msgs) {
      final role = (m as Map)['role'] as String;
      if (role == 'assistant' || role == 'tool') {
        expect(
          m['content'],
          isA<String>(),
          reason: 'role $role content must be a plain string for DeepSeek',
        );
      }
    }
    // The image inside the assistant array is preserved as Markdown.
    final assistant = msgs.firstWhere((m) => (m as Map)['role'] == 'assistant');
    expect(
      (assistant as Map)['content'] as String,
      contains('![image](https://example.com/a.png)'),
    );
  });

  test('unknown content blocks are dropped instead of forwarded', () async {
    await ChatApiService.sendMessageStream(
      config: _deepseekConfig(fix.baseUrl),
      modelId: 'deepseek-v4.1-flash',
      messages: const [
        {
          'role': 'user',
          'content': [
            {'type': 'future_block', 'future_block': {'x': 1}},
            {'type': 'text', 'text': 'hello'},
          ],
        },
      ],
      requestId: 'ds-unknown-block',
    ).toList();

    expect(fix.bodies, hasLength(1));
    final msgs = fix.bodies.single['messages'] as List;
    // List content is a request-side block list: it is flattened to plain
    // text, so the unknown block is dropped and only the text survives.
    final content = (msgs.first as Map)['content'];
    expect(content, isA<String>());
    expect(content as String, contains('hello'));
    expect(content.contains('future_block'), isFalse);
  });

  test('bare strings inside a content array keep their text', () async {
    await ChatApiService.sendMessageStream(
      config: _deepseekConfig(fix.baseUrl),
      modelId: 'deepseek-v4.1-flash',
      messages: const [
        {
          'role': 'user',
          'content': [
            'plain string part',
            {
              'type': 'image_url',
              // data: URLs skip the remote-image reachability probe and are
              // always converted to image parts.
              'image_url': {'url': 'data:image/png;base64,aGVsbG8='},
            },
          ],
        },
      ],
      requestId: 'ds-bare-string',
    ).toList();

    expect(fix.bodies, hasLength(1));
    final msgs = fix.bodies.single['messages'] as List;
    final content = (msgs.first as Map)['content'] as List;
    final textBlocks = content
        .whereType<Map>()
        .where((b) => b['type'] == 'text')
        .map((b) => b['text'])
        .join('\n');
    expect(textBlocks, contains('plain string part'));
    expect(
      content.any(
        (b) =>
            b is Map &&
            b['type'] == 'image_url' &&
            (b['image_url'] as Map)['url'] == 'data:image/png;base64,aGVsbG8=',
      ),
      isTrue,
      reason: 'the image block must survive alongside the string text',
    );
  });

  test('plain string messages pass through untouched', () async {
    await ChatApiService.sendMessageStream(
      config: _deepseekConfig(fix.baseUrl),
      modelId: 'deepseek-v4.1-flash',
      messages: const [
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': 'hello'},
      ],
      requestId: 'ds-plain',
    ).toList();

    expect(fix.bodies, hasLength(1));
    final msgs = fix.bodies.single['messages'] as List;
    expect((msgs.first as Map)['content'], 'sys');
    expect((msgs.last as Map)['content'], 'hello');
  });
}
