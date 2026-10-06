// Skills settings page (PLAN_AGENT_SKILLS.md §7.2). Follows the
// InstructionInjectionPage visual language: tactile cards + Slidable delete.
//
// Scope split (D2/D6): this page manages GLOBAL skills only. Project skills
// are read-only auto-discovery from the conversation workspace. Desktop shows
// no delete control (the global dir is shared with Claude Code / Anybuff);
// mobile gets Slidable + a per-row delete button.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/models/skill.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/skills_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../utils/platform_utils.dart';
import '../widgets/github_skills_dialog.dart';
import '../widgets/skill_edit_sheet.dart';

class SkillsPage extends StatefulWidget {
  const SkillsPage({super.key});

  @override
  State<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends State<SkillsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<SkillsProvider>().refresh();
    });
  }

  // ==========================================================================
  // Actions
  // ==========================================================================

  Future<bool> _confirm(BuildContext context, String message) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.skillsTitle),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.quickPhraseCancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.skillsConfirmButton),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _createSkill() async {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<SkillsProvider>();
    final form = await showSkillEditSheet(context);
    if (form == null || !mounted) return;
    final name = form['name'] ?? '';
    final description = form['description'] ?? '';
    final body = form['body'] ?? '';

    var result = await provider.createSkill(
      name: name,
      description: description,
      body: body,
    );
    if (!mounted) return;
    if (!result.ok && result.exists) {
      final overwrite = await _confirm(context, l10n.skillsOverwriteConfirm(name));
      if (!overwrite || !mounted) return;
      result = await provider.createSkill(
        name: name,
        description: description,
        body: body,
        confirm: true,
      );
    }
    if (!mounted) return;
    showAppSnackBar(
      context,
      message: result.ok
          ? l10n.skillsGithubDownloadSuccess(name)
          : (result.error ?? l10n.skillsImportFailed),
      type: result.ok ? NotificationType.success : NotificationType.error,
    );
  }

  Future<void> _importSkills() async {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<SkillsProvider>();

    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: const ['md'],
      );
    } catch (_) {
      return;
    }
    if (picked == null || picked.files.isEmpty) return;

    var imported = 0;
    for (final file in picked.files) {
      final path = file.path;
      if (path == null || path.isEmpty) continue;
      var result = await provider.importSkill(sourcePath: path);
      if (!mounted) return;

      if (result.folderConfirm) {
        final count = result.folderFiles.length;
        final proceed = await _confirm(
          context,
          '${l10n.skillsFolderConfirmTitle}\n\n'
          '${l10n.skillsFolderConfirmFiles(count)}\n\n'
          '${result.folderFiles.take(20).join('\n')}',
        );
        if (!proceed || !mounted) continue;
        result = await provider.importSkill(
          sourcePath: path,
          confirmFolder: true,
        );
      }
      if (!mounted) return;

      if (!result.ok && result.exists) {
        final name = _skillNameFromFile(path);
        final overwrite = await _confirm(
          context,
          l10n.skillsOverwriteConfirm(name),
        );
        if (!overwrite || !mounted) continue;
        result = await provider.importSkill(
          sourcePath: path,
          confirm: true,
          confirmFolder: true,
        );
      }
      if (!mounted) return;
      if (result.ok) imported++;
    }
    if (!mounted) return;
    showAppSnackBar(
      context,
      message: imported > 0
          ? l10n.skillsImportSuccess(imported)
          : l10n.skillsImportFailed,
      type: imported > 0 ? NotificationType.success : NotificationType.warning,
    );
  }

  String _skillNameFromFile(String path) {
    try {
      final content = File(path).readAsStringSync();
      final name = _extractName(content);
      if (name != null && name.isNotEmpty) return name;
    } catch (_) {}
    return File(path).parent.path.split(Platform.pathSeparator).last;
  }

  String? _extractName(String content) {
    final match = RegExp(r'^name:\s*(.+)$', multiLine: true)
        .firstMatch(content);
    if (match == null) return null;
    var value = match.group(1)!.trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }

  Future<void> _deleteSkill(SkillDefinition skill) async {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<SkillsProvider>();
    final confirmed =
        await _confirm(context, l10n.skillsDeleteConfirm(skill.name));
    if (!confirmed || !mounted) return;
    final result = await provider.deleteSkill(skill.name);
    if (!mounted) return;
    showAppSnackBar(
      context,
      message: result.ok
          ? l10n.skillsGithubDownloadSuccess(skill.name)
          : (result.error ?? l10n.skillsImportFailed),
      type: result.ok ? NotificationType.success : NotificationType.error,
    );
  }

  Future<void> _openFolder(String path) async {
    try {
      final uri = Uri.file(path);
      await launchUrl(uri);
    } catch (_) {}
  }

  // ==========================================================================
  // Build
  // ==========================================================================

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.watch<SkillsProvider>();
    final settings = context.watch<SettingsProvider>();
    final skills = provider.globalSkills;

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: _TactileIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.skillsTitle),
        actions: [
          Tooltip(
            message: l10n.skillsGithubTooltip,
            child: _TactileIconButton(
              icon: Lucide.Package,
              color: cs.onSurface,
              onTap: () => showGithubSkillsDialog(context),
            ),
          ),
          Tooltip(
            message: l10n.skillsImportTooltip,
            child: _TactileIconButton(
              icon: Lucide.Import,
              color: cs.onSurface,
              onTap: _importSkills,
            ),
          ),
          Tooltip(
            message: l10n.skillsAddTooltip,
            child: _TactileIconButton(
              icon: Lucide.Plus,
              color: cs.onSurface,
              onTap: _createSkill,
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: provider.refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            // Preload switch card
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark ? Colors.white10 : Colors.white.withOpacity(0.96),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: cs.outlineVariant.withOpacity(isDark ? 0.1 : 0.08),
                  width: 0.6,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.skillsPreloadTitle,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          l10n.skillsPreloadDescription,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.35,
                            color: cs.onSurface.withOpacity(0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  IosSwitch(
                    value: settings.skillsPreloadEnabled,
                    onChanged: (v) =>
                        context.read<SettingsProvider>().setSkillsPreloadEnabled(v),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Section header
            Text(
              l10n.skillsInstalledSection(skills.length),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 10),

            if (provider.loading && skills.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (provider.error != null && skills.isEmpty)
              _ErrorRow(message: l10n.skillsLoadError)
            else if (skills.isEmpty)
              _EmptyState(
                onAdd: _createSkill,
                onImport: _importSkills,
                onGithub: () => showGithubSkillsDialog(context),
              )
            else
              ...skills.map(
                (skill) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _SkillCard(
                    skill: skill,
                    onDelete: PlatformUtils.isMobile
                        ? () => _deleteSkill(skill)
                        : null,
                  ),
                ),
              ),

            const SizedBox(height: 12),
            _HelpBlock(
              provider: provider,
              onOpenFolder: provider.globalRootPath == null
                  ? null
                  : () => _openFolder(provider.globalRootPath!),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.error.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Lucide.CircleX, size: 18, color: cs.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 13, color: cs.error),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.onAdd,
    required this.onImport,
    required this.onGithub,
  });

  final VoidCallback onAdd;
  final VoidCallback onImport;
  final VoidCallback onGithub;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
      child: Column(
        children: [
          Icon(Lucide.WandSparkles, size: 56, color: cs.onSurface.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text(
            l10n.skillsEmptyMessage,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurface.withOpacity(0.6),
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            children: [
              FilledButton.icon(
                onPressed: onAdd,
                icon: Icon(Lucide.Plus, size: 16),
                label: Text(l10n.skillsAddTooltip),
              ),
              OutlinedButton.icon(
                onPressed: onImport,
                icon: Icon(Lucide.Import, size: 16),
                label: Text(l10n.skillsImportTooltip),
              ),
              OutlinedButton.icon(
                onPressed: onGithub,
                icon: Icon(Lucide.Package, size: 16),
                label: Text(l10n.skillsGithubTooltip),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SkillCard extends StatelessWidget {
  const _SkillCard({required this.skill, this.onDelete});

  final SkillDefinition skill;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final sourceLabel = switch (skill.source) {
      SkillInstallSource.manual => l10n.skillSourceManual,
      SkillInstallSource.file => l10n.skillSourceFile,
      SkillInstallSource.github => l10n.skillSourceGithub,
      SkillInstallSource.external => l10n.skillSourceExternal,
    };

    final card = Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white.withOpacity(0.96),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: cs.outlineVariant.withOpacity(isDark ? 0.1 : 0.08),
          width: 0.6,
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Lucide.WandSparkles, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  skill.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              _Badge(label: sourceLabel),
              if (onDelete != null) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: l10n.skillsDeleteTooltip,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      Haptics.light();
                      onDelete!.call();
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Lucide.Trash2, size: 16, color: cs.error),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            skill.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withOpacity(0.7),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Lucide.Folder, size: 13, color: cs.onSurface.withOpacity(0.5)),
              const SizedBox(width: 4),
              Text(
                l10n.skillFilesCount(skill.fileCount),
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withOpacity(0.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (onDelete == null) return card;

    return Slidable(
      key: ValueKey('skill-${skill.name}'),
      endActionPane: ActionPane(
        motion: const StretchMotion(),
        extentRatio: 0.3,
        children: [
          CustomSlidableAction(
            autoClose: true,
            backgroundColor: Colors.transparent,
            child: Container(
              width: double.infinity,
              height: double.infinity,
              decoration: BoxDecoration(
                color: isDark
                    ? cs.error.withOpacity(0.22)
                    : cs.error.withOpacity(0.14),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: cs.error.withOpacity(0.35)),
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              alignment: Alignment.center,
              child: Icon(Lucide.Trash2, color: cs.error, size: 18),
            ),
            onPressed: (_) => onDelete!.call(),
          ),
        ],
      ),
      child: card,
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: cs.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: cs.primary.withOpacity(0.85)),
      ),
    );
  }
}

class _HelpBlock extends StatelessWidget {
  const _HelpBlock({required this.provider, this.onOpenFolder});

  final SkillsProvider provider;
  final VoidCallback? onOpenFolder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final path = provider.globalRootPath ?? '~/.agents/skills';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withOpacity(0.04)
            : Colors.black.withOpacity(0.03),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.skillsFormatHelp,
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: cs.onSurface.withOpacity(0.65),
            ),
          ),
          const SizedBox(height: 10),
          if (!PlatformUtils.isMobile)
            Text(
              l10n.skillsDesktopDeleteHint(path),
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: cs.onSurface.withOpacity(0.65),
              ),
            ),
          if (!PlatformUtils.isMobile && onOpenFolder != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onOpenFolder,
              icon: Icon(Lucide.FolderOpen, size: 15),
              label: Text(l10n.skillsOpenFolderTooltip),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            l10n.skillsProjectHint,
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: cs.onSurface.withOpacity(0.65),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.skillsNoBackupNote,
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: cs.onSurface.withOpacity(0.65),
            ),
          ),
        ],
      ),
    );
  }
}

class _TactileIconButton extends StatefulWidget {
  const _TactileIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  State<_TactileIconButton> createState() => _TactileIconButtonState();
}

class _TactileIconButtonState extends State<_TactileIconButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.color;
    final press = base.withOpacity(0.7);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        Haptics.light();
        widget.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          widget.icon,
          size: 22,
          color: _pressed ? press : base,
        ),
      ),
    );
  }
}
