import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../shared/widgets/markdown_with_highlight.dart';
import '../../../shared/widgets/ios_tactile.dart';

class AiTeamProposalsSection extends StatefulWidget {
  const AiTeamProposalsSection({
    super.key,
    required this.data,
    this.isStreaming = false,
  });

  final String data;
  final bool isStreaming;

  @override
  State<AiTeamProposalsSection> createState() => _AiTeamProposalsSectionState();
}

class _AiTeamProposalsSectionState extends State<AiTeamProposalsSection> {
  bool _expanded = false;

  List<Map<String, dynamic>> _parseProposals() {
    try {
      final decoded = jsonDecode(widget.data);
      if (decoded is List) {
        return decoded.whereType<Map<String, dynamic>>().toList();
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
    final proposals = _parseProposals();
    // Filter out proposals that have empty content, empty reasoning, AND empty toolCalls
    final visibleProposals = proposals.where((p) {
      final c = (p['content'] as String? ?? '').trim();
      final r = (p['reasoning'] as String? ?? '').trim();
      final tc = (p['toolCalls'] as List?) ?? const [];
      return c.isNotEmpty || r.isNotEmpty || tc.isNotEmpty;
    }).toList();

    if (visibleProposals.isEmpty) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context)!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardTextColor =
        isDark ? const Color(0xFF9E9EA4) : const Color(0xFF7E7F83);

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.transparent,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header / Toggle bar
          IosCardPress(
            borderRadius: BorderRadius.circular(10),
            baseColor: Colors.transparent,
            pressedScale: 1.0,
            duration: const Duration(milliseconds: 220),
            onTap: () => setState(() => _expanded = !_expanded),
            padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    Lucide.Users,
                    size: 18,
                    color: cardTextColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.aiTeamFinalAnswerLabel,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.normal,
                      color: cardTextColor,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '(${visibleProposals.length})',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.normal,
                      color: cardTextColor.withValues(alpha: 0.9),
                    ),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0.0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeInOutCubic,
                    child: Icon(
                      Lucide.ChevronRight,
                      size: 18,
                      color: cardTextColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Collapsible body
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: const SizedBox(height: 0),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
              child: Builder(builder: (context) {
                final content = RepaintBoundary(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (int i = 0; i < visibleProposals.length; i++) ...[
                        if (i > 0)
                          Divider(
                            height: 12,
                            thickness: 0.5,
                            color: isDark ? const Color(0x22FFFFFF) : const Color(0x1A000000),
                          ),
                        _buildProposalBlock(context, i, visibleProposals[i]),
                      ],
                    ],
                  ),
                );
                return widget.isStreaming ? content : SelectionArea(child: content);
              }),
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

    final customLabel = proposal['label'] as String?;
    final label = customLabel ?? l10n.aiTeamProposalLabel(index + 1);
    final providerName = _providerName(providerKey);
    final subtitle = providerName.isNotEmpty ? '$providerName · $modelId' : modelId;

    return _CollapsibleProposalBlock(
      label: label,
      subtitle: subtitle,
      content: content,
      reasoning: reasoning,
      toolCalls: toolCalls,
      isStreaming: widget.isStreaming,
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
    this.isStreaming = false,
  });

  final String label;
  final String subtitle;
  final String content;
  final String reasoning;
  final List<Map<String, dynamic>> toolCalls;
  final bool isStreaming;

  @override
  State<_CollapsibleProposalBlock> createState() => _CollapsibleProposalBlockState();
}

class _CollapsibleProposalBlockState extends State<_CollapsibleProposalBlock> {
  bool _thinkingExpanded = false;
  bool _toolsExpanded = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardTextColor =
        isDark ? const Color(0xFF9E9EA4) : const Color(0xFF7E7F83);
    final l10n = AppLocalizations.of(context)!;
    final hasReasoning = widget.reasoning.trim().isNotEmpty;
    final hasToolCalls = widget.toolCalls.isNotEmpty;

    final TextStyle baseStyle = TextStyle(
      fontSize: 12.5,
      height: 1.32,
      color: cardTextColor,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Proposal header
        Text(
          '${widget.label} (${widget.subtitle})',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.normal,
            color: cardTextColor,
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
            cardTextColor: cardTextColor,
            child: MarkdownWithCodeHighlight(
              text: widget.reasoning,
              baseStyle: baseStyle,
              isStreaming: widget.isStreaming,
            ),
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
            cardTextColor: cardTextColor,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final tc in widget.toolCalls) ...[
                  _buildToolCallItem(context, tc, cardTextColor),
                  if (tc != widget.toolCalls.last) const SizedBox(height: 4),
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
        ],

        // Final answer (always visible)
        MarkdownWithCodeHighlight(
          text: widget.content,
          baseStyle: baseStyle,
          isStreaming: widget.isStreaming,
        ),
      ],
    );
  }

  Widget _buildCollapsibleSection(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool expanded,
    required VoidCallback onToggle,
    required Color cardTextColor,
    required Widget child,
  }) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.transparent,
      ),
      margin: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  Icon(icon, size: 14, color: cardTextColor),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.normal,
                      color: cardTextColor,
                    ),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(Lucide.ChevronRight, size: 14, color: cardTextColor),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 4, bottom: 4, top: 2),
              child: child,
            ),
        ],
      ),
    );
  }

  Widget _buildToolCallItem(
    BuildContext context,
    Map<String, dynamic> tc,
    Color cardTextColor,
  ) {
    final name = tc['name'] as String? ?? '';
    final arguments = tc['arguments'];
    final result = tc['result'] as String?;

    final argsStr = arguments is String
        ? arguments
        : (arguments is Map ? jsonEncode(arguments) : arguments.toString());

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: const BoxDecoration(
        color: Colors.transparent,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Lucide.Terminal, size: 14, color: cardTextColor),
              const SizedBox(width: 6),
              Text(
                name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.normal,
                  color: cardTextColor,
                ),
              ),
            ],
          ),
          if (argsStr.trim().isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              argsStr,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: cardTextColor.withValues(alpha: 0.8),
              ),
            ),
          ],
          if (result != null && result.trim().isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              result,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: cardTextColor.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
