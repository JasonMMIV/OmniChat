import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/providers/ai_team_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/models/ai_team_config.dart';
import '../../../core/services/haptics.dart';
import '../../model/widgets/model_select_sheet.dart';

class AiTeamPage extends StatefulWidget {
  const AiTeamPage({super.key});

  @override
  State<AiTeamPage> createState() => _AiTeamPageState();
}

class _AiTeamPageState extends State<AiTeamPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AiTeamProvider>().initialize();
    });
  }

  Future<void> _pickModel(int index) async {
    Haptics.light();
    final sel = await showModelSelector(context);
    if (sel == null || !mounted) return;
    await context.read<AiTeamProvider>().setProposerAt(index, AiTeamModelSlot(providerKey: sel.providerKey, modelId: sel.modelId));
  }

  Future<void> _pickAggregator() async {
    Haptics.light();
    final sel = await showModelSelector(context);
    if (sel == null || !mounted) return;
    await context.read<AiTeamProvider>().setAggregator(AiTeamModelSlot(providerKey: sel.providerKey, modelId: sel.modelId));
  }

  Future<void> _editProposalPrompt() async {
    final provider = context.read<AiTeamProvider>();
    final l = l10n;
    final initial = provider.useDefaultProposalPrompt
        ? l.aiTeamDefaultProposalPrompt
        : provider.proposalPrompt;
    final result = await _showPromptEditor(
      title: l.aiTeamProposalPromptLabel,
      initial: initial,
      onRestoreDefault: () => provider.update((c) => c.copyWith(useDefaultProposalPrompt: true)),
    );
    if (result != null && mounted) {
      await provider.setProposalPrompt(result);
    }
  }

  Future<void> _editAggregatorPrompt() async {
    final provider = context.read<AiTeamProvider>();
    final l = l10n;
    final initial = provider.useDefaultAggregatorPrompt
        ? l.aiTeamDefaultAggregatorPrompt
        : provider.aggregatorPrompt;
    final result = await _showPromptEditor(
      title: l.aiTeamAggregatorPromptLabel,
      initial: initial,
      onRestoreDefault: () => provider.update((c) => c.copyWith(useDefaultAggregatorPrompt: true)),
    );
    if (result != null && mounted) {
      await provider.setAggregatorPrompt(result);
    }
  }

  Future<void> _editChainProposerPrompt() async {
    final provider = context.read<AiTeamProvider>();
    final l = l10n;
    final initial = provider.useDefaultChainProposerPrompt
        ? AiTeamConfigDefaults.defaultChainProposerPrompt
        : provider.chainProposerPrompt;
    final result = await _showPromptEditor(
      title: l.aiTeamProposerPromptLabelShort,
      initial: initial,
      onRestoreDefault: () => provider.update((c) => c.copyWith(useDefaultChainProposerPrompt: true)),
    );
    if (result != null && mounted) {
      await provider.setChainProposerPrompt(result);
    }
  }

  Future<void> _editChainCriticPrompt() async {
    final provider = context.read<AiTeamProvider>();
    final l = l10n;
    final initial = provider.useDefaultChainCriticPrompt
        ? AiTeamConfigDefaults.defaultChainCriticPrompt
        : provider.chainCriticPrompt;
    final result = await _showPromptEditor(
      title: l.aiTeamCriticPromptLabel,
      initial: initial,
      onRestoreDefault: () => provider.update((c) => c.copyWith(useDefaultChainCriticPrompt: true)),
    );
    if (result != null && mounted) {
      await provider.setChainCriticPrompt(result);
    }
  }

  Future<void> _editChainAggregatorPrompt() async {
    final provider = context.read<AiTeamProvider>();
    final l = l10n;
    final initial = provider.useDefaultChainAggregatorPrompt
        ? AiTeamConfigDefaults.defaultChainAggregatorPrompt
        : provider.chainAggregatorPrompt;
    final result = await _showPromptEditor(
      title: l.aiTeamAggregatorPromptLabelShort,
      initial: initial,
      onRestoreDefault: () => provider.update((c) => c.copyWith(useDefaultChainAggregatorPrompt: true)),
    );
    if (result != null && mounted) {
      await provider.setChainAggregatorPrompt(result);
    }
  }

  AppLocalizations get l10n => AppLocalizations.of(context)!;

  Future<String?> _showPromptEditor({
    required String title,
    required String initial,
    VoidCallback? onRestoreDefault,
  }) async {
    final controller = TextEditingController(text: initial);
    final l = AppLocalizations.of(context)!;
    return await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.onSurface.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 12),
                Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: controller,
                    maxLines: 10,
                    minLines: 4,
                    decoration: InputDecoration(
                      filled: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
                        ),
                      ),
                      if (onRestoreDefault != null) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextButton(
                            onPressed: () {
                              onRestoreDefault();
                              Navigator.of(ctx).pop();
                            },
                            child: Text(l.aiTeamRestoreDefaultPrompt),
                          ),
                        ),
                      ],
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.of(ctx).pop(controller.text),
                          child: Text(MaterialLocalizations.of(ctx).saveButtonLabel),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  String _providerName(String providerKey) {
    final settings = context.read<SettingsProvider>();
    return settings.getProviderConfig(providerKey).name;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = this.l10n;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.watch<AiTeamProvider>();

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: _TactileIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.aiTeamTitle),
        actions: [
          Tooltip(
            message: l10n.aiTeamResetPrompts,
            child: _TactileIconButton(
              icon: Lucide.RotateCcw,
              color: cs.onSurface,
              size: 20,
              onTap: () async {
                Haptics.light();
                await provider.resetPrompts();
              },
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // Enable toggle
          _iosSectionCard(context, children: [
            SwitchListTile(
              value: provider.enabled,
              onChanged: (v) => provider.setEnabled(v),
              title: Text(l10n.aiTeamEnable, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: cs.onSurface.withOpacity(0.9))),
              secondary: Icon(Lucide.Users, size: 20, color: cs.primary),
            ),
          ]),
          const SizedBox(height: 12),

          // Collaboration Mode Selector
          _sectionTitle(context, l10n.aiTeamModeLabel),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: SegmentedButton<AiTeamMode>(
              segments: [
                ButtonSegment(value: AiTeamMode.parallel, label: Text(l10n.aiTeamModeParallel)),
                ButtonSegment(value: AiTeamMode.chain, label: Text(l10n.aiTeamModeChain)),
              ],
              selected: {provider.mode},
              onSelectionChanged: (s) => provider.setMode(s.first),
            ),
          ),
          const SizedBox(height: 12),

          if (provider.mode == AiTeamMode.parallel) ...[
            // Parallel: Proposer count
            _sectionTitle(context, l10n.aiTeamProposerCount),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: SegmentedButton<int>(
                segments: const [ButtonSegment(value: 1, label: Text('1')), ButtonSegment(value: 2, label: Text('2')), ButtonSegment(value: 3, label: Text('3')), ButtonSegment(value: 4, label: Text('4'))],
                selected: {provider.proposerCount},
                onSelectionChanged: (s) => provider.setProposerCount(s.first),
              ),
            ),
            const SizedBox(height: 12),

            // Parallel: Proposer model slots
            _sectionTitle(context, l10n.aiTeamProposerModels),
            _iosSectionCard(context, children: [
              for (int i = 0; i < provider.proposerCount; i++) ...[
                if (i > 0) _iosDivider(context),
                _modelSlotRow(
                  context,
                  slot: provider.proposers[i],
                  onTap: () => _pickModel(i),
                  onClear: provider.proposers[i] != null
                      ? () => provider.setProposerAt(i, null)
                      : null,
                ),
              ],
            ]),
            const SizedBox(height: 12),
          ] else ...[
            // Chain: Critic count
            _sectionTitle(context, l10n.aiTeamCriticCount),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: SegmentedButton<int>(
                segments: const [ButtonSegment(value: 0, label: Text('0')), ButtonSegment(value: 1, label: Text('1')), ButtonSegment(value: 2, label: Text('2')), ButtonSegment(value: 3, label: Text('3'))],
                selected: {provider.criticCount},
                onSelectionChanged: (s) => provider.setCriticCount(s.first),
              ),
            ),
            const SizedBox(height: 12),

            // Chain: Model slots (Proposer + Critics)
            _sectionTitle(context, l10n.aiTeamProposerModels),
            _iosSectionCard(context, children: [
              _modelSlotRow(
                context,
                slot: provider.proposers[0],
                onTap: () => _pickModel(0),
                fallbackText: l10n.aiTeamProposerModels,
                onClear: provider.proposers[0] != null
                    ? () => provider.setProposerAt(0, null)
                    : null,
              ),
              for (int i = 1; i <= provider.criticCount; i++) ...[
                _iosDivider(context),
                _modelSlotRow(
                  context,
                  slot: provider.proposers[i],
                  onTap: () => _pickModel(i),
                  fallbackText: l10n.aiTeamCriticLabel(i),
                  onClear: provider.proposers[i] != null
                      ? () => provider.setProposerAt(i, null)
                      : null,
                ),
              ],
            ]),
            const SizedBox(height: 12),
          ],

          // Aggregator model (Always visible)
          _sectionTitle(context, l10n.aiTeamAggregatorModel),
          _iosSectionCard(context, children: [
            _modelSlotRow(
              context,
              slot: provider.aggregator,
              onTap: _pickAggregator,
              fallbackText: l10n.aiTeamAggregatorUseCurrent,
              onClear: provider.aggregator != null
                  ? () => provider.setAggregator(null)
                  : null,
            ),
          ]),
          const SizedBox(height: 12),

          if (provider.mode == AiTeamMode.parallel) ...[
            // Proposal prompt
            _sectionTitle(context, l10n.aiTeamProposalPromptLabel),
            _iosSectionCard(context, children: [
              _pressableRow(
                context,
                icon: Lucide.FileText,
                title: l10n.aiTeamProposalPromptLabel,
                subtitle: provider.useDefaultProposalPrompt
                    ? l10n.aiTeamDefaultProposalPrompt
                    : provider.proposalPrompt,
                maxLines: 2,
                onTap: _editProposalPrompt,
              ),
            ]),
            const SizedBox(height: 12),

            // Aggregator prompt
            _sectionTitle(context, l10n.aiTeamAggregatorPromptLabel),
            _iosSectionCard(context, children: [
              _pressableRow(
                context,
                icon: Lucide.FileText,
                title: l10n.aiTeamAggregatorPromptLabel,
                subtitle: provider.useDefaultAggregatorPrompt
                    ? l10n.aiTeamDefaultAggregatorPrompt
                    : provider.aggregatorPrompt,
                maxLines: 2,
                onTap: _editAggregatorPrompt,
              ),
            ]),
          ] else ...[
            // Chain Proposer Prompt
            _sectionTitle(context, l10n.aiTeamProposerPromptLabelShort),
            _iosSectionCard(context, children: [
              _pressableRow(
                context,
                icon: Lucide.FileText,
                title: l10n.aiTeamProposerPromptLabelShort,
                subtitle: provider.useDefaultChainProposerPrompt
                    ? AiTeamConfigDefaults.defaultChainProposerPrompt
                    : provider.chainProposerPrompt,
                maxLines: 2,
                onTap: _editChainProposerPrompt,
              ),
            ]),
            const SizedBox(height: 12),

            // Chain Critic Prompt (if criticCount > 0)
            if (provider.criticCount > 0) ...[
              _sectionTitle(context, l10n.aiTeamCriticPromptLabel),
              _iosSectionCard(context, children: [
                _pressableRow(
                  context,
                  icon: Lucide.FileText,
                  title: l10n.aiTeamCriticPromptLabel,
                  subtitle: provider.useDefaultChainCriticPrompt
                      ? AiTeamConfigDefaults.defaultChainCriticPrompt
                      : provider.chainCriticPrompt,
                  maxLines: 2,
                  onTap: _editChainCriticPrompt,
                ),
              ]),
              const SizedBox(height: 12),
            ],

            // Chain Aggregator Prompt
            _sectionTitle(context, l10n.aiTeamAggregatorPromptLabelShort),
            _iosSectionCard(context, children: [
              _pressableRow(
                context,
                icon: Lucide.FileText,
                title: l10n.aiTeamAggregatorPromptLabelShort,
                subtitle: provider.useDefaultChainAggregatorPrompt
                    ? AiTeamConfigDefaults.defaultChainAggregatorPrompt
                    : provider.chainAggregatorPrompt,
                maxLines: 2,
                onTap: _editChainAggregatorPrompt,
              ),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _modelSlotRow(
    BuildContext context, {
    required AiTeamModelSlot? slot,
    required VoidCallback onTap,
    String? fallbackText,
    VoidCallback? onClear,
  }) {
    final cs = Theme.of(context).colorScheme;
    final hasModel = slot != null;
    final providerName = hasModel ? _providerName(slot!.providerKey) : '';
    final modelName = hasModel ? slot.modelId : (fallbackText ?? '');

    return _pressableRow(
      context,
      icon: hasModel ? Lucide.Boxes : Lucide.Plus,
      title: hasModel ? providerName : (fallbackText ?? l10n.aiTeamEmptyProposerSlot),
      subtitle: hasModel ? modelName : null,
      onTap: onTap,
      trailing: onClear != null
          ? GestureDetector(
              onTap: () { Haptics.light(); onClear(); },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Icon(Lucide.X, size: 18, color: cs.onSurface.withOpacity(0.5)),
              ),
            )
          : null,
    );
  }
}

Widget _sectionTitle(BuildContext context, String text) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
    child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.8))),
  );
}

Widget _iosSectionCard(BuildContext context, {required List<Widget> children}) {
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final Color bg = isDark ? Colors.white10 : Colors.white.withOpacity(0.96);
  return Container(
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: cs.outlineVariant.withOpacity(isDark ? 0.08 : 0.06), width: 0.6),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(children: children),
    ),
  );
}

Widget _iosDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Divider(height: 6, thickness: 0.6, indent: 54, endIndent: 12, color: cs.outlineVariant.withOpacity(0.18));
}

Widget _pressableRow(
  BuildContext context, {
  required IconData icon,
  required String title,
  String? subtitle,
  int maxLines = 1,
  VoidCallback? onTap,
  Widget? trailing,
}) {
  final cs = Theme.of(context).colorScheme;
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap == null
        ? null
        : () {
            Haptics.light();
            onTap();
          },
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Row(
        children: [
          SizedBox(width: 36, child: Icon(icon, size: 20, color: cs.primary)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 15, color: cs.onSurface.withOpacity(0.9), fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.5)), maxLines: maxLines, overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing,
          if (trailing == null && onTap != null) Icon(Lucide.ChevronRight, size: 16, color: cs.onSurface.withOpacity(0.4)),
        ],
      ),
    ),
  );
}

class _TactileIconButton extends StatefulWidget {
  const _TactileIconButton({required this.icon, required this.color, required this.onTap, this.size = 22});
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;

  @override
  State<_TactileIconButton> createState() => _TactileIconButtonState();
}

class _TactileIconButtonState extends State<_TactileIconButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.color;
    final pressColor = base.withOpacity(0.7);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () { Haptics.light(); widget.onTap(); },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Icon(widget.icon, size: widget.size, color: _pressed ? pressColor : base),
      ),
    );
  }
}
