import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/models/chat_message.dart';
import 'package:OmniChat/core/models/message_usage.dart';
import 'package:OmniChat/features/chat/widgets/message_stats_text.dart';

ChatMessage _message({
  int? totalTokens,
  String content = 'hello',
  String? reasoningText,
}) {
  return ChatMessage(
    id: 'm1',
    role: 'assistant',
    content: content,
    conversationId: 'c1',
    totalTokens: totalTokens,
    reasoningText: reasoningText,
  );
}

void main() {
  test('no usage summary keeps the existing stats text exactly', () {
    expect(buildMessageStatsText(_message(totalTokens: 23)), '23 tokens · 5 字');
  });

  test('no reported usage keeps the estimated-token fallback', () {
    expect(
      buildMessageStatsText(_message(content: 'hello')),
      '~2 tokens · 5 字',
    );
  });

  test('usage summary is appended only when present', () {
    expect(
      buildMessageStatsText(
        _message(totalTokens: 23),
        usageSummary: r'$0.0041',
      ),
      r'23 tokens · 5 字 · $0.0041',
    );
  });

  test('empty usage summary is treated as absent', () {
    expect(
      buildMessageStatsText(_message(totalTokens: 23), usageSummary: ''),
      '23 tokens · 5 字',
    );
  });

  group('buildUsageSummary', () {
    const freeLabel = 'Free';
    const allowanceLabel = 'Go allowance';
    const listPriceLabel = 'List price';

    String? summary(MessageUsage usage) => buildUsageSummary(
      usage,
      freeLabel: freeLabel,
      allowanceLabel: allowanceLabel,
      listPriceLabel: listPriceLabel,
    );

    test('free shows the localized free label', () {
      expect(summary(const MessageUsage(billingSource: 'free')), 'Free');
    });

    test('Go prefers allowance over a zero cost', () {
      expect(
        summary(
          const MessageUsage(
            costUsd: 0,
            listCostUsd: 0.00000695,
            allowanceUsd: 0.00000695,
            billingSource: 'go',
          ),
        ),
        r'Go allowance $0.00000695',
      );
    });

    test('Go falls back to list price', () {
      expect(
        summary(
          const MessageUsage(
            costUsd: 0,
            listCostUsd: 0.00000695,
            billingSource: 'go-plus',
          ),
        ),
        r'List price $0.00000695',
      );
    });

    test('an allowance without billing_source is still shown', () {
      expect(
        summary(const MessageUsage(costUsd: 0, allowanceUsd: 0.00000695)),
        r'Go allowance $0.00000695',
      );
    });

    test('balance shows the charged amount', () {
      expect(
        summary(const MessageUsage(costUsd: 0.0041, billingSource: 'balance')),
        r'$0.0041',
      );
    });

    test('balance does not treat an allowance as a Go charge', () {
      expect(
        summary(
          const MessageUsage(
            costUsd: 0.0041,
            allowanceUsd: 0.00000695,
            billingSource: 'balance',
          ),
        ),
        r'$0.0041',
      );
    });

    test('BYOK uses the charged amount and marks estimates', () {
      expect(
        summary(
          const MessageUsage(
            costUsd: 0.0041,
            billingSource: 'byok',
            estimated: true,
          ),
        ),
        r'≈$0.0041',
      );
    });

    test('empty usage has no summary', () {
      expect(summary(const MessageUsage()), isNull);
    });
  });
}
