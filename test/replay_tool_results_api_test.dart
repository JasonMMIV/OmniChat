// Integration tests for cross-turn tool result replay conversion in
// [ChatApiService.sendMessageStream]. Each test stands up an in-process
// HTTP server, sends messages that contain replayed OpenAI-format tool
// messages (role:'tool' + assistant tool_calls), and asserts the request
// body is converted to the provider-specific schema (OpenAI / Claude /
// Gemini).
//
// The replayed message shape matches what
// [MessageBuilderService.buildApiMessages] emits with includeToolMessages:
//   - {'role':'assistant','content':'\n\n','tool_calls':[{id,type,function}]}
//   - {'role':'tool','name','tool_call_id','content'}

import 'dart:convert';
import 'dart:io';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tool messages replayed by the builder (OpenAI neutral format).
final List<Map<String, dynamic>> _replayedToolMessages = [
  {
    'role': 'assistant',
    'content': '\n\n',
    'tool_calls': [
      {
        'id': 'call_1',
        'type': 'function',
        'function': {'name': 'file_read', 'arguments': '{"path": "main.dart"}'},
      },
    ],
  },
  {
    'role': 'tool',
    'name': 'file_read',
    'tool_call_id': 'call_1',
    'content': 'file contents',
  },
];

/// Captures request bodies and returns provider-appropriate SSE responses.
class _CaptureServer {
  _CaptureServer();

  late HttpServer server;
  late String baseUrl;
  final List<Map<String, dynamic>> bodies = [];

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
      bodies.add({'__raw': raw});
    }
    // All tests use stream:false, so respond with complete JSON bodies.
    req.response.headers.contentType =
        ContentType.parse('application/json');
    if (req.uri.path.contains('/messages')) {
      // Claude non-streaming response.
      req.response.write(
        jsonEncode({
          'content': [
            {'type': 'text', 'text': 'ok'},
          ],
          'stop_reason': 'end_turn',
          'usage': {'input_tokens': 5, 'output_tokens': 5},
        }),
      );
    } else if (req.uri.path.contains('generateContent')) {
      // Gemini non-streaming response.
      req.response.write(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'role': 'model',
                'parts': [{'text': 'ok'}],
              },
              'finishReason': 'STOP',
            },
          ],
        }),
      );
    } else if (req.uri.path.contains('/responses')) {
      // OpenAI Responses API non-streaming response.
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
      // OpenAI chat completions non-streaming response.
      req.response.write(
        jsonEncode({
          'id': '1',
          'object': 'chat.completion',
          'choices': [
            {'message': {'role': 'assistant', 'content': 'ok'}, 'finish_reason': 'stop'},
          ],
          'usage': {'prompt_tokens': 5, 'completion_tokens': 5, 'total_tokens': 10},
        }),
      );
    }
    await req.response.close();
  }
}

void main() {
  late _CaptureServer server;

  setUp(() async {
    server = _CaptureServer();
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  group('cross-turn tool result replay conversion', () {
    test('OpenAI: preserves role tool + tool_calls in the request', () async {
      final config = ProviderConfig(
        id: 'openai-test',
        enabled: true,
        name: 'openai-test',
        apiKey: 'key',
        baseUrl: server.baseUrl,
        providerType: ProviderKind.openai,
        models: const ['gpt-4o'],
      );
      await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'gpt-4o',
        messages: [
          const {'role': 'user', 'content': 'read the file'},
          ..._replayedToolMessages,
          const {'role': 'user', 'content': 'what did you find?'},
        ],
        requestId: 'req-openai',
        stream: false,
      ).toList();

      expect(server.bodies, isNotEmpty);
      final body = server.bodies.first;
      final msgs = body['messages'] as List;
      // user / assistant(tool_calls) / tool / user
      expect(msgs, hasLength(4));
      final assistantMsg = msgs[1] as Map;
      expect(assistantMsg['role'], 'assistant');
      expect(assistantMsg['tool_calls'], isA<List>());
      expect(
        (assistantMsg['tool_calls'] as List).single['id'],
        'call_1',
      );
      final toolMsg = msgs[2] as Map;
      expect(toolMsg['role'], 'tool');
      expect(toolMsg['tool_call_id'], 'call_1');
      expect(toolMsg['content'], 'file contents');
    });

    test('Claude: converts tool messages to tool_use + tool_result blocks',
        () async {
      final config = ProviderConfig(
        id: 'claude-test',
        enabled: true,
        name: 'claude-test',
        apiKey: 'key',
        baseUrl: server.baseUrl,
        providerType: ProviderKind.claude,
        models: const ['claude-test-model'],
      );
      await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'claude-test-model',
        messages: [
          const {'role': 'user', 'content': 'read the file'},
          ..._replayedToolMessages,
          const {'role': 'user', 'content': 'what did you find?'},
        ],
        requestId: 'req-claude',
        stream: false,
      ).toList();

      expect(server.bodies, isNotEmpty);
      final body = server.bodies.first;
      final msgs = body['messages'] as List;
      // user / assistant(tool_use blocks) / user(tool_result) / user
      expect(msgs, hasLength(4));
      final assistantMsg = msgs[1] as Map;
      expect(assistantMsg['role'], 'assistant');
      final blocks = assistantMsg['content'] as List;
      expect(blocks.single['type'], 'tool_use');
      expect(blocks.single['id'], 'call_1');
      expect(blocks.single['name'], 'file_read');
      expect((blocks.single['input'] as Map)['path'], 'main.dart');
      final resultMsg = msgs[2] as Map;
      expect(resultMsg['role'], 'user');
      final resultBlocks = resultMsg['content'] as List;
      expect(resultBlocks.single['type'], 'tool_result');
      expect(resultBlocks.single['tool_use_id'], 'call_1');
      expect(resultBlocks.single['content'], 'file contents');
    });

    test('Claude: empty tool result becomes (no output)', () async {
      final emptyResultMessages = [
        {
          'role': 'assistant',
          'content': '\n\n',
          'tool_calls': [
            {
              'id': 'call_x',
              'type': 'function',
              'function': {
                'name': 'web_search',
                'arguments': '{"q": "x"}',
              },
            },
          ],
        },
        {
          'role': 'tool',
          'name': 'web_search',
          'tool_call_id': 'call_x',
          'content': '',
        },
      ];
      final config = ProviderConfig(
        id: 'claude-test',
        enabled: true,
        name: 'claude-test',
        apiKey: 'key',
        baseUrl: server.baseUrl,
        providerType: ProviderKind.claude,
        models: const ['claude-test-model'],
      );
      await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'claude-test-model',
        messages: [
          const {'role': 'user', 'content': 'search'},
          ...emptyResultMessages,
        ],
        requestId: 'req-claude-empty',
        stream: false,
      ).toList();

      final body = server.bodies.first;
      final msgs = body['messages'] as List;
      final resultMsg = msgs[2] as Map;
      final resultBlocks = resultMsg['content'] as List;
      expect(resultBlocks.single['content'], '(no output)');
    });

    test('Gemini: converts tool messages to functionCall + functionResponse',
        () async {
      final config = ProviderConfig(
        id: 'gemini-test',
        enabled: true,
        name: 'gemini-test',
        apiKey: 'key',
        baseUrl: server.baseUrl,
        providerType: ProviderKind.google,
        models: const ['gemini-test-model'],
      );
      await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'gemini-test-model',
        messages: [
          const {'role': 'user', 'content': 'read the file'},
          ..._replayedToolMessages,
          const {'role': 'user', 'content': 'what did you find?'},
        ],
        requestId: 'req-gemini',
        stream: false,
      ).toList();

      expect(server.bodies, isNotEmpty);
      final body = server.bodies.first;
      final contents = body['contents'] as List;
      // user / model(functionCall) / user(functionResponse) / user
      expect(contents, hasLength(4));
      final modelMsg = contents[1] as Map;
      expect(modelMsg['role'], 'model');
      final modelParts = modelMsg['parts'] as List;
      expect(modelParts.single['functionCall'], isA<Map>());
      expect(
        (modelParts.single['functionCall'] as Map)['name'],
        'file_read',
      );
      expect(
        ((modelParts.single['functionCall'] as Map)['args'] as Map)['path'],
        'main.dart',
      );
      final resultMsg = contents[2] as Map;
      expect(resultMsg['role'], 'user');
      final resultParts = resultMsg['parts'] as List;
      expect(resultParts.single['functionResponse'], isA<Map>());
      expect(
        (resultParts.single['functionResponse'] as Map)['name'],
        'file_read',
      );
    });

    test(
        'P1-3 fix: DeepSeek thinking model keeps reasoning_content echoed on '
        'the replayed assistant tool_calls message', () async {
      final config = ProviderConfig(
        id: 'deepseek-test',
        enabled: true,
        name: 'deepseek-test',
        apiKey: 'key',
        baseUrl: server.baseUrl,
        providerType: ProviderKind.openai,
        models: const ['deepseek-v4.1-flash'],
      );
      final echoedToolMessages = [
        {
          'role': 'assistant',
          'content': '\n\n',
          'tool_calls': [
            {
              'id': 'call_ask',
              'type': 'function',
              'function': {'name': 'ask_user', 'arguments': '{}'},
            },
          ],
          // Persisted by the stream driver onto the tool event and
          // re-attached by the §3.11 replay builder.
          'reasoning_content': 'let me think about the question',
        },
        {
          'role': 'tool',
          'name': 'ask_user',
          'tool_call_id': 'call_ask',
          'content': '{"type":"ask_user_answer"}',
        },
      ];
      await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'deepseek-v4.1-flash',
        messages: [
          const {'role': 'user', 'content': 'ask me'},
          ...echoedToolMessages,
          const {'role': 'user', 'content': 'follow-up'},
        ],
        requestId: 'req-deepseek-echo',
        stream: false,
      ).toList();

      expect(server.bodies, isNotEmpty);
      final body = server.bodies.first;
      final msgs = body['messages'] as List;
      final assistantMsg = msgs[1] as Map;
      expect(assistantMsg['tool_calls'], isA<List>());
      expect(
        assistantMsg['reasoning_content'],
        'let me think about the question',
      );
    });

    test(
        'P1-3 fix (2026-09-11): DeepSeek thinking mode never 400s on a '
        'pending-tool replay without a persisted echo — the transport '
        'backfills reasoning_content when the builder could not', () async {
      // The real-world ask_user failure: the round that called ask_user
      // streamed no reasoning (or the conversation predates the echo
      // persistence), so the replayed assistant tool_calls message carries
      // no reasoning_content at all. needsReasoningEcho models must still
      // receive the field — the input-side backfill guarantees it.
      final config = ProviderConfig(
        id: 'deepseek-heal-test',
        enabled: true,
        name: 'deepseek-heal-test',
        apiKey: 'key',
        baseUrl: server.baseUrl,
        providerType: ProviderKind.openai,
        models: const ['deepseek-v4.1-flash'],
      );
      await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'deepseek-v4.1-flash',
        messages: [
          const {'role': 'user', 'content': 'ask me'},
          const {
            'role': 'assistant',
            'content': '\n\n',
            'tool_calls': [
              {
                'id': 'call_ask',
                'type': 'function',
                'function': {'name': 'ask_user', 'arguments': '{}'},
              },
            ],
            // No reasoning_content: neither the persisted event echo nor
            // the reasoningText fallback produced one.
          },
          const {
            'role': 'tool',
            'name': 'ask_user',
            'tool_call_id': 'call_ask',
            'content': '{"type":"ask_user_answer"}',
          },
          const {'role': 'user', 'content': 'follow-up'},
        ],
        requestId: 'req-deepseek-heal',
        stream: false,
      ).toList();

      expect(server.bodies, isNotEmpty);
      final body = server.bodies.first;
      final msgs = body['messages'] as List;
      final assistantMsg = msgs[1] as Map;
      expect(assistantMsg['tool_calls'], isA<List>());
      // The field must exist (DeepSeek rejects its absence) and must be a
      // string (a null value would also be rejected).
      expect(assistantMsg.containsKey('reasoning_content'), isTrue);
      // DeepSeek v4 treats an EMPTY string as missing (wire-capture
      // 2026-09-12 02:00): the backfilled value must be non-empty.
      expect(assistantMsg['reasoning_content'], '(no reasoning content)');
    });

    test(
        'P1-3 fix (2026-09-12 02:00): empty-string echo is replaced with a '
        'non-empty sentinel on every assistant message', () async {
      // Exact live-400 shape: the tool_calls message carried
      // reasoning_content:"" (backfilled) and the trailing text-only
      // assistant message carried reasoning_content:"" after the
      // every-message echo fix — DeepSeek v4 still rejected the request,
      // proving empty string == missing. Every echo must be non-empty.
      final config = ProviderConfig(
        id: 'deepseek-empty-echo-test',
        enabled: true,
        name: 'deepseek-empty-echo-test',
        apiKey: 'key',
        baseUrl: server.baseUrl,
        providerType: ProviderKind.openai,
        models: const ['deepseek-v4.1-flash'],
      );
      await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'deepseek-v4.1-flash',
        messages: const [
          {'role': 'user', 'content': 'tell me something'},
          {
            'role': 'assistant',
            'content': '\n\n',
            'tool_calls': [
              {
                'id': 'call_ask',
                'type': 'function',
                'function': {'name': 'ask_user', 'arguments': '{}'},
              },
            ],
            'reasoning_content': '',
          },
          {
            'role': 'tool',
            'name': 'ask_user',
            'tool_call_id': 'call_ask',
            'content': '{"type":"ask_user_answer"}',
          },
          {'role': 'assistant', 'content': '我來問問你想聽什麼 🙂', 'reasoning_content': ''},
        ],
        requestId: 'req-deepseek-empty-echo',
        stream: false,
      ).toList();

      expect(server.bodies, isNotEmpty);
      final body = server.bodies.first;
      final msgs = body['messages'] as List;
      for (final m in msgs) {
        if ((m as Map)['role'] != 'assistant') continue;
        expect(
          m['reasoning_content'],
          '(no reasoning content)',
          reason: 'assistant message with empty echo must be sent non-empty',
        );
      }
    });

    test(
        'P1-3 fix (2026-09-12): DeepSeek thinking mode requires '
        'reasoning_content on EVERY assistant message — a trailing '
        'text-only assistant message must be backfilled too', () async {
      // Exact wire shape captured from the live 400 (wire_errors.log,
      // req:b23c2675): the tool_calls assistant message had
      // reasoning_content backfilled, but the trailing text-only assistant
      // message (the pre-ask_user text) had no reasoning_content key at
      // all — DeepSeek v4 thinking mode rejects that with HTTP 400
      // "The `reasoning_content` in the thinking mode must be passed back
      // to the API." The echo contract covers every assistant message.
      final config = ProviderConfig(
        id: 'deepseek-trailing-test',
        enabled: true,
        name: 'deepseek-trailing-test',
        apiKey: 'key',
        baseUrl: server.baseUrl,
        providerType: ProviderKind.openai,
        models: const ['deepseek-v4.1-flash'],
      );
      await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'deepseek-v4.1-flash',
        messages: const [
          {'role': 'user', 'content': 'write something. (ask me first)'},
          {
            'role': 'assistant',
            'content': '\n\n',
            'tool_calls': [
              {
                'id': 'call_ask',
                'type': 'function',
                'function': {'name': 'ask_user', 'arguments': '{}'},
              },
            ],
            'reasoning_content': '',
          },
          {
            'role': 'tool',
            'name': 'ask_user',
            'tool_call_id': 'call_ask',
            'content': '{"type":"ask_user_answer"}',
          },
          {
            'role': 'assistant',
            'content': '我樂意幫你寫！先確認一下方向，這樣才能寫得符合你的期待。',
          },
        ],
        requestId: 'req-deepseek-trailing',
        stream: false,
      ).toList();

      expect(server.bodies, isNotEmpty);
      final body = server.bodies.first;
      final msgs = body['messages'] as List;
      // user / assistant(tool_calls) / tool / assistant(text-only)
      expect(msgs, hasLength(4));
      // The tool_calls message keeps its echo.
      expect((msgs[1] as Map).containsKey('reasoning_content'), isTrue);
      // THE FIX: the trailing text-only assistant message now carries the
      // field (string, possibly empty) instead of being stripped.
      final trailing = msgs[3] as Map;
      expect(trailing['role'], 'assistant');
      expect(trailing.containsKey('reasoning_content'), isTrue);
      // Non-empty: DeepSeek v4 rejects an empty string as if missing.
      expect(trailing['reasoning_content'], '(no reasoning content)');
    });

    test(
        'P1-3 fix: Claude conversion never forwards the replayed '
        'reasoning_content field (allow-list blocks it)', () async {
      final config = ProviderConfig(
        id: 'claude-test',
        enabled: true,
        name: 'claude-test',
        apiKey: 'key',
        baseUrl: server.baseUrl,
        providerType: ProviderKind.claude,
        models: const ['claude-test-model'],
      );
      // Shape produced by the builder's reasoningText fallback (pre-fix
      // history heal): the assistant tool_calls message carries a
      // vendor-specific reasoning_content the Anthropic schema does not
      // know. The Claude converter builds blocks from an allow-list
      // (tool_calls + claude_thinking_blocks), so the field must never
      // reach the request body.
      final echoedToolMessages = [
        {
          'role': 'assistant',
          'content': '\n\n',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {'name': 'file_read', 'arguments': '{}'},
            },
          ],
          'reasoning_content': 'deepseek-style field must not leak',
        },
        {
          'role': 'tool',
          'name': 'file_read',
          'tool_call_id': 'call_1',
          'content': 'file contents',
        },
      ];
      await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'claude-test-model',
        messages: [
          const {'role': 'user', 'content': 'read the file'},
          ...echoedToolMessages,
          const {'role': 'user', 'content': 'what next?'},
        ],
        requestId: 'req-claude-strip',
        stream: false,
      ).toList();

      expect(server.bodies, isNotEmpty);
      final body = server.bodies.first;
      expect(body.containsKey('reasoning_content'), isFalse);
      final msgs = body['messages'] as List;
      final assistantMsg = msgs[1] as Map;
      expect(assistantMsg.containsKey('reasoning_content'), isFalse);
      final blocks = assistantMsg['content'] as List;
      expect(blocks.single['type'], 'tool_use');
    });

    test(
        'P1-3 fix: non-echo models (OpenAI) strip the replayed '
        'reasoning_content field', () async {
      final config = ProviderConfig(
        id: 'openai-test',
        enabled: true,
        name: 'openai-test',
        apiKey: 'key',
        baseUrl: server.baseUrl,
        providerType: ProviderKind.openai,
        models: const ['gpt-4o'],
      );
      final echoedToolMessages = [
        {
          'role': 'assistant',
          'content': '\n\n',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {'name': 'file_read', 'arguments': '{}'},
            },
          ],
          'reasoning_content': 'vendor-specific field',
        },
        {
          'role': 'tool',
          'name': 'file_read',
          'tool_call_id': 'call_1',
          'content': 'file contents',
        },
      ];
      await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'gpt-4o',
        messages: [
          const {'role': 'user', 'content': 'read the file'},
          ...echoedToolMessages,
          const {'role': 'user', 'content': 'what next?'},
        ],
        requestId: 'req-openai-strip',
        stream: false,
      ).toList();

      expect(server.bodies, isNotEmpty);
      final body = server.bodies.first;
      final msgs = body['messages'] as List;
      final assistantMsg = msgs[1] as Map;
      expect(assistantMsg.containsKey('reasoning_content'), isFalse);
    });

    test('OpenAI Responses API: converts tool messages to function_call items',
        () async {
      final config = ProviderConfig(
        id: 'responses-test',
        enabled: true,
        name: 'responses-test',
        apiKey: 'key',
        baseUrl: server.baseUrl,
        providerType: ProviderKind.openai,
        models: const ['gpt-5'],
        useResponseApi: true,
      );
      await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'gpt-5',
        messages: [
          const {'role': 'user', 'content': 'read the file'},
          ..._replayedToolMessages,
          const {'role': 'user', 'content': 'what did you find?'},
        ],
        requestId: 'req-responses',
        stream: false,
      ).toList();

      expect(server.bodies, isNotEmpty);
      final body = server.bodies.first;
      expect(body['input'], isA<List>());
      final input = body['input'] as List;
      // user / function_call / function_call_output / user
      expect(input, hasLength(4));
      expect(input[0]['role'], 'user');
      final fc = input[1] as Map;
      expect(fc['type'], 'function_call');
      expect(fc['call_id'], 'call_1');
      expect(fc['name'], 'file_read');
      final fco = input[2] as Map;
      expect(fco['type'], 'function_call_output');
      expect(fco['call_id'], 'call_1');
      expect(fco['output'], 'file contents');
      expect(input[3]['role'], 'user');
    });
  });
}
