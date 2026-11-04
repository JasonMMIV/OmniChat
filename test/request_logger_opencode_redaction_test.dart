import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/network/request_logger.dart';

void main() {
  test('masks the OpenCode session header and keeps client identity', () {
    final headers = RequestLogger.redactHeaders(<String, String>{
      'x-opencode-session': 'conversation-123',
      'x-opencode-client': 'omnichat',
      'accept': 'application/json',
    });

    expect(headers['x-opencode-session'], '***');
    expect(headers['x-opencode-client'], 'omnichat');
    expect(headers['accept'], 'application/json');
    expect(headers.values.contains('conversation-123'), isFalse);
  });
}
