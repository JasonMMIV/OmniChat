import 'message_usage.dart';

class TokenUsage {
  final int promptTokens;
  final int completionTokens;
  final int cachedTokens;
  final int totalTokens;

  /// OpenCode-only cost/billing telemetry. Null for every other provider.
  final MessageUsage? messageUsage;

  const TokenUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.cachedTokens = 0,
    this.totalTokens = 0,
    this.messageUsage,
  });

  double? get costUsd => messageUsage?.costUsd;
  double? get listCostUsd => messageUsage?.listCostUsd;
  double? get allowanceUsd => messageUsage?.allowanceUsd;
  String? get billingSource => messageUsage?.billingSource;
  bool get estimated => messageUsage?.estimated ?? false;

  TokenUsage merge(TokenUsage other) {
    // For streaming responses:
    // - prompt tokens: take max (usually stays constant after initial value)
    // - completion tokens: take max (grows as response streams)
    // - cached tokens: take max (usually set once)
    // A later non-null cost snapshot replaces the earlier one; an unrelated
    // token-only update never erases it.
    final prompt = other.promptTokens > 0 ? other.promptTokens : promptTokens;
    final completion = other.completionTokens > 0
        ? other.completionTokens
        : completionTokens;
    final cached = other.cachedTokens > 0 ? other.cachedTokens : cachedTokens;
    final total = prompt + completion;
    return TokenUsage(
      promptTokens: prompt,
      completionTokens: completion,
      cachedTokens: cached,
      totalTokens: total,
      messageUsage: other.messageUsage ?? messageUsage,
    );
  }

  /// Token counts still follow the streaming max semantics; costs are summed.
  /// Use this only at multi-round tool aggregation points.
  TokenUsage accumulate(TokenUsage other) {
    final merged = merge(other);
    return TokenUsage(
      promptTokens: merged.promptTokens,
      completionTokens: merged.completionTokens,
      cachedTokens: merged.cachedTokens,
      totalTokens: merged.totalTokens,
      messageUsage: MessageUsage.accumulate(messageUsage, other.messageUsage),
    );
  }

  MessageUsage? toMessageUsage() => messageUsage;

  /// Applies `usage.opencode` without touching any generic cost field.
  TokenUsage withOpenCodeUsage(Map? rawUsage) {
    final parsed = MessageUsage.tryParseOpenCode(rawUsage);
    if (parsed == null) return this;
    return TokenUsage(
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      cachedTokens: cachedTokens,
      totalTokens: totalTokens,
      messageUsage: parsed,
    );
  }
}
