import 'package:flutter_test/flutter_test.dart';
import 'package:OmniChat/core/services/api/opencode_errors.dart';

void main() {
  test('classifies MissingSessionID and the session header mention', () {
    expect(
      classifyOpenCodeError(
        'HTTP 400: {"type":"error","error":{"type":"MissingSessionID"}}',
      ),
      OpenCodeErrorKind.missingSession,
    );
    expect(
      classifyOpenCodeError('request is missing x-opencode-session'),
      OpenCodeErrorKind.missingSession,
    );
  });

  test('classifies free-tier restrictions', () {
    expect(
      classifyOpenCodeError('HTTP 403: {"type":"FreeTierError"}'),
      OpenCodeErrorKind.freeTier,
    );
    expect(
      classifyOpenCodeError('Free tier models are restricted'),
      OpenCodeErrorKind.freeTier,
    );
  });

  test('classifies insufficient balance without matching unrelated numbers', () {
    expect(
      classifyOpenCodeError('HTTP 402: {"error":"insufficient funds"}'),
      OpenCodeErrorKind.insufficientBalance,
    );
    expect(
      classifyOpenCodeError('HTTP 400: invalid model id 402'),
      OpenCodeErrorKind.none,
    );
  });

  test('classifies protocol mismatch', () {
    expect(
      classifyOpenCodeError('HTTP 400: {"type":"ModelProtocolUnsupported"}'),
      OpenCodeErrorKind.protocolUnsupported,
    );
  });

  test('returns none for unrelated failures', () {
    expect(
      classifyOpenCodeError('HTTP 500: internal server error'),
      OpenCodeErrorKind.none,
    );
    expect(classifyOpenCodeError('SocketException'), OpenCodeErrorKind.none);
  });
}
