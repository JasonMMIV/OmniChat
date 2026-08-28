import 'package:OmniChat/core/services/api/stream_interruption.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyStreamEndRecovery', () {
    test('aborted → null (user cancel is intentional)', () {
      final r = classifyStreamEndRecovery(
        aborted: true,
        finishReason: 'stop',
        hasUsage: true,
        receivedReasoning: false,
        yieldedText: true,
        yieldedToolCall: false,
      );
      expect(r, isNull);
    });

    test('no finish part → streamInterruptedRecovery', () {
      final r = classifyStreamEndRecovery(
        aborted: false,
        finishReason: null,
        hasUsage: false,
        receivedReasoning: false,
        yieldedText: false,
        yieldedToolCall: false,
      );
      expect(r, isNotNull);
      expect(r!.source, 'stream-interrupted');
    });

    test("finishReason='unknown' + no usage → streamInterruptedRecovery", () {
      final r = classifyStreamEndRecovery(
        aborted: false,
        finishReason: 'unknown',
        hasUsage: false,
        receivedReasoning: false,
        yieldedText: false,
        yieldedToolCall: false,
      );
      expect(r, isNotNull);
      expect(r!.source, 'stream-interrupted');
    });

    test("finishReason='unknown' + usage → null (provider quirk, not interrupted)",
        () {
      final r = classifyStreamEndRecovery(
        aborted: false,
        finishReason: 'unknown',
        hasUsage: true,
        receivedReasoning: false,
        yieldedText: false,
        yieldedToolCall: false,
      );
      expect(r, isNull);
    });

    test('yieldedText + any finishReason → null (visible completion)', () {
      final r = classifyStreamEndRecovery(
        aborted: false,
        finishReason: 'length',
        hasUsage: true,
        receivedReasoning: true,
        yieldedText: true,
        yieldedToolCall: false,
      );
      expect(r, isNull);
    });

    test("finishReason='length' + no visible output → outputLimitRecovery", () {
      final r = classifyStreamEndRecovery(
        aborted: false,
        finishReason: 'length',
        hasUsage: true,
        receivedReasoning: true,
        yieldedText: false,
        yieldedToolCall: false,
      );
      expect(r, isNotNull);
      expect(r!.source, 'output-limit');
    });

    test('reasoning only with no visible output → reasoning-only recovery', () {
      final r = classifyStreamEndRecovery(
        aborted: false,
        finishReason: 'stop',
        hasUsage: true,
        receivedReasoning: true,
        yieldedText: false,
        yieldedToolCall: false,
      );
      expect(r, isNotNull);
      expect(r!.source, 'output-limit');
      expect(r.message, contains('reasoning'));
    });

    test('clean stop with visible output → null', () {
      final r = classifyStreamEndRecovery(
        aborted: false,
        finishReason: 'stop',
        hasUsage: true,
        receivedReasoning: false,
        yieldedText: true,
        yieldedToolCall: false,
      );
      expect(r, isNull);
    });

    test("UPPERCASE 'STOP' with visible output → null (Gemini-style)", () {
      final r = classifyStreamEndRecovery(
        aborted: false,
        finishReason: 'STOP',
        hasUsage: true,
        receivedReasoning: false,
        yieldedText: true,
        yieldedToolCall: false,
      );
      expect(r, isNull);
    });

    test("UPPERCASE 'MAX_TOKENS' with no visible output → outputLimitRecovery", () {
      final r = classifyStreamEndRecovery(
        aborted: false,
        finishReason: 'MAX_TOKENS',
        hasUsage: true,
        receivedReasoning: false,
        yieldedText: false,
        yieldedToolCall: false,
      );
      expect(r, isNotNull);
      expect(r!.source, 'output-limit');
    });

    test("UPPERCASE 'UNKNOWN' + no usage → streamInterruptedRecovery", () {
      final r = classifyStreamEndRecovery(
        aborted: false,
        finishReason: 'UNKNOWN',
        hasUsage: false,
        receivedReasoning: false,
        yieldedText: false,
        yieldedToolCall: false,
      );
      expect(r, isNotNull);
      expect(r!.source, 'stream-interrupted');
    });

    test("UPPERCASE 'UNKNOWN' + usage → null (provider quirk, not interrupted)", () {
      final r = classifyStreamEndRecovery(
        aborted: false,
        finishReason: 'UNKNOWN',
        hasUsage: true,
        receivedReasoning: false,
        yieldedText: false,
        yieldedToolCall: false,
      );
      expect(r, isNull);
    });
  });
}
