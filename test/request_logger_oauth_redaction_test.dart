// Log redaction for OAuth traffic (plan C5): identity keys, session ids and
// token-exchange fields never reach the request log.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/network/request_logger.dart';

void main() {
  test('masks OAuth identity and token fields, keeps the rest', () {
    final body = jsonEncode(<String, dynamic>{
      'model': 'claude-sonnet-4-5',
      'metadata': <String, dynamic>{
        'user_id': '{"device_id":"d","session_id":"s","account_uuid":"a"}',
      },
      'session_id': 'session-value',
      'conversation_id': 'conversation-value',
      'refresh_token': 'secret-refresh',
      'access_token': 'secret-access',
      'code_verifier': 'secret-verifier',
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': 'hello'},
      ],
    });

    final redacted = RequestLogger.redactOAuthBody(body);
    expect(redacted.contains('secret-refresh'), isFalse);
    expect(redacted.contains('secret-access'), isFalse);
    expect(redacted.contains('secret-verifier'), isFalse);
    expect(redacted.contains('session-value'), isFalse);
    expect(redacted.contains('conversation-value'), isFalse);
    expect(redacted.contains('claude-sonnet-4-5'), isTrue);
    expect(redacted.contains('hello'), isTrue);
    expect(redacted.contains('***'), isTrue);
  });

  test('form-encoded auth payloads keep keys but never values', () {
    const body =
        'grant_type=refresh_token&refresh_token=secret-refresh&code_verifier=secret-verifier';
    final redacted = RequestLogger.redactOAuthBody(body);
    expect(redacted.contains('secret-refresh'), isFalse);
    expect(redacted.contains('secret-verifier'), isFalse);
    expect(redacted, contains('refresh_token=***'));
    expect(redacted, contains('grant_type=***'));
  });

  test('OAuth session and account headers are masked', () {
    final headers = RequestLogger.redactHeaders(<String, String>{
      'Authorization': 'Bearer secret',
      'session_id': 'session-value',
      'conversation_id': 'conversation-value',
      'x-claude-code-session-id': 'session-value',
      'chatgpt-account-id': 'account-value',
      'x-msh-device-id': 'device-value',
      'x-msh-access-token': 'msh-secret',
      'x-msh-sign': 'signature-value',
      'Accept': 'text/event-stream',
    });
    expect(headers['Authorization'], '***');
    expect(headers['session_id'], '***');
    expect(headers['conversation_id'], '***');
    expect(headers['x-claude-code-session-id'], '***');
    expect(headers['chatgpt-account-id'], '***');
    expect(headers['x-msh-device-id'], '***');
    expect(headers['x-msh-access-token'], '***');
    expect(headers['x-msh-sign'], '***');
    expect(headers['Accept'], 'text/event-stream');
  });

  test('unknown OAuth bodies are suppressed, not logged verbatim', () {
    const text = 'not json at all';
    final redacted = RequestLogger.redactOAuthBody(text);
    expect(redacted, '[redacted oauth body]');
  });

  test('nested arrays are redacted too', () {
    final body = jsonEncode(<String, dynamic>{
      'items': <Map<String, dynamic>>[
        <String, dynamic>{'session_id': 'x', 'name': 'keep'},
      ],
    });
    final redacted = RequestLogger.redactOAuthBody(body);
    expect(redacted.contains('"x"'), isFalse);
    expect(redacted.contains('keep'), isTrue);
  });
}
