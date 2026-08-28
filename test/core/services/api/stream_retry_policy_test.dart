import 'dart:io';

import 'package:OmniChat/core/services/api/stream_retry_policy.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('StreamRetryConfig.computeBackoffDelayMs', () {
    test('attempt=0 with jitter off returns 1000 ms', () {
      expect(StreamRetryConfig.computeBackoffDelayMs(0, jitter: false), 1000);
    });

    test('attempt=2 with jitter off returns 4000 ms', () {
      expect(StreamRetryConfig.computeBackoffDelayMs(2, jitter: false), 4000);
    });

    test('attempt=10 with jitter off is capped at 8000 ms', () {
      expect(
        StreamRetryConfig.computeBackoffDelayMs(10, jitter: false),
        8000,
      );
    });

    test('negative attempt is treated as 0', () {
      expect(
        StreamRetryConfig.computeBackoffDelayMs(-5, jitter: false),
        1000,
      );
    });

    test('with jitter the result falls within ±20%', () {
      for (var i = 0; i < 50; i++) {
        final delay = StreamRetryConfig.computeBackoffDelayMs(0);
        expect(delay, inInclusiveRange(800, 1200));
      }
    });
  });

  group('isTransientNetworkError', () {
    test('SocketException is transient', () {
      const e = SocketException('connection reset by peer');
      expect(isTransientNetworkError(e), isTrue);
    });

    test('HandshakeException is transient', () {
      final e = HandshakeException('TLS error');
      expect(isTransientNetworkError(e), isTrue);
    });

    test('http.ClientException is transient', () {
      final e = http.ClientException('socket closed');
      expect(isTransientNetworkError(e), isTrue);
    });

    test('DioException connectionError is transient', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.connectionError,
      );
      expect(isTransientNetworkError(e), isTrue);
    });

    test('DioException receiveTimeout is transient', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.receiveTimeout,
      );
      expect(isTransientNetworkError(e), isTrue);
    });

    test('DioException badResponse is NOT transient (status decides)', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 500,
        ),
      );
      expect(isTransientNetworkError(e), isFalse);
    });

    test('HttpException with transient message substring is transient', () {
      final e = http.ClientException('Connection reset by peer');
      expect(isTransientNetworkError(e), isTrue);
    });

    test('Object that is none of the above is not transient', () {
      expect(isTransientNetworkError(StateError('boom')), isFalse);
    });
  });

  group('extractStatusCode', () {
    test('DioException with 500 response extracts 500', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 500,
        ),
      );
      expect(extractStatusCode(e), 500);
    });

    test('DioException without response is null', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.connectionError,
      );
      expect(extractStatusCode(e), isNull);
    });

    test('HttpException parses status from message', () {
      final e = HttpException('HTTP 429: rate limited');
      expect(extractStatusCode(e), 429);
    });

    test('SocketException has no status code', () {
      const e = SocketException('reset');
      expect(extractStatusCode(e), isNull);
    });
  });

  group('classify', () {
    test('SocketException → retryableTransient', () {
      const e = SocketException('reset');
      expect(classify(e), RetryDecision.retryableTransient);
    });

    test('DioException with status 500 → retryableTransient', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 500,
        ),
      );
      expect(classify(e), RetryDecision.retryableTransient);
    });

    test('DioException with status 429 → retryableTransient', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 429,
        ),
      );
      expect(classify(e), RetryDecision.retryableTransient);
    });

    test('DioException with status 408 → retryableTransient', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 408,
        ),
      );
      expect(classify(e), RetryDecision.retryableTransient);
    });

    test('DioException with status 400 → terminal', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 400,
        ),
      );
      expect(classify(e), RetryDecision.terminal);
    });

    test('DioException with status 401 → terminal (no failover)', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 401,
        ),
      );
      expect(classify(e), RetryDecision.terminal);
    });

    test('DioException with status 403 → terminal (no failover)', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 403,
        ),
      );
      expect(classify(e), RetryDecision.terminal);
    });

    test('HttpException 429 → retryableTransient', () {
      final e = HttpException('HTTP 429: rate limited');
      expect(classify(e), RetryDecision.retryableTransient);
    });
  });
}
