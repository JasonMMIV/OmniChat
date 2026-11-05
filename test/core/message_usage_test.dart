import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/message_usage.dart';
import 'package:OmniChat/core/models/token_usage.dart';
import 'package:OmniChat/utils/usd_format.dart';

Map<String, dynamic> _usage({
  required String source,
  double? cost,
  double? listCost,
  double? allowance,
  bool estimated = false,
}) {
  return <String, dynamic>{
    'prompt_tokens': 13,
    'completion_tokens': 10,
    'total_tokens': 23,
    'cost': cost,
    'opencode': <String, dynamic>{
      'billing_source': source,
      'list_cost': listCost,
      'allowance': allowance,
      'estimated': estimated,
      'tokens': <String, dynamic>{
        'input': 13,
        'output': 10,
        'reasoning': 4,
        'cache_read': 2,
        'cache_write_5m': 1,
        'cache_write_1h': 3,
      },
    },
  };
}

void main() {
  group('MessageUsage.tryParseOpenCode', () {
    test('parses balance billing', () {
      final usage = MessageUsage.tryParseOpenCode(
        _usage(source: 'balance', cost: 0.0041, listCost: 0.0041),
      );
      expect(usage, isNotNull);
      expect(usage!.billingSource, 'balance');
      expect(usage.costUsd, 0.0041);
      expect(usage.inputTokens, 13);
      expect(usage.outputTokens, 10);
      expect(usage.reasoningTokens, 4);
      expect(usage.cacheReadTokens, 2);
      expect(usage.cacheWrite5mTokens, 1);
      expect(usage.cacheWrite1hTokens, 3);
      expect(usage.hasCost, isTrue);
    });

    test('parses Go allowance without treating zero cost as free', () {
      final usage = MessageUsage.tryParseOpenCode(
        _usage(
          source: 'go',
          cost: 0,
          listCost: 0.00000695,
          allowance: 0.00000695,
        ),
      );
      expect(usage!.billingSource, 'go');
      expect(usage.costUsd, 0);
      expect(usage.allowanceUsd, 0.00000695);
      expect(usage.listCostUsd, 0.00000695);
      expect(usage.hasCost, isTrue);
    });

    test('parses free billing', () {
      final usage = MessageUsage.tryParseOpenCode(
        _usage(source: 'free', cost: 0, listCost: 0),
      );
      expect(usage!.billingSource, 'free');
      expect(usage.costUsd, 0);
    });

    test('parses BYOK estimate flag', () {
      final usage = MessageUsage.tryParseOpenCode(
        _usage(source: 'byok', cost: 0.0041, estimated: true),
      );
      expect(usage!.billingSource, 'byok');
      expect(usage.estimated, isTrue);
    });

    test('ignores generic cost without opencode block', () {
      expect(
        MessageUsage.tryParseOpenCode(<String, dynamic>{'cost': 0.5}),
        isNull,
      );
    });

    test('treats an empty usage map as absent', () {
      expect(MessageUsage.tryParse('{}'), isNull);
      expect(
        MessageUsage.tryParseOpenCode(<String, dynamic>{'opencode': {}}),
        isNull,
      );
    });
  });

  group('TokenUsage cost aggregation', () {
    test('merge keeps the latest non-null cost snapshot', () {
      const first = TokenUsage(
        promptTokens: 10,
        completionTokens: 2,
        totalTokens: 12,
        messageUsage: MessageUsage(costUsd: 0.1, billingSource: 'balance'),
      );
      const tokenOnly = TokenUsage(
        promptTokens: 10,
        completionTokens: 5,
        totalTokens: 15,
      );
      final merged = first.merge(tokenOnly);
      expect(merged.costUsd, 0.1);
      expect(merged.completionTokens, 5);
    });

    test('accumulate sums costs while keeping max token snapshots', () {
      const first = TokenUsage(
        promptTokens: 10,
        completionTokens: 2,
        totalTokens: 12,
        messageUsage: MessageUsage(costUsd: 0.1, allowanceUsd: 0.2),
      );
      const second = TokenUsage(
        promptTokens: 12,
        completionTokens: 4,
        totalTokens: 16,
        messageUsage: MessageUsage(costUsd: 0.3, allowanceUsd: 0.4),
      );
      final total = first.accumulate(second);
      expect(total.completionTokens, 4);
      expect(total.costUsd, closeTo(0.4, 1e-12));
      expect(total.allowanceUsd, closeTo(0.6, 1e-12));
      expect(total.billingSource, isNull);
    });

    test('withOpenCodeUsage leaves plain token usage unchanged', () {
      const plain = TokenUsage(promptTokens: 1, completionTokens: 2);
      final same = plain.withOpenCodeUsage(<String, dynamic>{'cost': 1});
      expect(same.toMessageUsage(), isNull);
      expect(same.promptTokens, 1);
    });
  });

  group('formatUsd', () {
    test('uses the precision ladder and trims trailing zeroes', () {
      expect(formatUsd(null), isNull);
      expect(formatUsd(0), r'$0');
      expect(formatUsd(0.01), r'$0.01');
      expect(formatUsd(0.0041), r'$0.0041');
      expect(formatUsd(0.00000695), r'$0.00000695');
    });
  });

  test('ChatMessage round-trips usageMeta through backup JSON', () {
    const usage = MessageUsage(
      costUsd: 0.0041,
      listCostUsd: 0.005,
      billingSource: 'balance',
      inputTokens: 13,
      outputTokens: 10,
    );
    final message = ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: 'hi',
      conversationId: 'c1',
      usageMetaJson: jsonEncode(usage.toJson()),
    );
    final restored = ChatMessage.fromJson(message.toJson());
    expect(restored.usageMeta?.costUsd, 0.0041);
    expect(restored.usageMeta?.inputTokens, 13);
  });
}
