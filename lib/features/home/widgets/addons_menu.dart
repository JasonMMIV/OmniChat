import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/answer_review.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/agent/subagent.dart';
import '../../../core/services/agent/subagent_profiles.dart';
import '../../../core/services/chat/ask_user_models.dart';
import '../../../core/services/haptics.dart';
import '../../../core/services/chat/todo_models.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/subagent_profile_icon.dart';

/// Mobile entry: the Add-ons bottom sheet behind the composer button
/// (desktop uses `showAddonsPopover` instead — no bottom sheets there).
///
/// The menu gathers everything the model can use in one place: MCP servers,
/// the built-in write_todos / ask_user tools and the advanced Subagents /
/// Self-Review features (2026-11-10 Add-ons reorganization).
Future<void> showAddonsSheet(
  BuildContext context, {
  required String? assistantId,
  ValueChanged<String>? onDelegateProfile,
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
      onDelegateProfile: onDelegateProfile,
    ),
  );
}

class _AddonsSheetBody extends StatelessWidget {
  const _AddonsSheetBody({required this.assistantId, this.onDelegateProfile});

  final String? assistantId;
  final ValueChanged<String>? onDelegateProfile;

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
            const SizedBox(height: 8),
            Text(
              l10n.chatInputBarAddonsTooltip,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: AddonsMenuContent(
                  assistantId: assistantId,
                  onRequestClose: () => Navigator.of(context).maybePop(),
                  onDelegateProfile: onDelegateProfile,
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
/// tools / advanced features). Subagents live in Advanced Features because
/// they start an isolated helper run rather than a single primitive tool call.
/// Hosted by the mobile bottom sheet and the desktop popover alike. Kept
/// compact so it reads like the other composer menus (2026-11-10 Windows
/// feedback pass).
class AddonsMenuContent extends StatefulWidget {
  const AddonsMenuContent({
    super.key,
    required this.assistantId,
    this.onRequestClose,
    this.onDelegateProfile,
  });

  /// Assistant whose MCP selection the switches edit. Null (or a stale id)
  /// degrades the MCP group to hints instead of crashing.
  final String? assistantId;

  /// Closes the hosting sheet/popover before the menu navigates elsewhere
  /// (the Self-Review picker).
  final Future<void> Function()? onRequestClose;

  /// Inserts `@<profileId>` into the composer after the menu closes.
  final ValueChanged<String>? onDelegateProfile;

  @override
  State<AddonsMenuContent> createState() => _AddonsMenuContentState();
}

class _AddonsMenuContentState extends State<AddonsMenuContent> {
  bool _mcpExpanded = true;
  bool _builtInExpanded = true;
  bool _advancedExpanded = true;
  bool _subagentExpanded = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    final mcp = context.watch<McpProvider>();
    final ap = context.watch<AssistantProvider>();
    final assistant = widget.assistantId == null
        ? null
        : ap.getById(widget.assistantId!);

    final connected = mcp.servers
        .where((s) => mcp.statusFor(s.id) == McpStatus.connected)
        .toList();
    final selectedIds = assistant?.mcpServerIds.toSet() ?? const <String>{};
    final selectedCount = connected
        .where((s) => selectedIds.contains(s.id))
        .length;

    final writeTodosOn =
        settings.planningEnabled &&
        settings.isWorkspaceToolEnabled(todoToolName);
    final askUserOn = settings.isWorkspaceToolEnabled(askUserToolName);
    final subagentOn = settings.isWorkspaceToolEnabled(spawnSubagentToolName);
    final subagentProfiles = settings.subagentProfiles;
    final reviewMode = settings.answerReviewMode;
    final advancedOnCount =
        (subagentOn ? 1 : 0) + (reviewMode != AnswerReviewMode.off ? 1 : 0);

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
            if (connected.isEmpty)
              _hintRow(l10n.assistantEditMcpNoServersMessage)
            else
              for (final s in connected)
                _MenuRow(
                  leading: Icon(
                    Lucide.Hammer,
                    size: 16,
                    color: selectedIds.contains(s.id)
                        ? cs.primary
                        : cs.onSurface,
                  ),
                  title: s.name,
                  detail: _toolsCountTag(
                    l10n.assistantEditMcpToolsCountTag(
                      s.tools.where((t) => t.enabled).length.toString(),
                      s.tools.length.toString(),
                    ),
                  ),
                  enabled: assistant != null,
                  onTap: () => _toggleServer(s.id, !selectedIds.contains(s.id)),
                  trailing: IosSwitch(
                    value: selectedIds.contains(s.id),
                    width: 38,
                    height: 22,
                    hitTestSize: 44,
                    onChanged: assistant == null
                        ? null
                        : (v) => _toggleServer(s.id, v),
                  ),
                ),
          ],
        ),
        const SizedBox(height: 8),
        _group(
          title: l10n.addonsBuiltInToolsTitle,
          expanded: _builtInExpanded,
          onToggle: (v) => setState(() => _builtInExpanded = v),
          summary: '${(writeTodosOn ? 1 : 0) + (askUserOn ? 1 : 0)}/2',
          children: [
            _MenuRow(
              leading: Icon(Lucide.ListChecks, size: 16, color: cs.onSurface),
              title: l10n.builtInToolWriteTodosName,
              subtitle: l10n.addonsWriteTodosSubtitle,
              onTap: () => _setWriteTodos(!writeTodosOn),
              trailing: IosSwitch(
                value: writeTodosOn,
                width: 38,
                height: 22,
                hitTestSize: 44,
                onChanged: _setWriteTodos,
              ),
            ),
            _MenuRow(
              leading: Icon(
                Lucide.MessageCircle,
                size: 16,
                color: cs.onSurface,
              ),
              title: l10n.builtInToolAskUserName,
              subtitle: l10n.addonsAskUserSubtitle,
              onTap: () => _setAskUser(!askUserOn),
              trailing: IosSwitch(
                value: askUserOn,
                width: 38,
                height: 22,
                hitTestSize: 44,
                onChanged: _setAskUser,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _group(
          title: l10n.addonsAdvancedFeaturesTitle,
          expanded: _advancedExpanded,
          onToggle: (v) => setState(() => _advancedExpanded = v),
          summary:
              '$advancedOnCount/2 · ${_selfReviewModeLabel(l10n, reviewMode)}',
          children: [
            _MenuRow(
              leading: Icon(
                Lucide.UserRoundGroup,
                size: 16,
                color: subagentOn ? cs.primary : cs.onSurface.withOpacity(0.45),
              ),
              title: l10n.builtInToolSubagentName,
              subtitle: l10n.addonsSubagentSubtitle,
              detail: Text(
                subagentOn
                    ? l10n.addonsSubagentProfileCount(
                        subagentProfiles.length.toString(),
                      )
                    : l10n.addonsSubagentEnable,
                style: TextStyle(
                  fontSize: 12,
                  color: subagentOn
                      ? cs.primary
                      : cs.onSurface.withOpacity(0.6),
                ),
              ),
              trailing: AnimatedRotation(
                turns: _subagentExpanded ? 0.25 : 0,
                duration: const Duration(milliseconds: 160),
                child: Icon(
                  Lucide.ChevronRight,
                  size: 14,
                  color: cs.onSurface.withOpacity(0.55),
                ),
              ),
              onTap: () =>
                  setState(() => _subagentExpanded = !_subagentExpanded),
            ),
            if (_subagentExpanded) ...[
              _MenuRow(
                leading: Icon(
                  Lucide.toggleRight,
                  size: 16,
                  color: subagentOn ? cs.primary : cs.onSurface,
                ),
                title: l10n.addonsSubagentEnable,
                onTap: () => _setSubagent(!subagentOn),
                trailing: IosSwitch(
                  value: subagentOn,
                  width: 38,
                  height: 22,
                  hitTestSize: 44,
                  onChanged: _setSubagent,
                ),
              ),
              if (!subagentOn) _hintRow(l10n.addonsSubagentPickHint),
              for (final profile in subagentProfiles)
                _MenuRow(
                  leading: SubagentProfileIcon(
                    profile: profile,
                    size: 16,
                    color: cs.onSurface,
                  ),
                  title: profile.name,
                  subtitle: _subagentProfileSubtitle(l10n, profile),
                  trailing: Icon(
                    Lucide.ChevronRight,
                    size: 14,
                    color: cs.onSurface.withOpacity(0.55),
                  ),
                  enabled: subagentOn,
                  onTap: () => _pickSubagentProfile(profile.id),
                ),
            ],
            _MenuRow(
              leading: Icon(
                Lucide.ScanSearch,
                size: 16,
                color: reviewMode == AnswerReviewMode.off
                    ? cs.onSurface
                    : cs.primary,
              ),
              title: l10n.displaySettingsPageAnswerReviewTitle,
              subtitle: l10n.displaySettingsPageAnswerReviewDescription,
              detail: Text(
                _selfReviewModeLabel(l10n, reviewMode),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: reviewMode == AnswerReviewMode.off
                      ? FontWeight.w400
                      : FontWeight.w600,
                  color: reviewMode == AnswerReviewMode.off
                      ? cs.onSurface.withOpacity(0.6)
                      : cs.primary,
                ),
              ),
              trailing: Icon(
                Lucide.ChevronRight,
                size: 14,
                color: cs.onSurface.withOpacity(0.55),
              ),
              onTap: _showSelfReviewModePicker,
            ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Collapsible group header
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
            height: 28,
            child: Row(
              children: [
                AnimatedRotation(
                  turns: expanded ? 0.25 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Lucide.ChevronRight,
                    size: 12,
                    color: cs.onSurface.withOpacity(0.5),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withOpacity(0.5),
                  ),
                ),
                const Spacer(),
                if (!expanded && summary != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 12,
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
                      if (i > 0) const SizedBox(height: 2),
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
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.55)),
      ),
    );
  }

  /// The original OmniChat MCP tools-count pill (formerly in the assistant
  /// MCP sheet): tinted primary fill + hairline border.
  Widget _toolsCountTag(String text) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: cs.primary.withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.primary.withOpacity(0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          color: cs.primary,
          fontWeight: FontWeight.w600,
        ),
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
    return context.read<SettingsProvider>().setWorkspaceToolEnabled(
      askUserToolName,
      v,
    );
  }

  Future<void> _setSubagent(bool v) {
    return context.read<SettingsProvider>().setWorkspaceToolEnabled(
      spawnSubagentToolName,
      v,
    );
  }

  String _subagentProfileSubtitle(
    AppLocalizations l10n,
    SubagentProfile profile,
  ) {
    final toolCount = profile.allowedTools?.length;
    return [
      profile.id,
      if (profile.readOnly) l10n.subagentProfileReadOnly,
      if (toolCount != null)
        l10n.subagentProfileToolsCount(toolCount.toString()),
      profile.followsConversationModel
          ? l10n.subagentProfileFollowConversation
          : '${profile.providerKey} / ${profile.modelId}',
    ].join(' · ');
  }

  Future<void> _pickSubagentProfile(String profileId) async {
    await widget.onRequestClose?.call();
    // Mobile sheets pop without awaiting the route animation; let it clear so
    // the composer can take focus and the keyboard opens over it.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    widget.onDelegateProfile?.call(profileId);
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

  Future<void> _showSelfReviewModePicker() async {
    final isDesktop =
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
    // Close the hosting menu first: the desktop popover lives in an
    // OverlayEntry above the navigator, so a dialog opened while it is still
    // inserted would appear *behind* the panel (Windows feedback, 2026-11-10).
    final navigator = Navigator.of(context);
    final sp = context.read<SettingsProvider>();
    await widget.onRequestClose?.call();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!navigator.mounted) return;
    if (isDesktop) {
      await _showSelfReviewModeDialog(navigator.context, sp);
    } else {
      await _showSelfReviewModeSheet(navigator.context, sp);
    }
  }

  Future<void> _showSelfReviewModeSheet(
    BuildContext context,
    SettingsProvider sp,
  ) async {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
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

  Future<void> _showSelfReviewModeDialog(
    BuildContext context,
    SettingsProvider sp,
  ) async {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
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

/// One compact menu row: leading icon, title, optional subtitle, optional
/// right-aligned detail widget (pill/tag/text) and a trailing switch/chevron.
/// Background stays transparent — only a subtle hover tint appears.
class _MenuRow extends StatefulWidget {
  const _MenuRow({
    required this.leading,
    required this.title,
    this.subtitle,
    this.detail,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final Widget? detail;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hoverBg = (isDark ? Colors.white : Colors.black).withOpacity(
      isDark ? 0.08 : 0.05,
    );
    final row = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          Haptics.light();
          widget.onTap?.call();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: _hovered ? hoverBg : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              widget.leading,
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                    ),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 1),
                      Text(
                        widget.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: cs.onSurface.withOpacity(0.55),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.detail != null) ...[
                const SizedBox(width: 8),
                widget.detail!,
              ],
              if (widget.trailing != null) ...[
                const SizedBox(width: 8),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
    if (widget.enabled) return row;
    return IgnorePointer(
      ignoring: true,
      child: Opacity(opacity: 0.45, child: row),
    );
  }
}
