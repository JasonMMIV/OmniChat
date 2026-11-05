import 'package:OmniChat/core/utils/provider_test_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts HTTP status, reason and provider message', () {
    final failure = ProviderTestFailure.parse(
      'HttpException: HTTP 401: {"error":{"message":"invalid x-api-key"}}',
      requestUrl: 'https://api.anthropic.com/v1/messages',
    );

    expect(failure.statusCode, 401);
    expect(failure.httpLabel, 'HTTP 401 Unauthorized');
    expect(failure.message, 'invalid x-api-key');
    expect(failure.detail, contains('invalid x-api-key'));
    expect(failure.requestUrl, 'https://api.anthropic.com/v1/messages');
  });

  test('keeps transport failures readable', () {
    final failure = ProviderTestFailure.parse(
      'SocketException: Failed host lookup: api.example.com',
    );

    expect(failure.statusCode, isNull);
    expect(failure.httpLabel, isNull);
    expect(failure.message, contains('Failed host lookup'));
  });
}
