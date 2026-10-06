// Agent Skills data model (PLAN_AGENT_SKILLS.md §3.1).
//
// A skill is a folder under a skills root (`~/.agents/skills/` on desktop,
// `<appData>/.agents/skills/` on mobile, `<workspace>/.agents/skills/` for
// project scope) containing a `SKILL.md` with YAML frontmatter plus optional
// attachment files (`references/`, `scripts/`, ...). The format is byte-level
// compatible with Claude Code / Anybuff so the same folder works across tools.
//
// Result types below are plain data (no exceptions across install boundaries)
// so the UI can render status without try/catch plumbing.

enum SkillScope { global, project }

enum SkillInstallSource { manual, file, github, external }

extension SkillInstallSourceCodec on SkillInstallSource {
  String get value => switch (this) {
        SkillInstallSource.manual => 'manual',
        SkillInstallSource.file => 'file',
        SkillInstallSource.github => 'github',
        SkillInstallSource.external => 'external',
      };

  static SkillInstallSource fromValue(String? value) {
    switch (value) {
      case 'manual':
        return SkillInstallSource.manual;
      case 'file':
        return SkillInstallSource.file;
      case 'github':
        return SkillInstallSource.github;
      default:
        // No provenance stamp (installed by another tool) → external.
        return SkillInstallSource.external;
    }
  }
}

class SkillDefinition {
  const SkillDefinition({
    required this.name,
    required this.description,
    this.license,
    this.disableModelInvocation = false,
    required this.content,
    required this.filePath,
    required this.scope,
    this.fileCount = 1,
    this.source = SkillInstallSource.external,
    this.installedAt,
  });

  /// Frontmatter `name` — must equal the folder name (loader keys by it).
  final String name;

  /// Frontmatter `description` — clamped to [SkillParser.maxDescriptionLength]
  /// by the parser (truncated, never rejected).
  final String description;
  final String? license;

  /// `true` = hidden from the `<available_skills>` list; still loadable via
  /// the `skill` tool by name or the `/skill <name>` command.
  final bool disableModelInvocation;

  /// Complete SKILL.md text (frontmatter included) — this is what the `skill`
  /// tool returns and what `/skill <name>` injects.
  final String content;

  /// Absolute path of the SKILL.md file.
  final String filePath;
  final SkillScope scope;

  /// Files in the skill folder (including SKILL.md) — UI "含附件" hint.
  final int fileCount;

  /// Best-effort provenance read from frontmatter `metadata.source`.
  final SkillInstallSource source;
  final DateTime? installedAt;

  SkillDefinition copyWith({
    String? name,
    String? description,
    String? license,
    bool? disableModelInvocation,
    String? content,
    String? filePath,
    SkillScope? scope,
    int? fileCount,
    SkillInstallSource? source,
    DateTime? installedAt,
  }) {
    return SkillDefinition(
      name: name ?? this.name,
      description: description ?? this.description,
      license: license ?? this.license,
      disableModelInvocation:
          disableModelInvocation ?? this.disableModelInvocation,
      content: content ?? this.content,
      filePath: filePath ?? this.filePath,
      scope: scope ?? this.scope,
      fileCount: fileCount ?? this.fileCount,
      source: source ?? this.source,
      installedAt: installedAt ?? this.installedAt,
    );
  }
}

/// Outcome of [SkillService.installSkill] / [SkillService.installSkillMulti].
class InstallResult {
  const InstallResult({
    required this.ok,
    this.skill,
    this.exists = false,
    this.error,
  });

  final bool ok;

  /// The freshly installed skill (null unless [ok]).
  final SkillDefinition? skill;

  /// True when a skill with the same name already exists and [confirm] was
  /// false — the caller should surface an overwrite confirmation.
  final bool exists;

  /// Machine-readable failure reason for non-[ok] results.
  final String? error;

  static InstallResult success(SkillDefinition skill) =>
      InstallResult(ok: true, skill: skill);

  static InstallResult existsConflict() =>
      const InstallResult(ok: false, exists: true, error: 'exists');

  static InstallResult failure(String error) =>
      InstallResult(ok: false, error: error);
}

/// Outcome of [SkillService.deleteSkill].
class DeleteResult {
  const DeleteResult({required this.ok, this.error});

  final bool ok;
  final String? error;

  static DeleteResult success() => const DeleteResult(ok: true);
  static DeleteResult failure(String error) =>
      DeleteResult(ok: false, error: error);
}

/// Outcome of [SkillService.importSkillFile]. `folderConfirm` mirrors the
/// two-step folder-import handshake: when a picked SKILL.md sits in a folder
/// with attachments, the first call returns the candidate file list and the
/// caller must re-invoke with `confirmFolder: true`.
class ImportResult {
  const ImportResult({
    required this.ok,
    this.skill,
    this.exists = false,
    this.folderConfirm = false,
    this.folderFiles = const <String>[],
    this.error,
  });

  final bool ok;
  final SkillDefinition? skill;
  final bool exists;
  final bool folderConfirm;
  final List<String> folderFiles;
  final String? error;

  static ImportResult success(SkillDefinition skill) =>
      ImportResult(ok: true, skill: skill);

  static ImportResult existsConflict() =>
      const ImportResult(ok: false, exists: true, error: 'exists');

  static ImportResult confirmFolder(List<String> files) => ImportResult(
        ok: false,
        folderConfirm: true,
        folderFiles: files,
        error: 'folder_confirm',
      );

  static ImportResult failure(String error) =>
      ImportResult(ok: false, error: error);
}

/// One installable folder inside a GitHub repo (contains a SKILL.md).
class GithubSkillCandidate {
  const GithubSkillCandidate({
    required this.name,
    required this.path,
    required this.fileCount,
  });

  /// Folder name — usually the skill name.
  final String name;
  final String path;
  final int fileCount;
}

/// Outcome of [GithubSkillService.listGithubSkills].
class ListGithubSkillsResult {
  const ListGithubSkillsResult({
    required this.ok,
    this.candidates = const <GithubSkillCandidate>[],
    this.truncated = false,
    this.error,
  });

  final bool ok;
  final List<GithubSkillCandidate> candidates;
  final bool truncated;
  final String? error;

  static ListGithubSkillsResult failure(String error) =>
      ListGithubSkillsResult(ok: false, error: error);
}

/// Outcome of [GithubSkillService.downloadGithubSkill].
class DownloadGithubSkillResult {
  const DownloadGithubSkillResult({
    required this.ok,
    this.skill,
    this.exists = false,
    this.error,
  });

  final bool ok;
  final SkillDefinition? skill;
  final bool exists;
  final String? error;

  static DownloadGithubSkillResult success(SkillDefinition skill) =>
      DownloadGithubSkillResult(ok: true, skill: skill);

  static DownloadGithubSkillResult existsConflict() =>
      const DownloadGithubSkillResult(ok: false, exists: true, error: 'exists');

  static DownloadGithubSkillResult failure(String error) =>
      DownloadGithubSkillResult(ok: false, error: error);
}
