import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/token_usage.dart';

void main() {
  group('TokenUsage.subagentTokens (P1-4)', () {
    test('merge keeps helper tokens in the total but not in prompt', () {
      const base = TokenUsage(
        promptTokens: 100,
        completionTokens: 50,
        totalTokens: 150,
      );
      final merged = base.merge(const TokenUsage(subagentTokens: 900));
      expect(merged.promptTokens, 100);
      expect(merged.completionTokens, 50);
      expect(merged.subagentTokens, 900);
      expect(merged.totalTokens, 1050);
    });

    test('merge takes the max helper value (streaming semantics)', () {
      const a = TokenUsage(subagentTokens: 300, totalTokens: 300);
      final merged = a.merge(const TokenUsage(subagentTokens: 200));
      expect(merged.subagentTokens, 300);
      // prompt(0) + completion(0) + 300
      expect(merged.totalTokens, 300);
    });

    test('sum adds helper tokens without double-counting totals', () {
      const main = TokenUsage(
        promptTokens: 100,
        completionTokens: 40,
        totalTokens: 140,
      );
      const helpers = TokenUsage(subagentTokens: 60, totalTokens: 60);
      final sum = main.sum(helpers);
      expect(sum.subagentTokens, 60);
      expect(sum.promptTokens, 100);
      expect(sum.completionTokens, 40);
      expect(sum.totalTokens, 200);
    });

    test('sum falls back to p + c + helper when totals are zero', () {
      const a = TokenUsage(promptTokens: 10, completionTokens: 5);
      const b = TokenUsage(subagentTokens: 7);
      final sum = a.sum(b);
      expect(sum.totalTokens, 22);
      expect(sum.subagentTokens, 7);
    });

    test('accumulate carries the helper field through the rebuild', () {
      const a = TokenUsage(
        promptTokens: 10,
        completionTokens: 2,
        totalTokens: 12,
        subagentTokens: 30,
      );
      final out = a.accumulate(const TokenUsage(subagentTokens: 5));
      expect(out.subagentTokens, 30);
      expect(out.totalTokens, 42);
    });

    test('withOpenCodeUsage preserves helper tokens', () {
      const usage = TokenUsage(
        promptTokens: 1,
        completionTokens: 2,
        totalTokens: 3,
        subagentTokens: 9,
      );
      final out = usage.withOpenCodeUsage(null);
      expect(identical(out, usage), isTrue);
      expect(out.subagentTokens, 9);
    });
  });
}
