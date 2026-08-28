// Integration tests for the L1 retry loop in
// [ChatApiService.sendMessageStream]. These tests stand up an in-process
// HTTP server, drive the retry loop end-to-end, and assert the
// observable behaviour: how many retries fire, what the final error
// looks like, and whether a partial response that was already
// delivered is handled correctly.
//
// NOTE: the old "zero-output gate" (suppress retries once any visible
// chunk was yielded) has been REMOVED — the L1 loop now retries any
// transient / silent-interrupt failure regardless of prior output. The
// remaining yielded-flag tracking feeds silent-interruption detection
// (a `length` stop after visible output is a normal completion, not a
// retry).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:OmniChat/core/services/api/transient_stream_error.dart';
import 'package:flutter_test/flutter_test.dart';

  /// Per-test scenario the server should implement.
enum _Scenario {
  /// Always return a successful OpenAI-style SSE response with one
  /// 'ok' content delta and a `stop` finish reason.
  success,

  /// Fail with [failStatus] for the first [failCount] requests, then
  /// return a successful SSE response.
  failThenSuccess,

  /// Emit one content chunk then close the connection without [DONE]
  /// or a finish reason — simulates a proxy killing the stream.
  silentInterrupt,

  /// Emit one content chunk, then abruptly close the connection
  /// (raw socket drop). Exercises the partial-output retry path.
  yieldThenDrop,

  /// All requests return [HttpStatus.serviceUnavailable] (or the
  /// overridden [failStatus] in the 400 test).
  allFail,

  /// Emit content then a `length` finish reason with [DONE] — a
  /// complete-but-truncated response. The parser should treat this as
  /// a normal completion (visible output was already delivered).
  lengthAfterVisible,

  /// Emit a `length` finish reason with NO visible content — the model
  /// spent its budget on reasoning. Should surface output-limit.
  lengthNoOutput,
}

/// Test fixture that owns the HTTP server and per-test configuration.
class _RetryLoopFixture {
  _RetryLoopFixture();

  late HttpServer server;
  late String baseUrl;
  _Scenario scenario = _Scenario.success;
  int failStatus = HttpStatus.internalServerError;
  int failCount = 0;
  int requestCount = 0;

  Future<void> start() async {
    requestCount = 0;
    scenario = _Scenario.success;
    failStatus = HttpStatus.internalServerError;
    failCount = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}/v1';
    server.listen(_handle);
  }

  Future<void> stop() async {
    await server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    requestCount++;
    // ignore: avoid_print
    print('[fixture] handle hit, requestCount=$requestCount scenario=$scenario');
    switch (scenario) {
      case _Scenario.success:
        await _writeSuccess(request, text: 'ok');
        return;
      case _Scenario.failThenSuccess:
        if (requestCount <= failCount) {
          await _writeError(request, status: failStatus);
          return;
        }
        await _writeSuccess(request, text: 'ok');
        return;
      case _Scenario.silentInterrupt:
        await _writeSilentInterrupt(request);
        return;
      case _Scenario.yieldThenDrop:
        await _writeYieldThenDrop(request);
        return;
      case _Scenario.allFail:
        await _writeError(request, status: failStatus);
        return;
      case _Scenario.lengthAfterVisible:
        await _writeLengthAfterVisible(request);
        return;
      case _Scenario.lengthNoOutput:
        await _writeLengthNoOutput(request);
        return;
    }
  }

  Future<void> _writeSuccess(
    HttpRequest request, {
    required String text,
  }) async {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    request.response.write(
      'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'role': 'assistant', 'content': text},
                'finish_reason': null,
              },
            ],
            'object': 'chat.completion.chunk',
          })}\n\n',
    );
    request.response.write(
      'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {},
                'finish_reason': 'stop',
              },
            ],
            'usage': {
              'prompt_tokens': 1,
              'completion_tokens': 1,
              'total_tokens': 2,
            },
          })}\n\n',
    );
    request.response.write('data: [DONE]\n\n');
    await request.response.close();
  }

  Future<void> _writeError(
    HttpRequest request, {
    required int status,
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'error': 'mock failure'}));
    await request.response.close();
  }

  Future<void> _writeSilentInterrupt(HttpRequest request) async {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    request.response.write(
      'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'content': 'partial'},
                'finish_reason': null,
              },
            ],
          })}\n\n',
    );
    // Force-close without [DONE] / finish_reason.
    await request.response.close();
  }

  Future<void> _writeYieldThenDrop(HttpRequest request) async {
    // Write a content chunk, then abruptly close the connection.
    // This is a raw socket drop — the parser will either get a SocketException
    // or see the body end without [DONE]; either way it is a NON-silent
    // exception (silent_interrupt requires the parser to detect a clean
    // end-of-stream without finish_reason; this scenario never reaches
    // that branch because the connection dies mid-bytes).
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    request.response.write(
      'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'content': 'first-attempt'},
                'finish_reason': null,
              },
            ],
          })}\n\n',
    );
    // Write garbage bytes then close abruptly.
    request.response.add(
      Uint8List.fromList(utf8.encode('partial-garbage')),
    );
    await request.response.close();
  }

  Future<void> _writeLengthAfterVisible(HttpRequest request) async {
    // A full OpenAI SSE stream: content chunk, then a `length` finish
    // reason (with usage) and [DONE]. The visible content means this
    // must be treated as a NORMAL completion — no retry.
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    request.response.write(
      'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'role': 'assistant', 'content': 'partial-answer'},
                'finish_reason': null,
              },
            ],
            'object': 'chat.completion.chunk',
          })}\n\n',
    );
    request.response.write(
      'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {},
                'finish_reason': 'length',
              },
            ],
            'usage': {
              'prompt_tokens': 1,
              'completion_tokens': 1,
              'total_tokens': 2,
            },
          })}\n\n',
    );
    request.response.write('data: [DONE]\n\n');
    await request.response.close();
  }

  Future<void> _writeLengthNoOutput(HttpRequest request) async {
    // A `length` finish reason with NO visible content — the model
    // spent its output budget on reasoning. Should surface output-limit.
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    request.response.write(
      'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {},
                'finish_reason': 'length',
              },
            ],
            'usage': {
              'prompt_tokens': 1,
              'completion_tokens': 1,
              'total_tokens': 2,
            },
          })}\n\n',
    );
    request.response.write('data: [DONE]\n\n');
    await request.response.close();
  }

}

void main() {
  late _RetryLoopFixture fix;

  setUp(() async {
    fix = _RetryLoopFixture();
    await fix.start();
  });

  tearDown(() async {
    await fix.stop();
  });

  ProviderConfig buildConfig() => ProviderConfig(
        id: 'test',
        enabled: true,
        name: 'test',
        apiKey: 'test-key',
        baseUrl: fix.baseUrl,
        providerType: ProviderKind.openai,
        models: const ['gpt-test'],
      );

  group('sendMessageStream L1 retry', () {
    test(
      'succeeds on first attempt with no retry chunk',
      () async {
        fix.scenario = _Scenario.success;
        final chunks = await ChatApiService.sendMessageStream(
          config: buildConfig(),
          modelId: 'gpt-test',
          messages: const [
            {'role': 'user', 'content': 'hi'}
          ],
          requestId: 'req-success',
        ).toList();

        final retryChunks = chunks
            .where((c) => c.errorKind != null && c.attempt != null)
            .toList();
        expect(retryChunks, isEmpty);
        // Stream ends with an isDone chunk.
        expect(chunks.last.isDone, isTrue);
        // The 'ok' content was streamed mid-flight.
        final visible = chunks
            .where((c) => c.content.isNotEmpty)
            .map((c) => c.content)
            .join();
        expect(visible, contains('ok'));
        // Yielded tracker is cleared after the request finishes.
        expect(
          ChatApiService.debugHasYielded('req-success'),
          isFalse,
        );
        expect(fix.requestCount, 1);
      },
    );

    test(
      'retries once on transient 500 then succeeds',
      () async {
        fix.scenario = _Scenario.failThenSuccess;
        fix.failCount = 1;
        fix.failStatus = HttpStatus.internalServerError;
        final chunks = await ChatApiService.sendMessageStream(
          config: buildConfig(),
          modelId: 'gpt-test',
          messages: const [
            {'role': 'user', 'content': 'hi'}
          ],
          requestId: 'req-retry-1',
        ).toList();

        // Exactly one retry chunk with attempt=1.
        final retryChunks = chunks
            .where((c) => c.errorKind != null && c.attempt != null)
            .toList();
        expect(retryChunks, hasLength(1));
        expect(retryChunks.first.attempt, 1);
        expect(retryChunks.first.errorKind, 'transient_retry');
        // The second attempt's content is present.
        final visible = chunks
            .where((c) => c.content.isNotEmpty)
            .map((c) => c.content)
            .join();
        expect(visible, contains('ok'));
        expect(fix.requestCount, 2);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'exhausts 3 retries and raises retries_exhausted',
      () async {
        fix.scenario = _Scenario.allFail;
        fix.failStatus = HttpStatus.serviceUnavailable;

        Object? caught;
        final done = Completer<void>();
        final sub = ChatApiService.sendMessageStream(
          config: buildConfig(),
          modelId: 'gpt-test',
          messages: const [
            {'role': 'user', 'content': 'hi'}
          ],
          requestId: 'req-exhaust',
        ).listen(
          (_) {},
          onError: (Object e) {
            caught = e;
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        await done.future;
        await sub.cancel();

        // 1 initial + 3 retries = 4 attempts.
        expect(fix.requestCount, 4);
        expect(caught, isA<TransientStreamError>());
        final err = caught! as TransientStreamError;
        expect(err.isRetriesExhausted, isTrue);
        expect(err.attempts, 4);
        expect(err.originalMessage, contains('503'));
        expect(
          ChatApiService.debugHasYielded('req-exhaust'),
          isFalse,
        );
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'silent stream interruption after partial content still retries (safe — no usage block)',
      () async {
        // Silent interruption is a CLOSED but uncharged request — the
        // SSE body ended before `[DONE]` / usage, so the provider
        // never billed for the partial content. Retrying here is safe
        // and keeps a mid-stream proxy drop visible to the user.
        // The retry budget (4 attempts) is still respected.
        fix.scenario = _Scenario.silentInterrupt;

        Object? caught;
        final chunks = <ChatStreamChunk>[];
        final done = Completer<void>();
        final sub = ChatApiService.sendMessageStream(
          config: buildConfig(),
          modelId: 'gpt-test',
          messages: const [
            {'role': 'user', 'content': 'hi'}
          ],
          requestId: 'req-silent',
        ).listen(
          chunks.add,
          onError: (Object e) {
            caught = e;
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        await done.future;
        await sub.cancel();

        // 1 initial + 3 retries — all detect the same silent
        // interruption, then the budget is exhausted.
        expect(fix.requestCount, 4);
        expect(caught, isA<TransientStreamError>());
        final err = caught! as TransientStreamError;
        expect(err.isRetriesExhausted, isTrue);
        // Retry chunks should have been yielded — the chat-action
        // layer uses these to surface the inline "重試中… 1/3" indicator.
        final retryChunks = chunks
            .where((c) => c.errorKind != null && c.attempt != null)
            .toList();
        expect(retryChunks, hasLength(3));
        expect(retryChunks.first.errorKind, 'silent_interrupt_retry');
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'silent_interrupt after partial content triggers safe retry',
      () async {
        // When the parser has *successfully streamed* a chunk and
        // then sees the connection drop, the L1 retry loop reissues
        // the request: the provider never sent a `[DONE]` / usage
        // block and so did not bill — retrying is safe. This test
        // verifies that path: the loop should issue 4 requests (1
        // initial + 3 retries) and surface a retries_exhausted
        // error.
        fix.scenario = _Scenario.yieldThenDrop;

        Object? caught;
        final chunks = <ChatStreamChunk>[];
        final done = Completer<void>();
        final sub = ChatApiService.sendMessageStream(
          config: buildConfig(),
          modelId: 'gpt-test',
          messages: const [
            {'role': 'user', 'content': 'hi'}
          ],
          requestId: 'req-yield-then-drop',
        ).listen(
          chunks.add,
          onError: (Object e) {
            caught = e;
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        await done.future;
        await sub.cancel();

        // 1 initial + 3 retries — all detect the same silent
        // interruption (parser sees a clean-but-incomplete stream),
        // then the budget is exhausted. The visible content is the
        // first-attempt chunk, then the user sees 3 retry chunks.
        expect(fix.requestCount, 4);
        expect(caught, isA<TransientStreamError>());
        final err = caught! as TransientStreamError;
        expect(err.isRetriesExhausted, isTrue);
        final visible = chunks
            .where((c) => c.content.isNotEmpty)
            .map((c) => c.content)
            .join();
        expect(visible, contains('first-attempt'));
        // Retry chunks must have been yielded so the chat-action
        // layer can show the inline "重試中… 1/3" indicator.
        final retryChunks = chunks
            .where((c) => c.errorKind != null && c.attempt != null)
            .toList();
        expect(retryChunks, hasLength(3));
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'terminal 4xx (400) does not retry',
      () async {
        fix.scenario = _Scenario.allFail;
        fix.failStatus = HttpStatus.badRequest;

        Object? caught;
        final done = Completer<void>();
        final sub = ChatApiService.sendMessageStream(
          config: buildConfig(),
          modelId: 'gpt-test',
          messages: const [
            {'role': 'user', 'content': 'hi'}
          ],
          requestId: 'req-400',
        ).listen(
          (_) {},
          onError: (Object e) {
            caught = e;
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        await done.future;
        await sub.cancel();
        // Exactly one attempt — 400 is terminal, no retry.
        expect(fix.requestCount, 1);
        expect(caught, isNot(isA<TransientStreamError>()));
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      "'length' finish after visible output does NOT retry (clean completion)",
      () async {
        // Regression for P1: when the parser has streamed visible
        // content and then reports a `length` finish reason, the stream
        // completed visibly — the L1 loop must NOT reissue the request
        // (that would duplicate what the user already saw and burn
        // tokens upstream).
        fix.scenario = _Scenario.lengthAfterVisible;

        final chunks = await ChatApiService.sendMessageStream(
          config: buildConfig(),
          modelId: 'gpt-test',
          messages: const [
            {'role': 'user', 'content': 'hi'}
          ],
          requestId: 'req-length-visible',
        ).toList();

        // No retry chunks — the request was NOT reissued.
        final retryChunks = chunks
            .where((c) => c.errorKind != null && c.attempt != null)
            .toList();
        expect(retryChunks, isEmpty);
        expect(fix.requestCount, 1);
        // The partial answer was delivered as content.
        final visible = chunks
            .where((c) => c.content.isNotEmpty)
            .map((c) => c.content)
            .join();
        expect(visible, contains('partial-answer'));
        // Stream completes normally.
        expect(chunks.last.isDone, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      "'length' finish with NO visible output is not retried (output-limit, terminal-ish)",
      () async {
        // Regression for P1: a `length` finish with no visible output
        // maps to outputLimitRecovery — a user-visible limit, NOT a
        // silent interruption. The L1 loop must not burn retries on it.
        fix.scenario = _Scenario.lengthNoOutput;

        final chunks = await ChatApiService.sendMessageStream(
          config: buildConfig(),
          modelId: 'gpt-test',
          messages: const [
            {'role': 'user', 'content': 'hi'}
          ],
          requestId: 'req-length-noout',
        ).toList();

        final retryChunks = chunks
            .where((c) => c.errorKind != null && c.attempt != null)
            .toList();
        expect(retryChunks, isEmpty);
        expect(fix.requestCount, 1);
        // Stream completes normally (the isDone chunk is still emitted).
        expect(chunks.last.isDone, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });
}
