// GitHub skill download dialog (PLAN_AGENT_SKILLS.md §7.2 / D4).
// Two steps in one dialog: repo input → candidate folders (name, path, file
// count) → tap to download (overwrite confirmation → progress → snackbar).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/skill.dart';
import '../../../core/providers/skills_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';

Future<void> showGithubSkillsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _GithubSkillsDialog(),
  );
}

class _GithubSkillsDialog extends StatefulWidget {
  const _GithubSkillsDialog();

  @override
  State<_GithubSkillsDialog> createState() => _GithubSkillsDialogState();
}

class _GithubSkillsDialogState extends State<_GithubSkillsDialog> {
  final TextEditingController _repoController = TextEditingController();
  List<GithubSkillCandidate> _candidates = const <GithubSkillCandidate>[];
  bool _truncated = false;
  bool _listing = false;
  bool _downloading = false;
  String? _downloadingName;

  @override
  void dispose() {
    _repoController.dispose();
    super.dispose();
  }

  String? _mapError(BuildContext context, String? error) {
    final l10n = AppLocalizations.of(context)!;
    switch (error) {
      case 'invalid_repo':
        return l10n.skillsGithubInvalidRepo;
      case 'not_found':
        return l10n.skillsGithubError404;
      case 'rate_limit':
        return l10n.skillsGithubRateLimit;
      case 'no_skills':
        return l10n.skillsGithubNoSkills;
      case 'no_skill_md':
        return l10n.skillsGithubNoSkills;
      case 'invalid_skill':
        return l10n.skillsGithubListFailed;
      case null:
        return null;
      default:
        return l10n.skillsGithubListFailed;
    }
  }

  Future<void> _list() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _listing = true;
      _candidates = const [];
      _truncated = false;
    });
    final result = await context.read<SkillsProvider>().listGithubSkills(
          _repoController.text,
        );
    if (!mounted) return;
    setState(() {
      _listing = false;
      _candidates = result.candidates;
      _truncated = result.truncated;
    });
    if (!result.ok) {
      showAppSnackBar(
        context,
        message:
            _mapError(context, result.error) ?? l10n.skillsGithubListFailed,
        type: NotificationType.error,
      );
    }
  }

  Future<void> _download(GithubSkillCandidate candidate) async {
    final provider = context.read<SkillsProvider>();
    var confirm = false;
    while (true) {
      setState(() {
        _downloading = true;
        _downloadingName = candidate.name;
      });
      final result = await provider.downloadGithubSkill(
        repoInput: _repoController.text,
        path: candidate.path,
        confirm: confirm,
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloadingName = null;
      });
      if (result.ok) {
        final l10n = AppLocalizations.of(context)!;
        showAppSnackBar(
          context,
          message: l10n.skillsGithubDownloadSuccess(result.skill!.name),
          type: NotificationType.success,
        );
        if (Navigator.of(context).canPop()) Navigator.of(context).pop();
        return;
      }
      if (result.exists && !confirm) {
        final l10n = AppLocalizations.of(context)!;
        final overwrite = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l10n.skillsFolderConfirmTitle),
            content: Text(l10n.skillsOverwriteConfirm(candidate.name)),
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
        if (overwrite != true || !mounted) return;
        confirm = true;
        continue;
      }
      showAppSnackBar(
        context,
        message: _mapError(context, result.error) ?? result.error ?? '',
        type: NotificationType.error,
      );
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AlertDialog(
      title: Text(l10n.skillsGithubDialogTitle),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _repoController,
              enabled: !_downloading,
              decoration: InputDecoration(
                hintText: l10n.skillsGithubRepoHint,
                isDense: true,
                filled: true,
                fillColor: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      BorderSide(color: cs.outlineVariant.withOpacity(0.4)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      BorderSide(color: cs.outlineVariant.withOpacity(0.4)),
                ),
              ),
              onSubmitted: (_) => _listing || _downloading ? null : _list(),
            ),
            const SizedBox(height: 12),
            if (_listing || _downloading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _downloading
                            ? (_downloadingName ?? l10n.skillsGithubListing)
                            : l10n.skillsGithubListing,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withOpacity(0.7),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _candidates.length,
                  itemBuilder: (ctx, index) {
                    final c = _candidates[index];
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Lucide.Folder,
                        size: 18,
                        color: cs.primary,
                      ),
                      title: Text(
                        c.name,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(
                        '${c.path.isEmpty ? '/' : c.path} · ${l10n.skillFilesCount(c.fileCount)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withOpacity(0.6),
                        ),
                      ),
                      trailing: Icon(
                        Lucide.Download,
                        size: 16,
                        color: cs.onSurface.withOpacity(0.5),
                      ),
                      onTap: _downloading ? null : () => _download(c),
                    );
                  },
                ),
              ),
            if (_truncated && !_listing)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Lucide.BadgeInfo,
                        size: 14, color: cs.error.withOpacity(0.8)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        l10n.skillsGithubTruncated,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withOpacity(0.6),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _downloading
              ? null
              : () => Navigator.of(context).maybePop(),
          child: Text(l10n.quickPhraseCancelButton),
        ),
        if (!_listing && _candidates.isEmpty)
          FilledButton(
            onPressed: _downloading ? null : _list,
            child: Text(l10n.skillsGithubListButton),
          ),
      ],
    );
  }
}
