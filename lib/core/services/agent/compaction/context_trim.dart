// Context-window budget helpers + R0 mechanical trim (IMPORT_PLAN_COWORK.md
// P1-2). Ported from AnyBuff (common/src/util/context-trim.ts and
// packages/agent-runtime/src/util/messages.ts trimMessagesToFitTokenLimit).
//
// Pure Dart: no Flutter imports, deterministic output.
library;

import 'dart:math' as math;

import 'tool_pairing.dart';

/// Window assumed for a model with no declared capability and no learned
/// window (plan v1.3: modern flagships are ~1M class; an optimistic prior +
/// the R0 overflow backstop beats a small fallback that would over-compact
/// 1M-class users).
const int unknownModelContextFallback = 1_000_000;

/// Lower clamp of the headroom reserve (plan: 8k).
const int contextReserveMinTokens = 8_000;

/// Output-token reservation is capped at 64k (a 262k-output model would
/// otherwise swallow the whole trigger).
const int _outputReserveCap = 64_000;
const double _reserveFraction = 0.12;
const double _reserveCapFraction = 0.5;
const double _triggerFraction = 0.7;

int _clampInt(int value, int lo, int hi) => value < lo ? lo : (value > hi ? hi : value);

/// Headroom reserved inside a context window before compaction/trim
/// triggers, so in-flight output (and tokenizer variance) never push a
/// request over the provider's real limit. [outputTokens] is the model's
/// declared max output; when unknown only the flat 12% reserve applies.
///
///   reserve(W, out) = clamp(max(0.12*W, min(out, 64k)), 8k, 0.5*W)
int reserveTokens(int contextWindowTokens, int? outputTokens) {
  final window = math.max(1, contextWindowTokens);
  final outputReserve = outputTokens == null
      ? 0
      : _clampInt(outputTokens, 0, _outputReserveCap);
  final lo = math.min(contextReserveMinTokens, (_reserveCapFraction * window).floor());
  final hi = (_reserveCapFraction * window).floor();
  final raw = math.max((_reserveFraction * window).floor(), outputReserve);
  return _clampInt(raw, lo, hi);
}

/// Token count at which a conversation should be compacted/trimmed for a
/// model with the given window. Deliberately conservative:
///
///   trigger(W) = min(0.7*W, W - reserve(W, out))
int compactionTriggerTokens(int contextWindowTokens, int? outputTokens) {
  final window = math.max(1, contextWindowTokens);
  final reserve = reserveTokens(window, outputTokens);
  return math.max(
    1,
    math.min((_triggerFraction * window).floor(), window - reserve),
  );
}

// ============================================================================
// Seed window table (plan v1.4: tiny ~10-entry table, small-window trap
// families only; values from AnyBuff B1a, data source models.dev (MIT)).
// BYOK model ids outpace any table — R0 error-message learning is the
// authoritative correction; this table doubles as insurance for the
// "no digits in the error message" corner.
// ============================================================================

class ModelWindowSpec {
  /// Lowercase substring matched against the model id. First match wins —
  /// order specific ids before family rules.
  final String pattern;

  /// Input-context cap in tokens (口径 = input cap over total window).
  final int windowTokens;

  /// Declared max output tokens (feeds the output reserve).
  final int outputTokens;

  const ModelWindowSpec(this.pattern, this.windowTokens, this.outputTokens);
}

const List<ModelWindowSpec> kSeedContextWindows = <ModelWindowSpec>[
  // Specific ids before family rules.
  ModelWindowSpec('gpt-5.2-chat-latest', 128_000, 16_384),
  ModelWindowSpec('gpt-5', 272_000, 128_000), // input cap
  ModelWindowSpec('gpt-4.1', 1_047_576, 32_768),
  ModelWindowSpec('gpt-4o', 131_072, 16_384),
  ModelWindowSpec('claude', 200_000, 64_000), // 4.5 line + older
  ModelWindowSpec('glm-5.1', 200_000, 131_072),
  ModelWindowSpec('glm', 131_072, 65_536),
  ModelWindowSpec('kimi', 262_144, 131_072), // K2.x
  ModelWindowSpec('minimax', 204_800, 131_072), // m2.x
  ModelWindowSpec('deepseek', 131_072, 65_536), // V3-era chat/reasoner
  ModelWindowSpec('gemini', 1_048_576, 65_536),
];

/// Resolve the seed window spec for a model id, or `null` when unknown.
ModelWindowSpec? seedWindowForModel(String modelId) {
  final id = modelId.trim().toLowerCase();
  if (id.isEmpty) return null;
  for (final spec in kSeedContextWindows) {
    if (id.contains(spec.pattern)) return spec;
  }
  return null;
}

/// Window lookup order: learned (from R0 overflow errors) → seed table →
/// 1M fallback. Explicit user configuration, once it exists, belongs ahead
/// of the learned value at the call site.
int resolveContextWindowTokens(String modelId, {int? learned}) {
  if (learned != null && learned > 0) return learned;
  return seedWindowForModel(modelId)?.windowTokens ?? unknownModelContextFallback;
}

// ============================================================================
// Token estimation (chars/3 ruler — internal budget measure only; triggers
// use real measured usage).
// ============================================================================

/// Approximate characters per token (matches AnyBuff's estimateTokens).
const int charsPerToken = 3;

int estimateTextTokens(String text) => (text.length / charsPerToken).ceil();

String _stringOf(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  return value.toString();
}

/// Rough token estimate for one neutral OpenAI-format message (content +
/// tool-call arguments), surrogate-safe by construction (UTF-16 length).
int estimateApiMessageTokens(Map<String, dynamic> message) {
  var chars = _stringOf(message['content']).length;
  final calls = message['tool_calls'];
  if (calls is List) {
    for (final call in calls) {
      if (call is! Map) continue;
      final fn = call['function'];
      if (fn is! Map) continue;
      chars += _stringOf(fn['name']).length;
      chars += _stringOf(fn['arguments']).length;
    }
  }
  return (chars / charsPerToken).ceil();
}

/// Rough token estimate for a whole neutral message list.
int estimateApiMessagesTokens(List<Map<String, dynamic>> messages) {
  var total = 0;
  for (final m in messages) {
    total += estimateApiMessageTokens(m);
  }
  return total;
}

// ============================================================================
// R0 mechanical trim: tail-keep, system preserved, pairing-safe cut points.
// ============================================================================

const String contextTrimPlaceholderText =
    '[... earlier messages omitted to fit the context window ...]';

/// Trim [messages] (neutral OpenAI format) so the estimated total fits
/// [maxTokens], keeping the newest tail. Rules (AnyBuff semantics):
///
/// - leading `role:'system'` messages are always preserved;
/// - the cut lands only on a pairing-safe boundary (never before a
///   `role:'tool'` result whose call was dropped — see [firstLegalTailStart]);
/// - a user-role placeholder marks the omission;
/// - the newest message is always kept even when it alone blows the budget.
///
/// Returns `null` when there is nothing to drop (already fits, or only the
/// forced tail would remain) — callers treat that as "irreducible".
List<Map<String, dynamic>>? trimMessagesToFitTokenLimit(
  List<Map<String, dynamic>> messages,
  int maxTokens,
) {
  if (messages.isEmpty || maxTokens <= 0) return null;

  var systemEnd = 0;
  var systemTokens = 0;
  while (systemEnd < messages.length &&
      messages[systemEnd]['role'] == 'system') {
    systemTokens += estimateApiMessageTokens(messages[systemEnd]);
    systemEnd++;
  }

  final total = estimateApiMessagesTokens(messages);
  if (total <= maxTokens) return null;

  final tailBudget = math.max(1, maxTokens - systemTokens);
  var kept = 0;
  var cut = messages.length;
  for (var i = messages.length - 1; i >= systemEnd; i--) {
    final cost = estimateApiMessageTokens(messages[i]);
    if (kept + cost > tailBudget) break;
    kept += cost;
    cut = i;
  }
  if (cut >= messages.length) return null;

  if (cut < systemEnd) cut = systemEnd;
  // Pairing safety: advance past dangling tool results.
  cut = firstLegalTailStart(messages, cut);
  if (cut >= messages.length) return null;

  final out = <Map<String, dynamic>>[
    for (var i = 0; i < systemEnd; i++) messages[i],
  ];
  if (cut > systemEnd) {
    out.add(<String, dynamic>{
      'role': 'user',
      'content': contextTrimPlaceholderText,
    });
  }
  out.addAll(messages.sublist(cut));
  return out;
}
