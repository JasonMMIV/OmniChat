// Regression test for the L1 silent-interruption detector (2026-11-09).
//
// Agnes apihub closes an OpenAI-compatible SSE stream with:
//   1. choices[0].finish_reason = "stop"
//   2. a trailing chunk that STILL has a non-empty `choices` array, carries
//      `usage`, and reports `finish_reason: null`
//   3. [DONE]
// The parser used to overwrite the captured "stop" with that null, so the
// retry loop classified a completed answer as a dropped stream and reissued
// the request up to 4× ("connection interrupted after 4 attempts").
//
// Driven through the real `sendMessageStream` + loopback server so the actual
// parser and the L1 retry loop both participate.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:OmniChat/core/services/api/chat_stream_chunk.dart';
import 'package:OmniChat/core/services/api/stream_retry_policy.dart';
import 'package:OmniChat/core/services/api/transient_stream_error.dart';

ProviderConfig _config(String baseUrl) => ProviderConfig(
  id: 'agnes-test',
  enabled: true,
  name: 'agnes-test',
  apiKey: 'k',
  baseUrl: baseUrl,
  providerType: ProviderKind.openai,
  models: const ['agnes-3.0-flash'],
);

String _sse(Map<String, dynamic> payload) => 'data: ${jsonEncode(payload)}\n\n';

void main() {
  test('trailing null finish_reason chunk keeps the earlier "stop" marker '
      '(no silent-interrupt retry)', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;

    server.listen((req) async {
      requests++;
      await req.drain<void>();
      req.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      req.response.write(
        _sse(<String, dynamic>{
          'id': 'x',
          'object': 'chat.completion.chunk',
          'choices': [
            <String, dynamic>{
              'index': 0,
              'delta': <String, dynamic>{'content': 'Hello'},
              'finish_reason': null,
            },
          ],
        }),
      );
      req.response.write(
        _sse(<String, dynamic>{
          'id': 'x',
          'object': 'chat.completion.chunk',
          'choices': [
            <String, dynamic>{
              'index': 0,
              'delta': <String, dynamic>{},
              'finish_reason': 'stop',
            },
          ],
        }),
      );
      // Agnes' trailing usage chunk: non-empty choices, finish_reason null.
      req.response.write(
        _sse(<String, dynamic>{
          'id': 'x',
          'object': 'chat.completion.chunk',
          'choices': [
            <String, dynamic>{
              'index': 0,
              'delta': <String, dynamic>{},
              'finish_reason': null,
            },
          ],
          'usage': <String, dynamic>{
            'prompt_tokens': 10,
            'completion_tokens': 5,
            'total_tokens': 15,
          },
        }),
      );
      req.response.write('data: [DONE]\n\n');
      await req.response.close();
    });

    final chunks = await ChatApiService.sendMessageStream(
      config: _config('http://127.0.0.1:${server.port}'),
      modelId: 'agnes-3.0-flash',
      messages: const [
        <String, dynamic>{'role': 'user', 'content': 'hi'},
      ],
      stream: true,
      requestId: 'finish-marker-test',
    ).toList();

    // No retry status chunk: the stream completed on the first attempt.
    expect(
      chunks.where((ChatStreamChunk c) => c.errorKind != null),
      isEmpty,
      reason: 'a completed stream must not be retried',
    );
    expect(requests, 1, reason: 'the L1 loop must not reissue the request');

    final terminal = chunks.last;
    expect(terminal.isDone, isTrue);
    expect(terminal.content, isEmpty);
    expect(terminal.usage!.totalTokens, 15);
    expect(
      chunks.map((ChatStreamChunk c) => c.content).join(),
      'Hello',
    );
  });

  test('a stream that really ends without any finish marker still retries '
      '(over-fix guard)', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;

    server.listen((req) async {
      requests++;
      await req.drain<void>();
      req.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      // Text, then the body just ends: no finish_reason, no usage, no [DONE].
      req.response.write(
        _sse(<String, dynamic>{
          'id': 'x',
          'object': 'chat.completion.chunk',
          'choices': [
            <String, dynamic>{
              'index': 0,
              'delta': <String, dynamic>{'content': 'cut off'},
              'finish_reason': null,
            },
          ],
        }),
      );
      await req.response.close();
    });

    final chunks = <ChatStreamChunk>[];
    Object? error;
    try {
      await for (final chunk in ChatApiService.sendMessageStream(
        config: _config('http://127.0.0.1:${server.port}'),
        modelId: 'agnes-3.0-flash',
        messages: const [
          <String, dynamic>{'role': 'user', 'content': 'hi'},
        ],
        stream: true,
        requestId: 'finish-marker-negative-test',
      )) {
        chunks.add(chunk);
      }
    } catch (e) {
      error = e;
    }

    expect(error, isA<TransientStreamError>());
    expect((error! as TransientStreamError).isRetriesExhausted, isTrue);
    expect(requests, StreamRetryConfig.maxRetriesPerMessage + 1);
    expect(
      chunks.where(
        (ChatStreamChunk c) => c.errorKind == 'silent_interrupt_retry',
      ),
      hasLength(StreamRetryConfig.maxRetriesPerMessage),
    );
  });
}
