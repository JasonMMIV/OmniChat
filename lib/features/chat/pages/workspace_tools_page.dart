import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/ask_user_models.dart';
import '../../../core/services/chat/todo_service.dart';
import '../../../core/services/file/file_tool_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';

/// One row of the workspace tools switchboard.
class _WorkspaceToolEntry {
  const _WorkspaceToolEntry({
    required this.name,
    required this.description,
    required this.icon,
  });

  final String name;
  final String description;
  final IconData icon;
}

/// Global workspace tools switchboard: the 15 built-in file tools plus the
/// write_todos and ask_user decision tools, each with its own toggle.
///
/// Only reachable from the workspace menu while the workspace is enabled —
/// a disabled workspace keeps every tool off regardless of these toggles.
class WorkspaceToolsPage extends StatelessWidget {
  const WorkspaceToolsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();

    final entries = <_WorkspaceToolEntry>[
      // File tools in definition order — the definitions are the canonical
      // name/description source, so the list can never drift from what the
      // LLM is actually offered.
      for (final def in FileToolService.getToolDefinitions())
        _WorkspaceToolEntry(
          name: ((def['function'] as Map)['name'] ?? '').toString(),
          description:
              ((def['function'] as Map)['description'] ?? '').toString(),
          icon: Lucide.FileText,
        ),
      _WorkspaceToolEntry(
        name: todoToolName,
        description: 'Write the plan/todo list for the current task.',
        icon: Lucide.ListChecks,
      ),
      _WorkspaceToolEntry(
        name: askUserToolName,
        description: 'Ask the user questions when a decision is needed.',
        icon: Lucide.MessageCircle,
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(l10n.workspaceToolsTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
              child: Text(
                l10n.workspaceToolsDescription,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: cs.onSurface.withOpacity(0.62),
                ),
              ),
            ),
            for (final entry in entries)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(entry.icon, size: 20),
                title: Text(
                  entry.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  _firstSentence(entry.description),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withOpacity(0.55),
                  ),
                ),
                trailing: IosSwitch(
                  value: settings.isWorkspaceToolEnabled(entry.name),
                  onChanged: (v) =>
                      settings.setWorkspaceToolEnabled(entry.name, v),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// First sentence of a built-in tool description (the raw descriptions are
/// English; showing the opening sentence keeps rows compact).
String _firstSentence(String description) {
  final text = description.trim();
  if (text.isEmpty) return text;
  final end = text.indexOf(RegExp(r'[.!?](\s|$)'));
  return end < 0 ? text : text.substring(0, end + 1);
}
