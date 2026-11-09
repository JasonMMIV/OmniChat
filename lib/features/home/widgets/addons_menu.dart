import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/answer_review.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/ask_user_models.dart';
import '../../../core/services/chat/todo_models.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../mcp/pages/mcp_page.dart';

/// Mobile entry: the Add-ons bottom sheet behind the composer button
/// (desktop uses `showAddonsPopover` instead — no bottom sheets there).
///
/// The menu gathers everything the model can use in one place: MCP servers,
/// the built-in write_todos / ask_user tools and the Self-Review mode
/// (2026-11-10 Add-ons reorganization).
Future<void> showAddonsSheet(
  BuildContext context, {
  required String? assistantId,
  required VoidCallback? onOpenCurrentPlan,
}) async {
  final cs = Theme.of(context).colorScheme;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _AddonsSheetBody(
      assistantId: assistantId,
      onOpenCurrentPlan: onOpenCurrentPlan,
    ),
  );
}

class _AddonsSheetBody extends StatelessWidget {
  const _AddonsSheetBody({
    required this.assistantId,
    required this.onOpenCurrentPlan,
  });

  final String? assistantId;
  final VoidCallback? onOpenCurrentPlan;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final maxHeight = MediaQuery.of(context).size.height * 0.8;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withOpacity(0.2),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              l10n.chatInputBarAddonsTooltip,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: AddonsMenuContent(
                  assistantId: assistantId,
                  onOpenCurrentPlan: onOpenCurrentPlan,
                  onRequestClose: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared Add-ons menu body: three collapsible groups (MCP servers / built-in
/// tools / advanced features) in the kelivo chat-tools-sheet style. Hosted by
/// the mobile bottom sheet and the desktop popover alike.
class AddonsMenuContent extends StatefulWidget {
  const AddonsMenuContent({
    super.key,
    required this.assistantId,
    required this.onOpenCurrentPlan,
    this.onRequestClose,
  });

  /// Assistant whose MCP selection the switches edit. Null (or a stale id)
  /// degrades the MCP group to hints instead of crashing.
  final String? assistantId;

  /// Opens the current-plan sheet; null when there is no active conversation,
  /// which disables the "Current plan" row.
  final VoidCallback? onOpenCurrentPlan;

  /// Closes the hosting sheet/popover before the menu navigates elsewhere
  /// (plan sheet, MCP management page).
  final Future<void> Function()? onRequestClose;

  @override
  State<AddonsMenuContent> createState() => _AddonsMenuContentState();
}

class _AddonsMenuContentState extends State<AddonsMenuContent> {
  bool _mcpExpanded = true;
  bool _builtInExpanded = true;
  bool _advancedExpanded = true;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    final mcp = context.watch<McpProvider>();
    final ap = context.watch<AssistantProvider>();
    final assistant =
        widget.assistantId == null ? null : ap.getById(widget.assistantId!);

    final connected = mcp.servers
        .where((s) => mcp.statusFor(s.id) == McpStatus.connected)
        .toList();
    final selectedIds = assistant?.mcpServerIds.toSet() ?? const <String>{};
    final selectedCount =
        connected.where((s) => selectedIds.contains(s.id)).length;

    final writeTodosOn =
        settings.planningEnabled && settings.isWorkspaceToolEnabled(todoToolName);
    final askUserOn = settings.isWorkspaceToolEnabled(askUserToolName);
    final reviewMode = settings.answerReviewMode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _group(
          title: l10n.addonsMcpServersTitle,
          expanded: _mcpExpanded,
          onToggle: (v) => setState(() => _mcpExpanded = v),
          summary: connected.isEmpty
              ? l10n.assistantEditMcpNoServersMessage
              : '$selectedCount/${connected.length}',
          children: [
            if (assistant == null) ...[
              if (connected.isEmpty)
                _hintRow(l10n.assistantEditMcpNoServersMessage),
            ] else if (connected.isEmpty)
              _hintRow(l10n.assistantEditMcpNoServersMessage)
            else ...[
              for (final s in connected)
                _MenuRow(
                  leading: Icon(
                    Lucide.Hammer,
                    size: 18,
                    color: selectedIds.contains(s.id)
                        ? cs.primary
                        : cs.onSurface,
                  ),
                  title: s.name,
                  detail:
                      '${s.tools.where((t) => t.enabled).length}/${s.tools.length}',
                  onTap: () =>
                      _toggleServer(s.id, !selectedIds.contains(s.id)),
                  trailing: IosSwitch(
                    value: selectedIds.contains(s.id),
                    onChanged: (v) => _toggleServer(s.id, v),
                  ),
                ),
              _MenuRow(
                leading: Icon(Lucide.Check, size: 18, color: cs.onSurface),
                title: l10n.addonsMcpSelectAll,
                onTap: () => _setAllServers(true),
              ),
              _MenuRow(
                leading: Icon(Lucide.CircleX, size: 18, color: cs.onSurface),
                title: l10n.addonsMcpClearAll,
                onTap: () => _setAllServers(false),
              ),
            ],
            _MenuRow(
              leading: Icon(Lucide.Settings2, size: 18, color: cs.onSurface),
              title: l10n.addonsManageServers,
              trailing: Icon(
                Lucide.ChevronRight,
                size: 16,
                color: cs.onSurface.withOpacity(0.55),
              ),
              onTap: _openManageServers,
            ),
          ],
        ),
        const SizedBox(height: 14),
        _group(
          title: l10n.addonsBuiltInToolsTitle,
          expanded: _builtInExpanded,
          onToggle: (v) => setState(() => _builtInExpanded = v),
          summary: '${(writeTodosOn ? 1 : 0) + (askUserOn ? 1 : 0)}/2',
          children: [
            _MenuRow(
              leading: Icon(Lucide.ListChecks, size: 18, color: cs.onSurface),
              title: l10n.builtInToolWriteTodosName,
              subtitle: l10n.addonsWriteTodosSubtitle,
              onTap: () => _setWriteTodos(!writeTodosOn),
              trailing: IosSwitch(
                value: writeTodosOn,
                onChanged: _setWriteTodos,
              ),
            ),
            _MenuRow(
              leading: Icon(Lucide.MessageCircle, size: 18, color: cs.onSurface),
              title: l10n.builtInToolAskUserName,
              subtitle: l10n.addonsAskUserSubtitle,
              onTap: () => _setAskUser(!askUserOn),
              trailing: IosSwitch(
                value: askUserOn,
                onChanged: _setAskUser,
              ),
            ),
            _MenuRow(
              leading: Icon(Lucide.NotebookTabs, size: 18, color: cs.onSurface),
              title: l10n.todoPlanTitle,
              enabled: widget.onOpenCurrentPlan != null,
              trailing: Icon(
                Lucide.ChevronRight,
                size: 16,
                color: cs.onSurface.withOpacity(0.55),
              ),
              onTap: () async {
                await widget.onRequestClose?.call();
                widget.onOpenCurrentPlan?.call();
              },
            ),
          ],
        ),
        const SizedBox(height: 14),
        _group(
          title: l10n.addonsAdvancedFeaturesTitle,
          expanded: _advancedExpanded,
          onToggle: (v) => setState(() => _advancedExpanded = v),
          summary: _selfReviewModeLabel(l10n, reviewMode),
          children: [
            _MenuRow(
              leading: Icon(
                Lucide.ScanSearch,
                size: 18,
                color: reviewMode == AnswerReviewMode.off
                    ? cs.onSurface
                    : cs.primary,
              ),
              title: l10n.displaySettingsPageAnswerReviewTitle,
              subtitle: l10n.displaySettingsPageAnswerReviewDescription,
              detail: _selfReviewModeLabel(l10n, reviewMode),
              detailHighlight: reviewMode != AnswerReviewMode.off,
              trailing: Icon(
                Lucide.ChevronRight,
                size: 16,
                color: cs.onSurface.withOpacity(0.55),
              ),
              onTap: () => _showSelfReviewModePicker(context),
            ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Collapsible group (kelivo chat-tools-sheet header anatomy)
  // ---------------------------------------------------------------------------

  Widget _group({
    required String title,
    required bool expanded,
    required ValueChanged<bool> onToggle,
    required String? summary,
    required List<Widget> children,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onToggle(!expanded),
          child: SizedBox(
            height: 32,
            child: Row(
              children: [
                AnimatedRotation(
                  turns: expanded ? 0.25 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Lucide.ChevronRight,
                    size: 14,
                    color: cs.onSurface.withOpacity(0.5),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withOpacity(0.5),
                  ),
                ),
                const Spacer(),
                if (!expanded && summary != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withOpacity(0.5),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: expanded
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < children.length; i++) ...[
                      if (i > 0) const SizedBox(height: 8),
                      children[i],
                    ],
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _hintRow(String text) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Text(
        text,
        style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.55)),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  /// Write Todos switch (mirrors the old workspace-tools planning switch:
  /// one switch owns both the planning flag and the legacy per-tool kill
  /// switch so older installs cannot disagree with it).
  Future<void> _setWriteTodos(bool v) async {
    final sp = context.read<SettingsProvider>();
    await sp.setPlanningEnabled(v);
    if (v) {
      await sp.setWorkspaceToolEnabled(todoToolName, true);
    }
  }

  Future<void> _setAskUser(bool v) {
    return context
        .read<SettingsProvider>()
        .setWorkspaceToolEnabled(askUserToolName, v);
  }

  Future<void> _toggleServer(String serverId, bool selected) async {
    if (widget.assistantId == null) return;
    final ap = context.read<AssistantProvider>();
    final assistant = ap.getById(widget.assistantId!);
    if (assistant == null) return;
    final ids = Set<String>.of(assistant.mcpServerIds);
    if (selected) {
      ids.add(serverId);
    } else {
      ids.remove(serverId);
    }
    await ap.updateAssistant(assistant.copyWith(mcpServerIds: ids.toList()));
  }

  Future<void> _setAllServers(bool selectAll) async {
    if (widget.assistantId == null) return;
    final mcp = context.read<McpProvider>();
    final ap = context.read<AssistantProvider>();
    final assistant = ap.getById(widget.assistantId!);
    if (assistant == null) return;
    final ids = selectAll
        ? [
            for (final s in mcp.servers)
              if (mcp.statusFor(s.id) == McpStatus.connected) s.id,
          ]
        : const <String>[];
    await ap.updateAssistant(assistant.copyWith(mcpServerIds: ids));
  }

  Future<void> _openManageServers() async {
    await widget.onRequestClose?.call();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const McpPage()),
    );
  }

  // ---------------------------------------------------------------------------
  // Self-Review mode picker (moved out of the settings page on 2026-11-10)
  // ---------------------------------------------------------------------------

  String _selfReviewModeLabel(AppLocalizations l10n, AnswerReviewMode mode) {
    switch (mode) {
      case AnswerReviewMode.off:
        return l10n.displaySettingsPageAnswerReviewOptionOff;
      case AnswerReviewMode.smart:
        return l10n.displaySettingsPageAnswerReviewOptionSmart;
      case AnswerReviewMode.always:
        return l10n.displaySettingsPageAnswerReviewOptionAlways;
    }
  }

  Future<void> _showSelfReviewModePicker(BuildContext context) async {
    final isDesktop =
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
    if (isDesktop) {
      await _showSelfReviewModeDialog(context);
    } else {
      await _showSelfReviewModeSheet(context);
    }
  }

  Future<void> _showSelfReviewModeSheet(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final sp = context.read<SettingsProvider>();
    final current = sp.answerReviewMode;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _modeOption(
                ctx,
                l10n.displaySettingsPageAnswerReviewOptionOff,
                selected: current == AnswerReviewMode.off,
                onTap: () => Navigator.of(ctx).pop('off'),
              ),
              _modeDivider(ctx),
              _modeOption(
                ctx,
                l10n.displaySettingsPageAnswerReviewOptionSmart,
                selected: current == AnswerReviewMode.smart,
                onTap: () => Navigator.of(ctx).pop('smart'),
              ),
              _modeDivider(ctx),
              _modeOption(
                ctx,
                l10n.displaySettingsPageAnswerReviewOptionAlways,
                selected: current == AnswerReviewMode.always,
                onTap: () => Navigator.of(ctx).pop('always'),
              ),
              _modeDivider(ctx),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.displaySettingsPageAnswerReviewSmartHint,
                      style: TextStyle(
                        color: cs.onSurface.withOpacity(0.6),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.displaySettingsPageAnswerReviewCostHint,
                      style: TextStyle(
                        color: cs.onSurface.withOpacity(0.6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await _applySelfReviewChoice(sp, choice);
  }

  Future<void> _showSelfReviewModeDialog(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final sp = context.read<SettingsProvider>();
    final current = sp.answerReviewMode;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Material(
            color: cs.surface,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
                    child: Text(
                      l10n.displaySettingsPageAnswerReviewTitle,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  _modeOption(
                    ctx,
                    l10n.displaySettingsPageAnswerReviewOptionOff,
                    selected: current == AnswerReviewMode.off,
                    onTap: () => Navigator.of(ctx).pop('off'),
                  ),
                  _modeDivider(ctx),
                  _modeOption(
                    ctx,
                    l10n.displaySettingsPageAnswerReviewOptionSmart,
                    selected: current == AnswerReviewMode.smart,
                    onTap: () => Navigator.of(ctx).pop('smart'),
                  ),
                  _modeDivider(ctx),
                  _modeOption(
                    ctx,
                    l10n.displaySettingsPageAnswerReviewOptionAlways,
                    selected: current == AnswerReviewMode.always,
                    onTap: () => Navigator.of(ctx).pop('always'),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.displaySettingsPageAnswerReviewSmartHint,
                          style: TextStyle(
                            color: cs.onSurface.withOpacity(0.6),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.displaySettingsPageAnswerReviewCostHint,
                          style: TextStyle(
                            color: cs.onSurface.withOpacity(0.6),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await _applySelfReviewChoice(sp, choice);
  }

  Future<void> _applySelfReviewChoice(
    SettingsProvider sp,
    String? choice,
  ) async {
    // Dismissing the sheet/dialog (scrim tap, back, drag-down) must not
    // change anything — only an explicit option pick applies a mode.
    if (choice == null) return;
    switch (choice) {
      case 'smart':
        await sp.setAnswerReviewMode(AnswerReviewMode.smart);
        break;
      case 'always':
        await sp.setAnswerReviewMode(AnswerReviewMode.always);
        break;
      default:
        await sp.setAnswerReviewMode(AnswerReviewMode.off);
    }
  }

  Widget _modeOption(
    BuildContext ctx,
    String label, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(ctx).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  color: selected ? cs.primary : cs.onSurface,
                ),
              ),
            ),
            if (selected) Icon(Lucide.Check, size: 16, color: cs.primary),
          ],
        ),
      ),
    );
  }

  Widget _modeDivider(BuildContext ctx) {
    final cs = Theme.of(ctx).colorScheme;
    return Divider(
      height: 1,
      thickness: 0.6,
      indent: 16,
      endIndent: 16,
      color: cs.outlineVariant.withOpacity(0.18),
    );
  }
}

/// One menu row (kelivo tools-sheet row anatomy): leading icon, title,
/// optional subtitle, optional right-aligned detail text and a trailing
/// switch/chevron. Disabled rows dim and ignore pointers.
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.leading,
    required this.title,
    this.subtitle,
    this.detail,
    this.detailHighlight = false,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final String? detail;
  final bool detailHighlight;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final row = IosCardPress(
      borderRadius: BorderRadius.circular(14),
      baseColor: isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.04),
      duration: const Duration(milliseconds: 260),
      onTap: onTap ?? () {},
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withOpacity(0.55),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (detail != null) ...[
            const SizedBox(width: 8),
            Text(
              detail!,
              style: TextStyle(
                fontSize: 13,
                fontWeight: detailHighlight ? FontWeight.w600 : FontWeight.w400,
                color: detailHighlight
                    ? cs.primary
                    : cs.onSurface.withOpacity(0.6),
              ),
            ),
          ],
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
    if (enabled) return row;
    return IgnorePointer(
      ignoring: true,
      child: Opacity(opacity: 0.45, child: row),
    );
  }
}
