import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../core/providers/ai_team_provider.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/models/ai_team_config.dart';
import '../../shared/widgets/ios_switch.dart';
import '../../features/model/widgets/model_select_sheet.dart' show showModelSelector;

class DesktopAiTeamPane extends StatefulWidget {
  const DesktopAiTeamPane({super.key});

  @override
  State<DesktopAiTeamPane> createState() => _DesktopAiTeamPaneState();
}

class _DesktopAiTeamPaneState extends State<DesktopAiTeamPane> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AiTeamProvider>().initialize();
    });
  }

  Future<void> _pickModel(int index) async {
    final sel = await showModelSelector(context);
    if (sel == null || !mounted) return;
    await context.read<AiTeamProvider>().setProposerAt(index, AiTeamModelSlot(providerKey: sel.providerKey, modelId: sel.modelId));
  }

  Future<void> _pickAggregator() async {
    final sel = await showModelSelector(context);
    if (sel == null || !mounted) return;
    await context.read<AiTeamProvider>().setAggregator(AiTeamModelSlot(providerKey: sel.providerKey, modelId: sel.modelId));
  }

  String _providerName(String providerKey) {
    final settings = context.read<SettingsProvider>();
    return settings.getProviderConfig(providerKey).name;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<AiTeamProvider>();

    return Container(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 36,
                  child: Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            l10n.aiTeamTitle,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.8)),
                          ),
                        ),
                      ),
                      _SmallIconBtn(
                        icon: lucide.Lucide.RotateCcw,
                        tooltip: l10n.aiTeamResetPrompts,
                        onTap: () => provider.resetPrompts(),
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 8)),

              // Enable toggle
              SliverToBoxAdapter(
                child: _desktopCard(context, child: Row(
                  children: [
                    Icon(lucide.Lucide.Users, size: 20, color: cs.primary),
                    const SizedBox(width: 12),
                    Expanded(child: Text(l10n.aiTeamEnable, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: cs.onSurface.withOpacity(0.9)))),
                    IosSwitch(
                      value: provider.enabled,
                      onChanged: (v) => provider.setEnabled(v),
                    ),
                  ],
                )),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),

              // Collaboration Mode Selector
              SliverToBoxAdapter(child: _sectionLabel(context, l10n.aiTeamModeLabel)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SegmentedButton<AiTeamMode>(
                    segments: [
                      ButtonSegment(value: AiTeamMode.parallel, label: Text(l10n.aiTeamModeParallel)),
                      ButtonSegment(value: AiTeamMode.chain, label: Text(l10n.aiTeamModeChain)),
                    ],
                    selected: {provider.mode},
                    onSelectionChanged: (s) => provider.setMode(s.first),
                  ),
                ),
              ),

              if (provider.mode == AiTeamMode.parallel) ...[
                // Parallel: Proposer count
                SliverToBoxAdapter(child: _sectionLabel(context, l10n.aiTeamProposerCount)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SegmentedButton<int>(
                      segments: const [ButtonSegment(value: 1, label: Text('1')), ButtonSegment(value: 2, label: Text('2')), ButtonSegment(value: 3, label: Text('3')), ButtonSegment(value: 4, label: Text('4'))],
                      selected: {provider.proposerCount},
                      onSelectionChanged: (s) => provider.setProposerCount(s.first),
                    ),
                  ),
                ),

                // Parallel: Proposer model slots
                SliverToBoxAdapter(child: _sectionLabel(context, l10n.aiTeamProposerModels)),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) {
                      final slot = provider.proposers[i];
                      return _desktopCard(
                        context,
                        onTap: () => _pickModel(i),
                        child: _modelSlotContent(
                          context,
                          slot: slot,
                          fallbackText: l10n.aiTeamEmptyProposerSlot,
                          onClear: slot != null ? () => provider.setProposerAt(i, null) : null,
                        ),
                      );
                    },
                    childCount: provider.proposerCount,
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
              ] else ...[
                // Chain: Critic count
                SliverToBoxAdapter(child: _sectionLabel(context, l10n.aiTeamCriticCount)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SegmentedButton<int>(
                      segments: const [ButtonSegment(value: 0, label: Text('0')), ButtonSegment(value: 1, label: Text('1')), ButtonSegment(value: 2, label: Text('2')), ButtonSegment(value: 3, label: Text('3'))],
                      selected: {provider.criticCount},
                      onSelectionChanged: (s) => provider.setCriticCount(s.first),
                    ),
                  ),
                ),

                // Chain: Model slots (Proposer + Critics)
                SliverToBoxAdapter(child: _sectionLabel(context, l10n.aiTeamProposerModels)),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) {
                      final slot = provider.proposers[i];
                      final fallback = i == 0 ? l10n.aiTeamProposerModels : l10n.aiTeamCriticLabel(i);
                      return _desktopCard(
                        context,
                        onTap: () => _pickModel(i),
                        child: _modelSlotContent(
                          context,
                          slot: slot,
                          fallbackText: fallback,
                          onClear: slot != null ? () => provider.setProposerAt(i, null) : null,
                        ),
                      );
                    },
                    childCount: provider.criticCount + 1,
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
              ],

              // Aggregator model (Always visible)
              SliverToBoxAdapter(child: _sectionLabel(context, l10n.aiTeamAggregatorModel)),
              SliverToBoxAdapter(
                child: _desktopCard(
                  context,
                  onTap: _pickAggregator,
                  child: _modelSlotContent(
                    context,
                    slot: provider.aggregator,
                    fallbackText: l10n.aiTeamAggregatorUseCurrent,
                    onClear: provider.aggregator != null ? () => provider.setAggregator(null) : null,
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),

              if (provider.mode == AiTeamMode.parallel) ...[
                // Proposal prompt
                SliverToBoxAdapter(child: _sectionLabel(context, l10n.aiTeamProposalPromptLabel)),
                SliverToBoxAdapter(
                  child: _desktopCard(
                    context,
                    onTap: () => _editPromptDialog(
                      context,
                      title: l10n.aiTeamProposalPromptLabel,
                      initial: provider.useDefaultProposalPrompt
                          ? l10n.aiTeamDefaultProposalPrompt
                          : provider.proposalPrompt,
                      onSave: (s) => provider.setProposalPrompt(s),
                      onRestoreDefault: () => provider.update((c) => c.copyWith(useDefaultProposalPrompt: true)),
                    ),
                    child: _promptPreview(
                      context,
                      provider.useDefaultProposalPrompt
                          ? l10n.aiTeamDefaultProposalPrompt
                          : provider.proposalPrompt,
                      l10n.aiTeamProposalPromptLabel,
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),

                // Aggregator prompt
                SliverToBoxAdapter(child: _sectionLabel(context, l10n.aiTeamAggregatorPromptLabel)),
                SliverToBoxAdapter(
                  child: _desktopCard(
                    context,
                    onTap: () => _editPromptDialog(
                      context,
                      title: l10n.aiTeamAggregatorPromptLabel,
                      initial: provider.useDefaultAggregatorPrompt
                          ? l10n.aiTeamDefaultAggregatorPrompt
                          : provider.aggregatorPrompt,
                      onSave: (s) => provider.setAggregatorPrompt(s),
                      onRestoreDefault: () => provider.update((c) => c.copyWith(useDefaultAggregatorPrompt: true)),
                    ),
                    child: _promptPreview(
                      context,
                      provider.useDefaultAggregatorPrompt
                          ? l10n.aiTeamDefaultAggregatorPrompt
                          : provider.aggregatorPrompt,
                      l10n.aiTeamAggregatorPromptLabel,
                    ),
                  ),
                ),
              ] else ...[
                // Chain Proposer Prompt
                SliverToBoxAdapter(child: _sectionLabel(context, l10n.aiTeamProposerPromptLabelShort)),
                SliverToBoxAdapter(
                  child: _desktopCard(
                    context,
                    onTap: () => _editPromptDialog(
                      context,
                      title: l10n.aiTeamProposerPromptLabelShort,
                      initial: provider.useDefaultChainProposerPrompt
                          ? AiTeamConfigDefaults.defaultChainProposerPrompt
                          : provider.chainProposerPrompt,
                      onSave: (s) => provider.setChainProposerPrompt(s),
                      onRestoreDefault: () => provider.update((c) => c.copyWith(useDefaultChainProposerPrompt: true)),
                    ),
                    child: _promptPreview(
                      context,
                      provider.useDefaultChainProposerPrompt
                          ? AiTeamConfigDefaults.defaultChainProposerPrompt
                          : provider.chainProposerPrompt,
                      l10n.aiTeamProposerPromptLabelShort,
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),

                // Chain Critic Prompt (if criticCount > 0)
                if (provider.criticCount > 0) ...[
                  SliverToBoxAdapter(child: _sectionLabel(context, l10n.aiTeamCriticPromptLabel)),
                  SliverToBoxAdapter(
                    child: _desktopCard(
                      context,
                      onTap: () => _editPromptDialog(
                        context,
                        title: l10n.aiTeamCriticPromptLabel,
                        initial: provider.useDefaultChainCriticPrompt
                            ? AiTeamConfigDefaults.defaultChainCriticPrompt
                            : provider.chainCriticPrompt,
                        onSave: (s) => provider.setChainCriticPrompt(s),
                        onRestoreDefault: () => provider.update((c) => c.copyWith(useDefaultChainCriticPrompt: true)),
                      ),
                      child: _promptPreview(
                        context,
                        provider.useDefaultChainCriticPrompt
                            ? AiTeamConfigDefaults.defaultChainCriticPrompt
                            : provider.chainCriticPrompt,
                        l10n.aiTeamCriticPromptLabel,
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                ],

                // Chain Aggregator Prompt
                SliverToBoxAdapter(child: _sectionLabel(context, l10n.aiTeamAggregatorPromptLabelShort)),
                SliverToBoxAdapter(
                  child: _desktopCard(
                    context,
                    onTap: () => _editPromptDialog(
                      context,
                      title: l10n.aiTeamAggregatorPromptLabelShort,
                      initial: provider.useDefaultChainAggregatorPrompt
                          ? AiTeamConfigDefaults.defaultChainAggregatorPrompt
                          : provider.chainAggregatorPrompt,
                      onSave: (s) => provider.setChainAggregatorPrompt(s),
                      onRestoreDefault: () => provider.update((c) => c.copyWith(useDefaultChainAggregatorPrompt: true)),
                    ),
                    child: _promptPreview(
                      context,
                      provider.useDefaultChainAggregatorPrompt
                          ? AiTeamConfigDefaults.defaultChainAggregatorPrompt
                          : provider.chainAggregatorPrompt,
                      l10n.aiTeamAggregatorPromptLabelShort,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _modelSlotContent(
    BuildContext context, {
    required AiTeamModelSlot? slot,
    required String fallbackText,
    VoidCallback? onClear,
  }) {
    final cs = Theme.of(context).colorScheme;
    final hasModel = slot != null;
    final providerName = hasModel ? _providerName(slot!.providerKey) : fallbackText;
    final modelName = hasModel ? slot.modelId : '';

    return Row(
      children: [
        Icon(hasModel ? lucide.Lucide.Boxes : lucide.Lucide.Plus, size: 20, color: cs.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(providerName, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: cs.onSurface.withOpacity(0.9)), maxLines: 1, overflow: TextOverflow.ellipsis),
              if (hasModel) ...[
                const SizedBox(height: 2),
                Text(modelName, style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.5)), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
        if (onClear != null)
          _SmallIconBtn(icon: lucide.Lucide.X, onTap: onClear),
        if (onClear == null)
          Icon(lucide.Lucide.ChevronRight, size: 16, color: cs.onSurface.withOpacity(0.4)),
      ],
    );
  }

  Widget _promptPreview(BuildContext context, String prompt, String label) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(lucide.Lucide.FileText, size: 20, color: cs.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(prompt, style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.5)), maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        Icon(lucide.Lucide.ChevronRight, size: 16, color: cs.onSurface.withOpacity(0.4)),
      ],
    );
  }

  Future<void> _editPromptDialog(
    BuildContext context, {
    required String title,
    required String initial,
    required Future<void> Function(String) onSave,
    Future<void> Function()? onRestoreDefault,
  }) async {
    final controller = TextEditingController(text: initial);
    final l = AppLocalizations.of(context)!;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: controller,
            maxLines: 12,
            minLines: 6,
            decoration: InputDecoration(
              filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel)),
          if (onRestoreDefault != null)
            TextButton(
              onPressed: () async {
                await onRestoreDefault();
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: Text(l.aiTeamRestoreDefaultPrompt),
            ),
          FilledButton(
            onPressed: () async {
              await onSave(controller.text);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: Text(MaterialLocalizations.of(ctx).saveButtonLabel),
          ),
        ],
      ),
    );
  }
}

Widget _sectionLabel(BuildContext context, String text) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
    child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.8))),
  );
}

Widget _desktopCard(BuildContext context, {required Widget child, VoidCallback? onTap}) {
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final Color bg = isDark ? Colors.white10 : Colors.white.withOpacity(0.96);
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: MouseRegion(
      cursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: cs.outlineVariant.withOpacity(isDark ? 0.08 : 0.06), width: 0.6),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: child,
        ),
      ),
    ),
  );
}

class _SmallIconBtn extends StatefulWidget {
  const _SmallIconBtn({required this.icon, required this.onTap, this.tooltip, this.size = 18});
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final double size;

  @override
  State<_SmallIconBtn> createState() => _SmallIconBtnState();
}

class _SmallIconBtnState extends State<_SmallIconBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final child = GestureDetector(
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(widget.icon, size: widget.size, color: _hover ? cs.primary : cs.onSurface.withOpacity(0.5)),
      ),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: widget.tooltip != null ? Tooltip(message: widget.tooltip!, child: child) : child,
    );
  }
}
