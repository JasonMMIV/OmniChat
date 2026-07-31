import '../../../core/models/conversation.dart';
import '../../../core/models/chat_message.dart';
import '../models/stats_models.dart';

class StatsAggregationService {
  static StatsSnapshot buildSnapshot({
    required DateTime now,
    required StatsDateRange range,
    required List<Conversation> conversations,
    required Map<String, List<ChatMessage>> messagesByConversation,
    required int launchCount,
    required String unknownProviderLabel,
    required String unknownProjectLabel,
    Map<String, String> projectNames = const {},
    Set<String>? existingProjectIds,
    Map<String, String> providerNames = const {},
  }) {
    final rangeMessages = <ChatMessage>[];
    final heatmapCounts = <DateTime, int>{};
    final modelCounts = <String, int>{};
    final modelProviders = <String, String>{};
    final projectCounts = <String, int>{};

    var inputTokens = 0;
    var outputTokens = 0;
    var cachedTokens = 0;

    for (final conversation in conversations) {
      final messages = messagesByConversation[conversation.id] ?? const [];
      if (range.contains(conversation.createdAt)) {
        final assistantId = conversation.assistantId?.trim().isNotEmpty == true
            ? conversation.assistantId!.trim()
            : '_default';
        final projectExists =
            existingProjectIds == null ||
            assistantId == '_default' ||
            existingProjectIds.contains(assistantId);
        if (projectExists) {
          projectCounts[assistantId] = (projectCounts[assistantId] ?? 0) + 1;
        }
      }

      for (final message in messages) {
        final messageDate = StatsDateRange.normalizeDate(message.timestamp);
        heatmapCounts[messageDate] = (heatmapCounts[messageDate] ?? 0) + 1;

        if (!range.contains(message.timestamp)) continue;

        rangeMessages.add(message);
        final inTok = message.promptTokens ?? 0;
        final outTok = message.completionTokens ?? 0;
        final cacheTok = message.cachedTokens ?? 0;
        final totalTok = message.totalTokens ?? 0;

        if (inTok > 0 || outTok > 0 || cacheTok > 0) {
          inputTokens += inTok;
          outputTokens += outTok;
          cachedTokens += cacheTok;
        } else {
          outputTokens += totalTok;
        }

        final modelId = message.modelId?.trim();
        if (modelId != null && modelId.isNotEmpty) {
          modelCounts[modelId] = (modelCounts[modelId] ?? 0) + 1;
          final providerId = message.providerId?.trim();
          if (providerId != null && providerId.isNotEmpty) {
            modelProviders.putIfAbsent(modelId, () => providerId);
          }
        }
      }
    }

    final filteredConversationCount = conversations
        .where((conversation) => range.contains(conversation.createdAt))
        .length;

    final trendRange = _trendRange(now, range);
    final trend = _buildTrend(
      trendRange: trendRange,
      conversations: conversations,
      messagesByConversation: messagesByConversation,
      providerNames: providerNames,
      unknownProviderLabel: unknownProviderLabel,
    );

    return StatsSnapshot(
      range: range,
      summary: StatsSummary(
        totalConversations: filteredConversationCount,
        totalMessages: rangeMessages.length,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cachedTokens: cachedTokens,
        launchCount: launchCount,
      ),
      heatmap: _buildHeatmap(now, heatmapCounts),
      trend: trend,
      modelRank: _rank(
        modelCounts,
        (id) => id,
        providerFor: (id) => modelProviders[id],
      ),
      projectRank: _projectRank(
        projectCounts,
        projectNames,
        existingProjectIds: existingProjectIds,
      ),
    );
  }

  static ({DateTime start, DateTime end}) _trendRange(
    DateTime now,
    StatsDateRange range,
  ) {
    final today = StatsDateRange.normalizeDate(now);
    if (range.isAllTime) {
      return (start: StatsDateRange.addCalendarDays(today, -29), end: today);
    }
    return (
      start: range.start ?? StatsDateRange.addCalendarDays(today, -29),
      end: range.end ?? today,
    );
  }

  static List<StatsHeatmapDay> _buildHeatmap(
    DateTime now,
    Map<DateTime, int> counts,
  ) {
    final today = StatsDateRange.normalizeDate(now);
    final start = StatsDateRange.addCalendarDays(today, -364);
    final days = <StatsHeatmapDay>[];
    for (
      var date = start;
      !date.isAfter(today);
      date = StatsDateRange.addCalendarDays(date, 1)
    ) {
      days.add(StatsHeatmapDay(date: date, count: counts[date] ?? 0));
    }
    return days;
  }

  static List<StatsTrendDay> _buildTrend({
    required ({DateTime start, DateTime end}) trendRange,
    required List<Conversation> conversations,
    required Map<String, List<ChatMessage>> messagesByConversation,
    required Map<String, String> providerNames,
    required String unknownProviderLabel,
  }) {
    final buckets = <DateTime, Map<String, StatsTokenBucket>>{};
    for (
      var date = trendRange.start;
      !date.isAfter(trendRange.end);
      date = StatsDateRange.addCalendarDays(date, 1)
    ) {
      buckets[date] = <String, StatsTokenBucket>{};
    }

    for (final conversation in conversations) {
      final messages = messagesByConversation[conversation.id] ?? const [];
      for (final message in messages) {
        final date = StatsDateRange.normalizeDate(message.timestamp);
        if (date.isBefore(trendRange.start) || date.isAfter(trendRange.end)) {
          continue;
        }
        final inTok = message.promptTokens ?? 0;
        final outTok = message.completionTokens ?? 0;
        final cacheTok = message.cachedTokens ?? 0;
        final totalTok = message.totalTokens ?? 0;
        final uncategorizedTok = (inTok == 0 && outTok == 0 && totalTok > 0) ? totalTok : 0;

        final providerId = message.providerId?.trim();
        if ((providerId == null || providerId.isEmpty) &&
            inTok == 0 && outTok == 0 && cacheTok == 0 && uncategorizedTok == 0) {
          continue;
        }
        final providerLabel = providerId == null || providerId.isEmpty
            ? unknownProviderLabel
            : (providerNames[providerId] ?? providerId);
        final dayBuckets = buckets[date]!;
        final previous = dayBuckets[providerLabel] ?? const StatsTokenBucket();
        dayBuckets[providerLabel] = previous.add(
          inputTokens: inTok,
          outputTokens: outTok,
          cachedTokens: cacheTok,
          uncategorizedTokens: uncategorizedTok,
          activityCount: 1,
        );
      }
    }

    return [
      for (final entry in buckets.entries)
        StatsTrendDay(
          date: entry.key,
          providerTokens: Map.unmodifiable(entry.value),
        ),
    ];
  }

  static List<StatsRankItem> _rank(
    Map<String, int> counts,
    String Function(String id) labelFor, {
    String? Function(String id)? providerFor,
  }) {
    final entries = counts.entries.toList();
    entries.sort((a, b) {
      final byValue = b.value.compareTo(a.value);
      if (byValue != 0) return byValue;
      return 0;
    });
    return [
      for (final entry in entries)
        StatsRankItem(
          id: entry.key,
          label: labelFor(entry.key),
          value: entry.value,
          providerId: providerFor?.call(entry.key),
        ),
    ];
  }

  static List<StatsRankItem> _projectRank(
    Map<String, int> counts,
    Map<String, String> projectNames, {
    Set<String>? existingProjectIds,
    bool hideUnresolved = false,
  }) {
    final valuesByLabel = <String, int>{};
    final representativeIdByLabel = <String, String>{};
    final representativeValueByLabel = <String, int>{};

    for (final entry in counts.entries) {
      final id = entry.key;
      final isDefault = id == '_default';
      final isKnown = projectNames.containsKey(id);
      if (!isDefault &&
          existingProjectIds != null &&
          !existingProjectIds.contains(id)) {
        continue;
      }
      if (!isDefault && hideUnresolved && !isKnown) continue;

      final resolvedLabel = projectNames[id]?.trim();
      final label = resolvedLabel == null || resolvedLabel.isEmpty
          ? id
          : resolvedLabel;
      valuesByLabel[label] = (valuesByLabel[label] ?? 0) + entry.value;
      final representativeValue = representativeValueByLabel[label];
      if (representativeValue == null || entry.value > representativeValue) {
        representativeIdByLabel[label] = id;
        representativeValueByLabel[label] = entry.value;
      }
    }

    final items = [
      for (final entry in valuesByLabel.entries)
        StatsRankItem(
          id: representativeIdByLabel[entry.key]!,
          label: entry.key,
          value: entry.value,
        ),
    ];
    items.sort((a, b) {
      final byValue = b.value.compareTo(a.value);
      if (byValue != 0) return byValue;
      return a.label.compareTo(b.label);
    });
    return items;
  }
}
