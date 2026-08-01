import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/utils/reasoning_capabilities.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../core/services/haptics.dart';

Future<ReasoningBudgetSelection?> showReasoningBudgetSheet(
  BuildContext context, {
  int? initialBudget,
  String? modelProvider,
  String? modelId,
  bool allowInherit = false,
}) async {
  return showModalBottomSheet<ReasoningBudgetSelection>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _ReasoningBudgetSheet(
      initialBudget: initialBudget,
      modelProvider: modelProvider,
      modelId: modelId,
      allowInherit: allowInherit,
    ),
  );
}

class _ReasoningBudgetSheet extends StatefulWidget {
  const _ReasoningBudgetSheet({
    this.initialBudget,
    this.modelProvider,
    this.modelId,
    this.allowInherit = false,
  });

  final int? initialBudget;
  final String? modelProvider;
  final String? modelId;
  final bool allowInherit;

  @override
  State<_ReasoningBudgetSheet> createState() => _ReasoningBudgetSheetState();
}

class _ReasoningBudgetSheetState extends State<_ReasoningBudgetSheet> {
  late int? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.allowInherit
        ? widget.initialBudget
        : (widget.initialBudget ?? ReasoningBudget.auto);
  }

  void _select(int? value) {
    Navigator.of(context).pop(ReasoningBudgetSelection(value));
  }

  ReasoningCapabilities _capabilities(SettingsProvider settings) {
    final assistant = context.read<AssistantProvider>().currentAssistant;
    final provider =
        widget.modelProvider ??
        assistant?.chatModelProvider ??
        settings.currentModelProvider;
    final model =
        widget.modelId ?? assistant?.chatModelId ?? settings.currentModelId;
    if (provider == null || model == null) {
      return ReasoningCapabilities.unsupported;
    }
    return settings.reasoningCapabilities(provider, model);
  }

  bool _active(int? value, ReasoningCapabilities capabilities) {
    if (value == null) return widget.allowInherit && _selected == null;
    final selected =
        capabilities.thinkingAlwaysOn && _selected == ReasoningBudget.off
        ? ReasoningBudget.auto
        : _selected;
    return ReasoningBudget.bucket(
          selected,
          allowXhigh: capabilities.supportsXhigh,
          allowMax: capabilities.supportsMax,
        ) ==
        value;
  }

  Widget _tile(
    IconData icon,
    String title,
    int? value, {
    required ReasoningCapabilities capabilities,
    bool deepthink = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final active = _active(value, capabilities);
    final Color iconColor = active ? cs.primary : cs.onSurface.withOpacity(0.7);
    final Color onColor = active ? cs.primary : cs.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: SizedBox(
        height: 48,
        child: IosCardPress(
          borderRadius: BorderRadius.circular(14),
          baseColor: cs.surface,
          duration: const Duration(milliseconds: 260),
          onTap: () {
            Haptics.light();
            _select(value);
          },
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              deepthink
                  ? SvgPicture.asset(
                      'assets/icons/deepthink.svg',
                      width: 18,
                      height: 18,
                      colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
                    )
                  : Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: onColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (active)
                Icon(Lucide.Check, size: 18, color: cs.primary)
              else
                const SizedBox(width: 18),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final capabilities = _capabilities(settings);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;
    return SafeArea(
      top: false,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 6),
                // No title per iOS style; keep content close to handle
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    children: [
                      if (widget.allowInherit)
                        _tile(
                          Lucide.Settings2,
                          l10n.reasoningBudgetSheetUseGlobal,
                          null,
                          capabilities: capabilities,
                        ),
                      if (!capabilities.thinkingAlwaysOn)
                        _tile(
                          Lucide.X,
                          l10n.reasoningBudgetSheetOff,
                          ReasoningBudget.off,
                          capabilities: capabilities,
                        ),
                      _tile(
                        Lucide.Settings2,
                        l10n.reasoningBudgetSheetAuto,
                        ReasoningBudget.auto,
                        capabilities: capabilities,
                      ),
                      _tile(
                        Lucide.Brain,
                        l10n.reasoningBudgetSheetLight,
                        ReasoningBudget.light,
                        capabilities: capabilities,
                        deepthink: true,
                      ),
                      _tile(
                        Lucide.Brain,
                        l10n.reasoningBudgetSheetMedium,
                        ReasoningBudget.medium,
                        capabilities: capabilities,
                        deepthink: true,
                      ),
                      _tile(
                        Lucide.Brain,
                        l10n.reasoningBudgetSheetHeavy,
                        ReasoningBudget.heavy,
                        capabilities: capabilities,
                        deepthink: true,
                      ),
                      if (capabilities.supportsXhigh)
                        _tile(
                          Lucide.Brain,
                          l10n.reasoningBudgetSheetXhigh,
                          ReasoningBudget.xhigh,
                          capabilities: capabilities,
                          deepthink: true,
                        ),
                      if (capabilities.supportsMax)
                        _tile(
                          Lucide.Brain,
                          l10n.reasoningBudgetSheetMax,
                          ReasoningBudget.max,
                          capabilities: capabilities,
                          deepthink: true,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
