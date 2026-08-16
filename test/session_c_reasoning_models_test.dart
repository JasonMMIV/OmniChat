import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/providers/model_provider.dart';
import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';

ProviderConfig _openAiResponsesConfig(String baseUrl) => ProviderConfig(
  id: 'OpenAIResponses',
  enabled: true,
  name: 'OpenAI Responses',
  apiKey: 'test-api-key',
  baseUrl: baseUrl,
  providerType: ProviderKind.openai,
  useResponseApi: true,
);

ProviderConfig _zhipuConfig(String baseUrl) => ProviderConfig(
  id: 'Zhipu AI',
  enabled: true,
  name: 'Zhipu AI',
  apiKey: 'test-api-key',
  baseUrl: baseUrl,
  providerType: ProviderKind.openai,
  useResponseApi: false,
);

Future<List<Map<String, dynamic>>> _sendResponsesToolCallAndCaptureRequestBodies(
  Future<List<dynamic>> Function(String baseUrl) sendRequest, {
  List<Map<String, dynamic>> completedOutput = const [
    {
      'type': 'function_call',
      'call_id': 'call_1',
      'name': 'lookup',
      'arguments': '{}',
    },
  ],
}) async {
  final requestBodies = <Map<String, dynamic>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final baseUrl = 'http://${server.address.address}:${server.port}/v1';

  server.listen((request) async {
    final body =
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
    requestBodies.add(body);

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );

    if (requestBodies.length == 1) {
      request.response.write(
        'data: ${jsonEncode({'type': 'response.output_item.added', 'item': {'type': 'function_call', 'call_id': 'call_1', 'name': 'lookup'}})}\n\n',
      );
      request.response.write(
        'data: ${jsonEncode({'type': 'response.function_call_arguments.delta', 'call_id': 'call_1', 'delta': '{"q": "test"}'})}\n\n',
      );
      request.response.write(
        'data: ${jsonEncode({'type': 'response.function_call_arguments.done', 'call_id': 'call_1', 'arguments': '{"q": "test"}'})}\n\n',
      );
      request.response.write(
        'data: ${jsonEncode({'type': 'response.output_item.done', 'item': {'type': 'function_call', 'call_id': 'call_1', 'name': 'lookup', 'arguments': '{"q": "test"}'}})}\n\n',
      );
      request.response.write(
        'data: ${jsonEncode({
          'type': 'response.completed',
          'response': {
            'output': completedOutput,
            'usage': {'input_tokens': 1, 'output_tokens': 1},
          },
        })}\n\n',
      );
    } else {
      request.response.write(
        'data: ${jsonEncode({'type': 'response.output_item.added', 'item': {'type': 'message', 'role': 'assistant', 'content': []}})}\n\n',
      );
      request.response.write(
        'data: ${jsonEncode({'type': 'response.content_part.added', 'part': {'type': 'output_text', 'text': ''}})}\n\n',
      );
      request.response.write(
        'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': 'Result: ok'})}\n\n',
      );
      request.response.write(
        'data: ${jsonEncode({'type': 'response.output_text.done', 'text': 'Result: ok'})}\n\n',
      );
      request.response.write(
        'data: ${jsonEncode({'type': 'response.completed', 'response': {'output': [], 'usage': {'input_tokens': 2, 'output_tokens': 2}}})}\n\n',
      );
    }

    request.response.write('data: [DONE]\n\n');
    await request.response.close();
  });

  try {
    await sendRequest(baseUrl);
  } finally {
    await server.close(force: true);
  }

  return requestBodies;
}

void main() {
  group('Session C Reasoning & Model Support', () {
    test('latest GLM and Kimi model ids infer expected capabilities', () {
      final glm = ModelRegistry.infer(
        ModelInfo(id: 'glm-5.2', displayName: 'glm-5.2'),
      );
      final kimi = ModelRegistry.infer(
        ModelInfo(id: 'kimi-k2.7-code', displayName: 'kimi-k2.7-code'),
      );

      expect(glm.input, const [Modality.text]);
      expect(glm.output, const [Modality.text]);
      expect(
        glm.abilities,
        containsAll([ModelAbility.tool, ModelAbility.reasoning]),
      );
      expect(kimi.input, contains(Modality.image));
      expect(kimi.output, const [Modality.text]);
      expect(
        kimi.abilities,
        containsAll([ModelAbility.tool, ModelAbility.reasoning]),
      );
    });

    test(
      'Responses tool continuation keeps streamed function call before output',
      () async {
        final requestBodies =
            await _sendResponsesToolCallAndCaptureRequestBodies(
              completedOutput: const <Map<String, dynamic>>[],
              (baseUrl) {
                return ChatApiService.sendMessageStream(
                  config: _openAiResponsesConfig(baseUrl),
                  modelId: 'gpt-5.5',
                  messages: const [
                    {'role': 'user', 'content': 'hi'},
                  ],
                  tools: const [
                    {
                      'type': 'function',
                      'function': {
                        'name': 'lookup',
                        'description': 'Lookup test data',
                        'parameters': {
                          'type': 'object',
                          'properties': <String, dynamic>{},
                        },
                      },
                    },
                  ],
                  onToolCall: (_, __, {toolCallId}) async => '{"result":"ok"}',
                ).toList();
              },
            );

        expect(requestBodies, hasLength(2));
        final followUpInput = (requestBodies[1]['input'] as List)
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList(growable: false);
        final functionCallIndex = followUpInput.indexWhere(
          (item) =>
              item['type'] == 'function_call' && item['call_id'] == 'call_1',
        );
        final outputIndex = followUpInput.indexWhere(
          (item) =>
              item['type'] == 'function_call_output' &&
              item['call_id'] == 'call_1',
        );

        expect(functionCallIndex, isNonNegative);
        expect(outputIndex, isNonNegative);
        expect(functionCallIndex, lessThan(outputIndex));
      },
    );

    test('glm-5.2 tool continuation preserves reasoning_content', () async {
      final secondRequestCompleter = Completer<Map<String, dynamic>>();
      var requestCount = 0;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        requestCount += 1;
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );

        if (requestCount == 1) {
          request.response.write(
            'data: ${jsonEncode({
              'id': 'cmpl-glm52-tool',
              'object': 'chat.completion.chunk',
              'created': 0,
              'model': 'glm-5.2',
              'choices': [
                {
                  'index': 0,
                  'delta': {
                    'role': 'assistant',
                    'reasoning_content': '先获取当前日期',
                    'content': '我先查一下日期。',
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'call_date',
                        'type': 'function',
                        'function': {'name': 'date', 'arguments': '{}'},
                      },
                    ],
                  },
                  'finish_reason': 'tool_calls',
                },
              ],
            })}\n\n',
          );
        } else {
          if (!secondRequestCompleter.isCompleted) {
            secondRequestCompleter.complete(body);
          }
          request.response.write(
            'data: ${jsonEncode({
              'id': 'cmpl-glm52-final',
              'object': 'chat.completion.chunk',
              'created': 0,
              'model': 'glm-5.2',
              'choices': [
                {
                  'index': 0,
                  'delta': {'role': 'assistant', 'content': '今天是 2026-06-15'},
                  'finish_reason': 'stop',
                },
              ],
            })}\n\n',
          );
        }

        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      });

      final baseUrl = 'http://${server.address.address}:${server.port}/v1';
      final chunks = await ChatApiService.sendMessageStream(
        config: _zhipuConfig(baseUrl),
        modelId: 'glm-5.2',
        messages: const [
          {'role': 'user', 'content': '今天几号？'},
        ],
        tools: const [
          {
            'type': 'function',
            'function': {
              'name': 'date',
              'description': 'Get current date',
              'parameters': {
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            },
          },
        ],
        thinkingBudget: 1024,
        onToolCall: (name, args, {toolCallId}) async {
          return '2026-06-15';
        },
      ).toList();

      final secondBody = await secondRequestCompleter.future;
      final messages = (secondBody['messages'] as List)
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      final assistantToolMessage = messages.firstWhere(
        (m) => m['role'] == 'assistant' && m['tool_calls'] is List,
      );

      expect(chunks.last.isDone, isTrue);
      expect(secondBody['thinking'], {'type': 'enabled'});
      expect(secondBody.containsKey('reasoning_effort'), isFalse);
      expect(assistantToolMessage['reasoning_content'], '先获取当前日期');
      expect(assistantToolMessage['tool_calls'], [
        {
          'id': 'call_date',
          'type': 'function',
          'function': {'name': 'date', 'arguments': '{}'},
        },
      ]);
    });
  });
}
