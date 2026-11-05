import 'dart:convert';

/// Cost and billing telemetry returned by OpenCode in `usage.opencode`.
///
/// This object is deliberately separate from [TokenUsage]: only OpenCode
/// responses carry it, and no other provider's UI or balance code should be
/// affected by its presence.
class MessageUsage {
  const MessageUsage({
    this.costUsd,
    this.listCostUsd,
    this.allowanceUsd,
    this.billingSource,
    this.estimated = false,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.reasoningTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWrite5mTokens = 0,
    this.cacheWrite1hTokens = 0,
  });

  /// The amount actually charged, when the provider reports one.
  final double? costUsd;

  /// The list price calculated from the model's published rates. Go uses this
  /// for the "what would this have cost" figure while [costUsd] is zero.
  final double? listCostUsd;

  /// How much of a Go plan allowance this request consumed.
  final double? allowanceUsd;

  /// `free`, `balance`, `go`, `go-plus`, `byok`, or null when unknown.
  final String? billingSource;

  /// True when [costUsd] is an estimate (BYOK).
  final bool estimated;

  final int inputTokens;
  final int outputTokens;
  final int reasoningTokens;
  final int cacheReadTokens;
  final int cacheWrite5mTokens;
  final int cacheWrite1hTokens;

  bool get hasCost =>
      costUsd != null || listCostUsd != null || allowanceUsd != null;

  bool get isEmpty =>
      !hasCost &&
      billingSource == null &&
      inputTokens == 0 &&
      outputTokens == 0 &&
      reasoningTokens == 0 &&
      cacheReadTokens == 0 &&
      cacheWrite5mTokens == 0 &&
      cacheWrite1hTokens == 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'costUsd': costUsd,
    'listCostUsd': listCostUsd,
    'allowanceUsd': allowanceUsd,
    'billingSource': billingSource,
    'estimated': estimated,
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'reasoningTokens': reasoningTokens,
    'cacheReadTokens': cacheReadTokens,
    'cacheWrite5mTokens': cacheWrite5mTokens,
    'cacheWrite1hTokens': cacheWrite1hTokens,
  };

  factory MessageUsage.fromJson(Map<String, dynamic> json) {
    return MessageUsage(
      costUsd: _asDouble(json['costUsd'] ?? json['cost']),
      listCostUsd: _asDouble(json['listCostUsd'] ?? json['list_cost']),
      allowanceUsd: _asDouble(json['allowanceUsd'] ?? json['allowance']),
      billingSource: _asString(json['billingSource'] ?? json['billing_source']),
      estimated: json['estimated'] == true,
      inputTokens: _asInt(json['inputTokens'] ?? json['input']),
      outputTokens: _asInt(json['outputTokens'] ?? json['output']),
      reasoningTokens: _asInt(json['reasoningTokens'] ?? json['reasoning']),
      cacheReadTokens: _asInt(json['cacheReadTokens'] ?? json['cache_read']),
      cacheWrite5mTokens: _asInt(
        json['cacheWrite5mTokens'] ?? json['cache_write_5m'],
      ),
      cacheWrite1hTokens: _asInt(
        json['cacheWrite1hTokens'] ?? json['cache_write_1h'],
      ),
    );
  }

  static MessageUsage? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final usage = MessageUsage.fromJson(decoded.cast<String, dynamic>());
        return usage.isEmpty ? null : usage;
      }
    } catch (_) {
      // A malformed sidecar must not make the message unreadable.
    }
    return null;
  }

  /// Returns null when the response has no OpenCode-specific usage block.
  /// A top-level generic `usage.cost` is intentionally ignored.
  static MessageUsage? tryParseOpenCode(Map? usage) {
    if (usage == null) return null;
    final openCode = usage['opencode'];
    if (openCode is! Map) return null;
    final rawTokens = openCode['tokens'];
    final tokens = rawTokens is Map ? rawTokens : const <dynamic, dynamic>{};
    final parsed = MessageUsage(
      costUsd: _asDouble(usage['cost']),
      listCostUsd: _asDouble(openCode['list_cost']),
      allowanceUsd: _asDouble(openCode['allowance']),
      billingSource: _asString(openCode['billing_source']),
      estimated: openCode['estimated'] == true,
      inputTokens: _asInt(tokens['input']),
      outputTokens: _asInt(tokens['output']),
      reasoningTokens: _asInt(tokens['reasoning']),
      cacheReadTokens: _asInt(tokens['cache_read']),
      cacheWrite5mTokens: _asInt(tokens['cache_write_5m']),
      cacheWrite1hTokens: _asInt(tokens['cache_write_1h']),
    );
    return parsed.isEmpty ? null : parsed;
  }

  /// Adds two usage snapshots across tool rounds. Null fields stay absent.
  static MessageUsage? accumulate(MessageUsage? a, MessageUsage? b) {
    if (a == null) return b;
    if (b == null) return a;
    return MessageUsage(
      costUsd: _sum(a.costUsd, b.costUsd),
      listCostUsd: _sum(a.listCostUsd, b.listCostUsd),
      allowanceUsd: _sum(a.allowanceUsd, b.allowanceUsd),
      billingSource: b.billingSource ?? a.billingSource,
      estimated: a.estimated || b.estimated,
      inputTokens: a.inputTokens + b.inputTokens,
      outputTokens: a.outputTokens + b.outputTokens,
      reasoningTokens: a.reasoningTokens + b.reasoningTokens,
      cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens,
      cacheWrite5mTokens: a.cacheWrite5mTokens + b.cacheWrite5mTokens,
      cacheWrite1hTokens: a.cacheWrite1hTokens + b.cacheWrite1hTokens,
    );
  }
}

double? _sum(double? a, double? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a + b;
}

double? _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

int _asInt(dynamic value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

String? _asString(dynamic value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}
