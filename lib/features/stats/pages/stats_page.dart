import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../home/widgets/assistant_avatar.dart';
import '../../home/widgets/model_icon.dart';
import '../models/stats_models.dart';
import '../services/stats_aggregation_service.dart';
import '../widgets/stats_heatmap.dart';
import '../widgets/stats_metric_grid.dart';
import '../widgets/stats_rank_section.dart';
import '../widgets/stats_section_card.dart';
import '../widgets/stats_usage_chart.dart';

class StatsPage extends StatefulWidget {
  const StatsPage({super.key, this.snapshotOverride, this.showAppBar = true});

  final StatsSnapshot? snapshotOverride;
  final bool showAppBar;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  late StatsDateRange _range;

  @override
  void initState() {
    super.initState();
    _range =
        widget.snapshotOverride?.range ??
        StatsDateRange.allTime(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final snapshot = widget.snapshotOverride ?? _buildSnapshot(context);
    final assistantById = widget.snapshotOverride == null
        ? {
            for (final assistant
                in context.watch<AssistantProvider>().assistants)
              assistant.id: assistant,
          }
        : <String, Assistant>{};

    final body = ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _RangeSelector(
          selected: _range.preset,
          onChanged: _setPreset,
          onCustom: _pickCustomRange,
        ),
        const SizedBox(height: 10),
        StatsSectionCard(
          title: l10n.statsPageHeatmapTitle,
          child: StatsHeatmap(days: snapshot.heatmap),
        ),
        const SizedBox(height: 12),
        StatsSectionCard(
          title: l10n.statsPageSummaryTitle,
          child: StatsMetricGrid(summary: snapshot.summary),
        ),
        const SizedBox(height: 12),
        StatsSectionCard(
          title: l10n.statsPageUsageTrendTitle,
          child: StatsUsageChart(days: snapshot.trend),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 600;
            final sections = [
              StatsRankSection(
                title: l10n.statsPageModelUsageTitle,
                leftHeader: l10n.statsPageModelColumn,
                rightHeader: l10n.statsPageMessagesColumn,
                items: snapshot.modelRank,
                leadingBuilder: (context, item) => CurrentModelIcon(
                  key: ValueKey('stats-model-icon-${item.id}'),
                  providerKey: item.providerId,
                  modelId: item.id,
                  size: 32,
                  withBackground: false,
                ),
              ),
              StatsRankSection(
                title: l10n.statsPageAssistantUsageTitle,
                leftHeader: l10n.statsPageAssistantColumn,
                rightHeader: l10n.statsPageTopicsColumn,
                items: snapshot.projectRank,
                leadingBuilder: (context, item) => AssistantAvatar(
                  key: ValueKey('stats-assistant-avatar-${item.id}'),
                  assistant: assistantById[item.id],
                  fallbackName: item.label,
                  size: 20,
                ),
              ),
            ];
            if (!wide) {
              return Column(
                children: [
                  for (var i = 0; i < sections.length; i++) ...[
                    sections[i],
                    if (i != sections.length - 1) const SizedBox(height: 12),
                  ],
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < sections.length; i++) ...[
                  Expanded(child: sections[i]),
                  if (i != sections.length - 1) const SizedBox(width: 12),
                ],
              ],
            );
          },
        ),
      ],
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            minSize: 44,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.statsPageTitle),
      ),
      body: body,
    );
  }

  StatsSnapshot _buildSnapshot(BuildContext context) {
    final now = DateTime.now();
    final l10n = AppLocalizations.of(context)!;
    final chatService = context.watch<ChatService>();
    final settings = context.watch<SettingsProvider>();
    final assistantProvider = context.watch<AssistantProvider>();

    final conversations = chatService.getAllConversations();
    final messagesByConversation = {
      for (final c in conversations) c.id: chatService.getMessages(c.id),
    };

    final projectNames = {
      for (final assistant in assistantProvider.assistants)
        assistant.id: assistant.name.trim().isEmpty
            ? l10n.statsPageUnknownAssistant
            : assistant.name.trim(),
      '_default': l10n.statsPageUnknownAssistant,
    };
    final existingProjectIds = {
      for (final assistant in assistantProvider.assistants) assistant.id,
      '_default',
    };
    final providerNames = {
      for (final entry in settings.providerConfigs.entries)
        entry.key: entry.value.name,
    };

    return StatsAggregationService.buildSnapshot(
      now: now,
      range: _range,
      conversations: conversations,
      messagesByConversation: messagesByConversation,
      launchCount: settings.appLaunchCount,
      projectNames: projectNames,
      existingProjectIds: existingProjectIds,
      providerNames: providerNames,
      unknownProviderLabel: l10n.statsPageUnknownProvider,
      unknownProjectLabel: l10n.statsPageUnknownAssistant,
    );
  }

  void _setPreset(StatsDateRangePreset preset) {
    final now = DateTime.now();
    setState(() {
      _range = switch (preset) {
        StatsDateRangePreset.allTime => StatsDateRange.allTime(now),
        StatsDateRangePreset.last30Days => StatsDateRange.last30Days(now),
        StatsDateRangePreset.previousMonth => StatsDateRange.previousMonth(now),
        StatsDateRangePreset.previousQuarter => StatsDateRange.previousQuarter(
          now,
        ),
        StatsDateRangePreset.custom => _range,
      };
    });
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final end = StatsDateRange.normalizeDate(now);
    final initialStart = _range.start ?? StatsDateRange.addCalendarDays(end, -29);
    final initialEnd = _range.end ?? end;

    final selected = await _showCustomRangePicker(
      context,
      initialRange: DateTimeRange(start: initialStart, end: initialEnd),
      firstDate: DateTime(2000),
      lastDate: end,
    );
    if (selected == null) return;
    setState(() {
      _range = StatsDateRange.custom(selected.start, selected.end);
    });
  }
}

class _RangeSelector extends StatelessWidget {
  const _RangeSelector({
    required this.selected,
    required this.onChanged,
    required this.onCustom,
  });

  final StatsDateRangePreset selected;
  final ValueChanged<StatsDateRangePreset> onChanged;
  final VoidCallback onCustom;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final options = [
      (StatsDateRangePreset.allTime, l10n.statsPageRangeAllTime),
      (StatsDateRangePreset.last30Days, l10n.statsPageRangeLast30Days),
      (StatsDateRangePreset.previousMonth, l10n.statsPageRangePreviousMonth),
      (
        StatsDateRangePreset.previousQuarter,
        l10n.statsPageRangePreviousQuarter,
      ),
      (StatsDateRangePreset.custom, l10n.statsPageRangeCustom),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < options.length; i++) ...[
            _RangeButton(
              label: options[i].$2,
              selected: selected == options[i].$1,
              onTap: () {
                if (options[i].$1 == StatsDateRangePreset.custom) {
                  onCustom();
                } else {
                  onChanged(options[i].$1);
                }
              },
            ),
            if (i != options.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _RangeButton extends StatelessWidget {
  const _RangeButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final background = selected
        ? (isDark
              ? Colors.white.withValues(alpha: 0.16)
              : const Color(0xFFE2E5E9))
        : (isDark
              ? Colors.white.withValues(alpha: 0.06)
              : const Color(0xFFF2F3F5));
    final textColor = theme.colorScheme.onSurface.withValues(
      alpha: selected ? 0.94 : 0.62,
    );
    return IosCardPress(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      baseColor: background,
      pressedBlendStrength: selected ? 0 : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: 12,
          fontWeight: selected
              ? AppFontWeights.emphasis
              : AppFontWeights.semibold,
        ),
      ),
    );
  }
}

Future<DateTimeRange?> _showCustomRangePicker(
  BuildContext context, {
  required DateTimeRange initialRange,
  required DateTime firstDate,
  required DateTime lastDate,
}) {
  final isDesktopWidth = MediaQuery.sizeOf(context).width >= 720;
  if (isDesktopWidth) {
    return showDialog<DateTimeRange>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        backgroundColor: Colors.transparent,
        child: _CustomRangeSheet(
          initialRange: initialRange,
          firstDate: firstDate,
          lastDate: lastDate,
          desktop: true,
        ),
      ),
    );
  }
  return showModalBottomSheet<DateTimeRange>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _CustomRangeSheet(
      initialRange: initialRange,
      firstDate: firstDate,
      lastDate: lastDate,
    ),
  );
}

class _CustomRangeSheet extends StatefulWidget {
  const _CustomRangeSheet({
    required this.initialRange,
    required this.firstDate,
    required this.lastDate,
    this.desktop = false,
  });

  final DateTimeRange initialRange;
  final DateTime firstDate;
  final DateTime lastDate;
  final bool desktop;

  @override
  State<_CustomRangeSheet> createState() => _CustomRangeSheetState();
}

class _CustomRangeSheetState extends State<_CustomRangeSheet> {
  late DateTime _startDate;
  late DateTime _endDate;
  late DateTime _visibleMonth;

  bool _pickingStart = true;
  _CalendarPickerMode _pickerMode = _CalendarPickerMode.day;

  @override
  void initState() {
    super.initState();
    _startDate = StatsDateRange.normalizeDate(widget.initialRange.start);
    _endDate = StatsDateRange.normalizeDate(widget.initialRange.end);
    _visibleMonth = DateTime(_endDate.year, _endDate.month);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeDate = _pickingStart ? _startDate : _endDate;
    final mediaSize = MediaQuery.sizeOf(context);
    final localeName = Localizations.localeOf(context).toString();

    Widget content = Container(
      width: widget.desktop ? 420 : double.infinity,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2126) : const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(24),
        boxShadow: widget.desktop
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.32 : 0.16),
                  blurRadius: 28,
                  offset: const Offset(0, 10),
                ),
              ]
            : null,
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.statsPageCustomRangeTitle,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.9),
                    fontSize: 16,
                    fontWeight: AppFontWeights.emphasis,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Lucide.X, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _DateField(
                  label: l10n.statsPageCustomRangeStart,
                  date: _startDate,
                  onTap: () {
                    setState(() {
                      _pickingStart = true;
                      _visibleMonth = DateTime(
                        _startDate.year,
                        _startDate.month,
                      );
                    });
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _DateField(
                  label: l10n.statsPageCustomRangeEnd,
                  date: _endDate,
                  onTap: () {
                    setState(() {
                      _pickingStart = false;
                      _visibleMonth = DateTime(_endDate.year, _endDate.month);
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              IosCardPress(
                onTap: () {
                  setState(() {
                    _pickerMode = _pickerMode == _CalendarPickerMode.day
                        ? _CalendarPickerMode.month
                        : _CalendarPickerMode.day;
                  });
                },
                borderRadius: BorderRadius.circular(10),
                baseColor: Colors.transparent,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      DateFormat(
                        _pickerMode == _CalendarPickerMode.day
                            ? 'yyyy MMM'
                            : 'yyyy',
                        localeName,
                      ).format(_visibleMonth),
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.88),
                        fontSize: 14,
                        fontWeight: AppFontWeights.emphasis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      _pickerMode == _CalendarPickerMode.day
                          ? Lucide.ChevronRight
                          : Lucide.ChevronDown,
                      size: 15,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              IosIconButton(
                icon: Lucide.ChevronLeft,
                size: 16,
                minSize: 32,
                onTap: () => _shiftYear(-1),
              ),
              const SizedBox(width: 4),
              IosIconButton(
                icon: Lucide.ChevronRight,
                size: 16,
                minSize: 32,
                onTap: () => _shiftYear(1),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_pickerMode == _CalendarPickerMode.day) ...[
            Row(
              children: [
                for (final dayLabel in _weekdayLabels(context))
                  Expanded(
                    child: Center(
                      child: Text(
                        dayLabel,
                        style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.45),
                          fontSize: 11,
                          fontWeight: AppFontWeights.semibold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _MonthGrid(
              visibleMonth: _visibleMonth,
              selectedDate: activeDate,
              firstDate: widget.firstDate,
              lastDate: widget.lastDate,
              onSelected: (date) {
                setState(() {
                  if (_pickingStart) {
                    _startDate = date;
                    if (_endDate.isBefore(_startDate)) {
                      _endDate = _startDate;
                    }
                  } else {
                    _endDate = date;
                    if (_startDate.isAfter(_endDate)) {
                      _startDate = _endDate;
                    }
                  }
                });
              },
            ),
          ] else
            _YearMonthGrid(
              visibleMonth: _visibleMonth,
              selectedDate: activeDate,
              firstDate: widget.firstDate,
              lastDate: widget.lastDate,
              onSelected: (month) {
                setState(() {
                  _visibleMonth = DateTime(_visibleMonth.year, month);
                  _pickerMode = _CalendarPickerMode.day;
                });
              },
            ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.statsPageCustomRangeCancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  Navigator.of(context).pop(
                    DateTimeRange(start: _startDate, end: _endDate),
                  );
                },
                child: Text(l10n.statsPageCustomRangeApply),
              ),
            ],
          ),
        ],
      ),
    );

    if (widget.desktop) return content;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mediaSize.height * 0.88),
        child: SingleChildScrollView(
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: content,
            ),
          ),
        ),
      ),
    );
  }

  void _shiftYear(int delta) {
    setState(() {
      _visibleMonth = _clampVisibleMonth(
        DateTime(_visibleMonth.year + delta, _visibleMonth.month),
      );
    });
  }

  DateTime _clampVisibleMonth(DateTime month) {
    final firstMonth = DateTime(widget.firstDate.year, widget.firstDate.month);
    final lastMonth = DateTime(widget.lastDate.year, widget.lastDate.month);
    if (month.isBefore(firstMonth)) return firstMonth;
    if (month.isAfter(lastMonth)) return lastMonth;
    return month;
  }

  List<String> _weekdayLabels(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final weekStart = DateTime(2026, 5, 4);
    final formatter = DateFormat.E(locale);
    return [
      for (var i = 0; i < 7; i++)
        formatter.format(StatsDateRange.addCalendarDays(weekStart, i)),
    ];
  }
}

enum _CalendarPickerMode { day, month }

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.visibleMonth,
    required this.selectedDate,
    required this.firstDate,
    required this.lastDate,
    required this.onSelected,
  });

  final DateTime visibleMonth;
  final DateTime selectedDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final ValueChanged<DateTime> onSelected;

  @override
  Widget build(BuildContext context) {
    final monthStart = DateTime(visibleMonth.year, visibleMonth.month);
    final gridStart = StatsDateRange.addCalendarDays(
      monthStart,
      DateTime.monday - monthStart.weekday,
    );
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        mainAxisSpacing: 7,
        crossAxisSpacing: 7,
      ),
      itemCount: 42,
      itemBuilder: (context, index) {
        final date = StatsDateRange.addCalendarDays(gridStart, index);
        return _DateCell(
          date: date,
          inVisibleMonth: date.month == visibleMonth.month,
          selected: StatsDateRange.normalizeDate(date) == selectedDate,
          enabled: !date.isBefore(firstDate) && !date.isAfter(lastDate),
          onTap: () => onSelected(StatsDateRange.normalizeDate(date)),
        );
      },
    );
  }
}

class _YearMonthGrid extends StatelessWidget {
  const _YearMonthGrid({
    required this.visibleMonth,
    required this.selectedDate,
    required this.firstDate,
    required this.lastDate,
    required this.onSelected,
  });

  final DateTime visibleMonth;
  final DateTime selectedDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final formatter = DateFormat.MMM(locale);
    return GridView.builder(
      key: const ValueKey('stats-custom-month-picker'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.85,
      ),
      itemCount: 12,
      itemBuilder: (context, index) {
        final month = index + 1;
        final monthDate = DateTime(visibleMonth.year, month);
        final enabled =
            !_monthIsBefore(monthDate, firstDate) &&
            !_monthIsAfter(monthDate, lastDate);
        return _MonthCell(
          key: ValueKey('stats-month-cell-$month'),
          label: formatter.format(monthDate),
          selected:
              selectedDate.year == visibleMonth.year &&
              selectedDate.month == month,
          enabled: enabled,
          onTap: () => onSelected(month),
        );
      },
    );
  }

  bool _monthIsBefore(DateTime month, DateTime boundary) {
    return month.year < boundary.year ||
        (month.year == boundary.year && month.month < boundary.month);
  }

  bool _monthIsAfter(DateTime month, DateTime boundary) {
    return month.year > boundary.year ||
        (month.year == boundary.year && month.month > boundary.month);
  }
}

class _MonthCell extends StatelessWidget {
  const _MonthCell({
    super.key,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = selected
        ? (isDark
              ? Colors.white.withValues(alpha: 0.18)
              : const Color(0xFFDADDE2))
        : (isDark
              ? Colors.white.withValues(alpha: 0.06)
              : const Color(0xFFECEEF1));
    return IosCardPress(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(13),
      baseColor: background,
      pressedBlendStrength: selected ? 0 : null,
      padding: EdgeInsets.zero,
      child: Center(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: cs.onSurface.withValues(alpha: enabled ? 0.82 : 0.22),
            fontSize: 12,
            fontWeight: selected
                ? AppFontWeights.heavy
                : AppFontWeights.emphasis,
          ),
        ),
      ),
    );
  }
}

class _DateCell extends StatelessWidget {
  const _DateCell({
    required this.date,
    required this.inVisibleMonth,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final DateTime date;
  final bool inVisibleMonth;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = selected
        ? (isDark
              ? Colors.white.withValues(alpha: 0.18)
              : const Color(0xFFDADDE2))
        : Colors.transparent;
    final alpha = !enabled
        ? 0.18
        : inVisibleMonth
        ? 0.82
        : 0.34;
    return IosCardPress(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      baseColor: background,
      pressedBlendStrength: selected ? 0 : null,
      padding: EdgeInsets.zero,
      child: Center(
        child: Text(
          date.day.toString(),
          style: TextStyle(
            color: cs.onSurface.withValues(alpha: alpha),
            fontSize: 12,
            fontWeight: selected
                ? AppFontWeights.heavy
                : AppFontWeights.semibold,
          ),
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.date,
    required this.onTap,
  });

  final String label;
  final DateTime date;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IosCardPress(
      onTap: onTap,
      borderRadius: BorderRadius.circular(13),
      baseColor: isDark
          ? Colors.white.withValues(alpha: 0.07)
          : const Color(0xFFECEEF1),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.52),
              fontSize: 11,
              fontWeight: AppFontWeights.semibold,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            DateFormat('yyyy-MM-dd').format(date),
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.9),
              fontSize: 13,
              fontWeight: AppFontWeights.emphasis,
            ),
          ),
        ],
      ),
    );
  }
}
