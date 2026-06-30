import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../shared/widgets/markdown_with_highlight.dart';

class AiTeamProposalsSection extends StatefulWidget {
  const AiTeamProposalsSection({
    super.key,
    required this.data,
  });

  final String data;

  @override
  State<AiTeamProposalsSection> createState() => _AiTeamProposalsSectionState();
}

class _AiTeamProposalsSectionState extends State<AiTeamProposalsSection> {
  bool _expanded = false;

  List<Map<String, dynamic>> _parseProposals() {
    try {
      final decoded = jsonDecode(widget.data);
      if (decoded is List) {
        return decoded.whereType<Map<String, dynamic>>().toList(growable: false);
      }
    } catch (_) {}
    return const [];
  }

  String _providerName(String? providerKey) {
    if (providerKey == null || providerKey.isEmpty) return '';
    try {
      final settings = context.read<SettingsProvider>();
      return settings.getProviderConfig(providerKey).name;
    } catch (_) {
      return providerKey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;
    final proposals = _parseProposals();
    if (proposals.isEmpty) return const SizedBox.shrink();

    // Filter out proposals with completely empty content
    final visibleProposals = proposals
        .where((p) => (p['content'] as String? ?? '').trim().isNotEmpty)
        .toList();
    if (visibleProposals.isEmpty) return const SizedBox.shrink();

    final bg = cs.primaryContainer.withOpacity(isDark ? 0.25 : 0.30);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              children: [
                Icon(Lucide.Users, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Text(
                  l10n.aiTeamFinalAnswerLabel,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withOpacity(0.8),
                  ),
                ),
                const Spacer(),
                AnimatedRotation(
                  turns: _expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Lucide.ChevronRight, size: 16, color: cs.onSurface.withOpacity(0.5)),
                ),
              ],
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: const SizedBox(height: 0),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 8, left: 2, right: 2, bottom: 2),
              child: SelectionArea(
                child: RepaintBoundary(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (int i = 0; i < visibleProposals.length; i++) ...[
                        if (i > 0) const SizedBox(height: 8),
                        _buildProposalBlock(context, i, visibleProposals[i]),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProposalBlock(BuildContext context, int index, Map<String, dynamic> proposal) {
    final l10n = AppLocalizations.of(context)!;
    final providerKey = proposal['providerKey'] as String?;
    final modelId = proposal['modelId'] as String? ?? '';
    final content = proposal['content'] as String? ?? '';
    final reasoning = proposal['reasoning'] as String? ?? '';
    final toolCalls = (proposal['toolCalls'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [];

    final label = l10n.aiTeamProposalLabel(index + 1);
    final providerName = _providerName(providerKey);
    final subtitle = providerName.isNotEmpty ? '$providerName · $modelId' : modelId;

    return _CollapsibleProposalBlock(
      label: label,
      subtitle: subtitle,
      content: content,
      reasoning: reasoning,
      toolCalls: toolCalls,
    );
  }
}

/// A single proposal block with layered collapse: header → (collapsed) thinking → (collapsed) tools → answer
class _CollapsibleProposalBlock extends StatefulWidget {
  const _CollapsibleProposalBlock({
    required this.label,
    required this.subtitle,
    required this.content,
    required this.reasoning,
    required this.toolCalls,
  });

  final String label;
  final String subtitle;
  final String content;
  final String reasoning;
  final List<Map<String, dynamic>> toolCalls;

  @override
  State<_CollapsibleProposalBlock> createState() => _CollapsibleProposalBlockState();
}

class _CollapsibleProposalBlockState extends State<_CollapsibleProposalBlock> {
  bool _thinkingExpanded = false;
  bool _toolsExpanded = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final hasReasoning = widget.reasoning.trim().isNotEmpty;
    final hasToolCalls = widget.toolCalls.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Proposal header
        Text(
          '${widget.label} (${widget.subtitle})',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: cs.onSurface.withOpacity(0.6),
          ),
        ),
        const SizedBox(height: 4),

        // Thinking section (collapsible, default collapsed)
        if (hasReasoning) ...[
          _buildCollapsibleSection(
            context,
            icon: Lucide.Brain,
            label: l10n.aiTeamThinkingLabel,
            expanded: _thinkingExpanded,
            onToggle: () => setState(() => _thinkingExpanded = !_thinkingExpanded),
            child: MarkdownWithCodeHighlight(text: widget.reasoning),
          ),
          const SizedBox(height: 4),
        ],

        // Tool calls section (collapsible, default collapsed)
        if (hasToolCalls) ...[
          _buildCollapsibleSection(
            context,
            icon: Lucide.Wrench,
            label: l10n.aiTeamToolCallsLabel,
            expanded: _toolsExpanded,
            onToggle: () => setState(() => _toolsExpanded = !_toolsExpanded),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final tc in widget.toolCalls) ...[
                  _buildToolCallItem(context, tc),
                  if (tc != widget.toolCalls.last) const SizedBox(height: 6),
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
        ],

        // Final answer (always visible)
        MarkdownWithCodeHighlight(text: widget.content),
      ],
    );
  }

  Widget _buildCollapsibleSection(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool expanded,
    required VoidCallback onToggle,
    required Widget child,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: cs.surface.withOpacity(isDark ? 0.5 : 0.7),
        borderRadius: BorderRadius.circular(10),
      ),
      margin: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: Row(
                children: [
                  Icon(icon, size: 13, color: cs.onSurface.withOpacity(0.5)),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface.withOpacity(0.5),
                    ),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(Lucide.ChevronRight, size: 14, color: cs.onSurface.withOpacity(0.4)),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8, top: 2),
              child: child,
            ),
        ],
      ),
    );
  }

  Widget _buildToolCallItem(BuildContext context, Map<String, dynamic> tc) {
    final cs = Theme.of(context).colorScheme;
    final name = tc['name'] as String? ?? '';
    final arguments = tc['arguments'];
    final result = tc['result'] as String?;

    final argsStr = arguments is String
        ? arguments
        : (arguments is Map ? jsonEncode(arguments) : arguments.toString());

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: cs.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Lucide.Terminal, size: 12, color: cs.primary),
              const SizedBox(width: 4),
              Text(
                name,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: cs.primary,
                ),
              ),
            ],
          ),
          if (argsStr.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              argsStr,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
                color: cs.onSurface.withOpacity(0.6),
              ),
            ),
          ],
          if (result != null && result.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                result,
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: 'monospace',
                  color: cs.onSurface.withOpacity(0.5),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
