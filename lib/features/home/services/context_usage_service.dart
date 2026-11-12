// Context usage snapshot + estimator (docs/context_usage_ring_plan.md v2).
//
// Pure computation — no Flutter UI imports. Version collapsing and the
// compacted-head estimate are injected so unit tests can drive this without
// MessageBuilderService (which needs a BuildContext). The controller wires the
// real implementations (collapseVersions / neutralMessagesFor +
// compactHistoryMessages).
//
// The `used` number answers "how full is the context for the NEXT request":
// the measured prompt of the last assistant turn, plus that turn's completion
// (completionTokens when the provider reported it), plus everything sent
// after it, estimated at chars/3.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/services/agent/compaction/context_trim.dart';
import '../../../core/services/api/tool_result_images.dart';

/// One-shot snapshot computed by the controller and pushed into a
/// [ValueNotifier]. Equality is value-based so the notifier only fires when
/// something actually changed.
@immutable
class ContextUsageSnapshot {
  final int usedTokens;

  /// null = window unknown → the display layer shows an empty ring and a
  /// `used / ...` header (no percentage).
  final int? maxTokens;

  /// Whether a measured prompt baseline was used.
  final bool measured;

  /// Whether any part of [usedTokens] is estimated.
  final bool estimated;

  /// Effective logical model id this snapshot was computed for (debug and
  /// staleness checks).
  final String? modelId;

  /// Effective provider key this snapshot was computed for.
  final String? providerKey;

  const ContextUsageSnapshot({
    required this.usedTokens,
    required this.maxTokens,
    required this.measured,
    required this.estimated,
    this.modelId,
    this.providerKey,
  });

  bool get hasWindow => maxTokens != null && maxTokens! > 0;

  /// Unclamped ratio; > 1 means over the window (model switch / stale data).
  double get rawRatio => hasWindow ? usedTokens / maxTokens! : 0.0;

  /// Clamped 0..1 for the ring arc.
  double get ratio => rawRatio.clamp(0.0, 1.0).toDouble();

  /// Real percentage for the header badge (can be > 100 — do not clamp).
  /// Only meaningful when [hasWindow]; the header hides the badge otherwise.
  int get displayPercent => (rawRatio * 100).round();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContextUsageSnapshot &&
          other.usedTokens == usedTokens &&
          other.maxTokens == maxTokens &&
          other.measured == measured &&
          other.estimated == estimated &&
          other.modelId == modelId &&
          other.providerKey == providerKey;

  @override
  int get hashCode => Object.hash(
    usedTokens,
    maxTokens,
    measured,
    estimated,
    modelId,
    providerKey,
  );
}

/// chars/3 estimate of one chat message including its tool events (args +
/// result bodies) — the same ruler as
/// `MessageGenerationService._estimateRawMessageTokens`, shared here so the
/// ring and the compaction trigger never drift apart in spirit.
int estimateChatMessageTokens(
  ChatMessage message, {
  required Iterable<Map<String, dynamic>> toolEvents,
}) {
  // Conservative per-image allowance: a vision-capable model bills roughly
  // 1.1k tokens for a 1568 px image (Claude/OpenAI) and ~258 for Gemini.
  // 1.5k keeps the ring/compaction trigger from underestimating a screenshot
  // round. The marker parser skips remote/data markers, which Stage 2 does not
  // send as images.
  const int toolImageTokenEstimate = 1500;
  var chars = message.content.length;
  var imageTokens = 0;
  for (final e in toolEvents) {
    try {
      chars += jsonEncode(e['arguments'] ?? const <String, dynamic>{}).length;
    } catch (_) {}
    final content = (e['content'] ?? '').toString();
    chars += content.length;
    imageTokens += extractMarkers(content).length * toolImageTokenEstimate;
  }
  return (chars / charsPerToken).ceil() + imageTokens;
}

/// `12.0k` / `1.2M` — mirrors AnyBuff's `formatTokens` (keeps the `.0`).
String compactTokenText(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

/// Whether a refresh result may still be applied: it must belong to the
/// newest refresh ([epoch] == [currentEpoch]) for the same conversation and
/// the same effective model. Guards the async learned-window lookup against
/// stale writes after a conversation/model switch.
bool contextUsageResultIsCurrent({
  required int epoch,
  required int currentEpoch,
  required String? currentConversationId,
  required String resultConversationId,
  required ({String providerKey, String modelId})? currentModelKey,
  required ({String providerKey, String modelId}) resultModelKey,
}) {
  return epoch == currentEpoch &&
      currentConversationId != null &&
      currentConversationId == resultConversationId &&
      currentModelKey != null &&
      currentModelKey == resultModelKey;
}

/// Compute the current context usage for the input-bar ring / menu header.
///
/// Mirrors `MessageBuilderService.buildApiMessages` exactly:
/// truncateIndex raw slice → version collapse → `compactBeforeIndex` split
/// (the head is replaced by one deterministic `<conversation_summary>`).
/// A measured prompt is used as the baseline whenever a usable one exists;
/// everything the next request adds on top is estimated.
ContextUsageSnapshot computeContextUsage({
  required List<ChatMessage> rawMessages,
  required Map<String, int> versionSelections,
  required int truncateIndex,
  required int compactBeforeIndex,
  required bool enableAutoCompaction,
  required int? learnedWindowTokens,
  required int? catalogWindowTokens,

  /// Explicit user configuration (modelOverrides `contextWindow`). Wins over
  /// the learned value — an intentional correction must not be shadowed by a
  /// device-local observation.
  required int? userWindowTokens,
  required String? currentModelId,
  required String? currentProviderKey,
  required String? streamingMessageId,
  required List<ChatMessage> Function(
    List<ChatMessage> items,
    Map<String, int> selections,
  )
  collapseVersions,
  required int Function(ChatMessage message) estimateMessageTokens,
  required int Function(List<ChatMessage> headMessages)
  estimateCompactedHeadTokens,
}) {
  // 1. Window: user override > learned > catalog > unknown. Never the 1M
  //    fallback — an unknown window must show an empty ring, not a fake
  //    ratio.
  final maxTokens = (userWindowTokens != null && userWindowTokens > 0)
      ? userWindowTokens
      : (learnedWindowTokens != null && learnedWindowTokens > 0)
      ? learnedWindowTokens
      : (catalogWindowTokens != null && catalogWindowTokens > 0
            ? catalogWindowTokens
            : null);

  // 2. Raw slice — same guard as buildApiMessages (`<=`, not `<`): a cleared
  //    conversation has truncateIndex == rawMessages.length and must slice to
  //    empty, not fall back to the full history.
  final tValid = truncateIndex >= 0 && truncateIndex <= rawMessages.length;
  final rawStart = tValid ? truncateIndex : 0;
  final sourceAll = tValid
      ? rawMessages.sublist(truncateIndex)
      : List<ChatMessage>.of(rawMessages);

  // 3. compactBeforeIndex split (same arithmetic as buildApiMessages).
  final compactSplit = compactBeforeIndex - rawStart;
  final hasCompact =
      enableAutoCompaction &&
      compactBeforeIndex > 0 &&
      compactSplit > 0 &&
      compactSplit < sourceAll.length;

  final List<ChatMessage> active;
  final List<ChatMessage>? compactedHead;
  if (hasCompact) {
    compactedHead = collapseVersions(
      sourceAll.sublist(0, compactSplit),
      versionSelections,
    );
    active = collapseVersions(
      sourceAll.sublist(compactSplit),
      versionSelections,
    );
  } else {
    active = collapseVersions(sourceAll, versionSelections);
    compactedHead = null;
  }

  // 4. Find the newest usable measured baseline in the live tail.
  final rawIndexById = <String, int>{
    for (var i = 0; i < rawMessages.length; i++) rawMessages[i].id: i,
  };

  ChatMessage? measuredMessage;
  var measuredAt = -1;
  for (var i = active.length - 1; i >= 0; i--) {
    final m = active[i];
    if (m.role != 'assistant' || (m.promptTokens ?? 0) <= 0) continue;
    final rawIndex = rawIndexById[m.id];
    if (rawIndex == null || rawIndex < rawStart) continue;
    // Auto-compaction: measurements taken before the boundary are stale —
    // their prompt still contained the raw (unsummarized) head.
    if (hasCompact && rawIndex < compactBeforeIndex) continue;
    // The effective model must match; old tokenizer numbers against a new
    // window are misleading. Legacy rows without identity are rejected too.
    if (m.modelId != currentModelId || m.providerId != currentProviderKey) {
      continue;
    }
    measuredMessage = m;
    measuredAt = i;
    break;
  }

  // 5. Measured path: prompt baseline + completion + trailing delta.
  if (measuredMessage != null) {
    // The measured prompt does not include this assistant's own completion,
    // but the next request does. Only the completion is new here — this
    // assistant's tool calls/results were already part of the last round's
    // prompt in a multi-round agent loop, so they must NOT be re-added.
    final hasExactCompletion = (measuredMessage.completionTokens ?? 0) > 0;
    final completion = hasExactCompletion
        ? measuredMessage.completionTokens!
        : estimateTextTokens(measuredMessage.content);
    var delta = completion;
    var hasEstimate = !hasExactCompletion;
    for (var j = measuredAt + 1; j < active.length; j++) {
      final m = active[j];
      // In-flight output is not part of the next prompt.
      if (m.role == 'assistant' && m.id == streamingMessageId) continue;
      delta += estimateMessageTokens(m);
      hasEstimate = true;
    }
    return ContextUsageSnapshot(
      usedTokens: measuredMessage.promptTokens! + delta,
      maxTokens: maxTokens,
      measured: true,
      estimated: hasEstimate || streamingMessageId != null,
      modelId: currentModelId,
      providerKey: currentProviderKey,
    );
  }

  // 6. Estimate path: compacted head summary + live messages.
  //    Known lower bound: system prompt, tool definitions, memory /
  //    instruction / search injections and the todo pair are not included —
  //    the UI must show the ≈ badge for this path.
  var used = compactedHead == null
      ? 0
      : estimateCompactedHeadTokens(compactedHead);
  for (final m in active) {
    used += estimateMessageTokens(m);
  }
  return ContextUsageSnapshot(
    usedTokens: used,
    maxTokens: maxTokens,
    measured: false,
    estimated: true,
    modelId: currentModelId,
    providerKey: currentProviderKey,
  );
}
