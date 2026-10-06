// Agent Skills service (PLAN_AGENT_SKILLS.md §3.3).
//
// IO + CRUD layer over the two skills roots:
// - global root: desktop `~/.agents/skills/` (shared with Claude Code /
//   Anybuff — writable but NO delete) / mobile `<appData>/.agents/skills/`
//   (app-private — full CRUD), and
// - project root: `<workspace>/.agents/skills/` (read-only discovery).
//
// Static methods with injectable roots keep every path unit-testable against
// temp directories (mirrors the FileToolService test pattern). All IO is
// sync-safe small-file work: skill folders are tiny and the scan runs on the
// UI isolate at message-assembly time (§15 R3 accepted the millisecond cost).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/skill.dart';
import 'skill_parser.dart';

/// Name of the LLM-facing tool that loads a skill by name.
const String skillToolName = 'skill';

class SkillService {
  SkillService._();

  /// In-memory cache of the resolved global root (async resolution is
  /// expensive and the directory never moves mid-session).
  static String? _globalRootCache;

  /// Synchronously available global root once [globalSkillsRoot] ran at least
  /// once (message assembly warms it before building tool definitions).
  static String? get cachedGlobalRoot => _globalRootCache;

  /// Injectable for tests. Resolved once, cached for the session.
  static Future<String> globalSkillsRoot() async {
    final cached = _globalRootCache;
    if (cached != null) return cached;
    final root = await _resolveGlobalRoot();
    _globalRootCache = root;
    return root;
  }

  static Future<String> _resolveGlobalRoot() async {
    final base = await _globalBaseDirectory();
    final dir = Directory('$base/.agents/skills');
    // Desktop first-use: `~/.agents/` may not exist — try to create it so
    // installs work immediately; a failure only disables auto-discovery.
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
    } catch (_) {}
    return dir.path;
  }

  /// Desktop → user home (`%USERPROFILE%` / `$HOME`), mobile → app data.
  /// Falls back to the app data directory when home is unavailable (never
  /// returns an empty string — installs must always land somewhere valid).
  static Future<String> _globalBaseDirectory() async {
    final home = homeDirectoryPath();
    if (home != null && home.trim().isNotEmpty) {
      return home;
    }
    return (await appDataDirectoryPath()).path;
  }

  /// Platform home directory, injectable via [debugHomeDirectoryOverride].
  static String? homeDirectoryPath() {
    final override = debugHomeDirectoryOverride;
    if (override != null) return override;
    if (Platform.isWindows) {
      return Platform.environment['USERPROFILE'];
    }
    return Platform.environment['HOME'];
  }

  /// Test seams — never set in production code.
  static String? debugHomeDirectoryOverride;
  static Directory? debugAppDataOverride;

  /// Test-only: drops the cached global root so a new
  /// [debugHomeDirectoryOverride] takes effect within the same process.
  static void debugResetGlobalRootCache() => _globalRootCache = null;

  static Future<Directory> appDataDirectoryPath() async {
    final override = debugAppDataOverride;
    if (override != null) return override;
    return appDataDirectoryHook();
  }

  /// Hook replaced by the Flutter-side initializer (avoids importing
  /// path_provider — and thus Flutter bindings — into this testable layer).
  static Future<Directory> Function() appDataDirectoryHook =
      _defaultAppDataUnavailable;

  static Future<Directory> _defaultAppDataUnavailable() async {
    throw StateError('appDataDirectoryHook not initialized');
  }

  /// Called from `AppDirectories` bootstrap so the service can resolve the
  /// mobile global root without a direct path_provider dependency here.
  static Future<Directory> defaultAppDataDirectory() async {
    return appDataDirectoryHook();
  }

  // ==========================================================================
  // Discovery
  // ==========================================================================

  /// Loads global + project skills. Later roots override earlier ones by
  /// name (project wins over global — Anybuff `loadSkillsSync` semantics).
  /// Returns a name-keyed map; unreadable roots are skipped silently
  /// (discovery must never throw into the message-assembly path).
  static Map<String, SkillDefinition> loadSkills({
    String? globalRoot,
    String? projectRoot,
  }) {
    final map = <String, SkillDefinition>{};
    if (globalRoot != null && globalRoot.isNotEmpty) {
      _scanRoot(globalRoot, SkillScope.global, map);
    }
    if (projectRoot != null && projectRoot.isNotEmpty) {
      _scanRoot(projectRoot, SkillScope.project, map);
    }
    return map;
  }

  static void _scanRoot(
    String root,
    SkillScope scope,
    Map<String, SkillDefinition> map,
  ) {
    final dir = Directory(root);
    List<FileSystemEntity> entries;
    try {
      if (!dir.existsSync()) return;
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final entry in entries) {
      if (entry is! Directory) continue;
      final dirName = _fileNameOf(entry.path);
      if (!SkillParser.isValidSkillName(dirName)) continue;
      final skillFile = _skillFileIn(entry.path);
      if (skillFile == null) continue;
      try {
        final content = File(skillFile).readAsStringSync();
        final skill = SkillParser.parseSkillFileContent(
          content,
          directoryName: dirName,
          filePath: skillFile,
          scope: scope,
          fileCount: countSkillFiles(entry.path),
        );
        if (skill != null) map[skill.name] = skill;
      } catch (_) {
        // Unreadable skill file — skip, never break discovery.
      }
    }
  }

  /// Case-insensitive SKILL.md lookup inside a skill folder.
  static String? _skillFileIn(String folderPath) {
    Directory folder;
    try {
      folder = Directory(folderPath);
      if (!folder.existsSync()) return null;
      for (final e in folder.listSync(followLinks: false)) {
        if (e is! File) continue;
        if (_fileNameOf(e.path).toLowerCase() ==
            SkillParser.skillFileName.toLowerCase()) {
          return e.path;
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Skills available for the current message assembly: project overrides
  /// global; no workspace → global only.
  static Map<String, SkillDefinition> skillsForContext({
    required String? workspacePath,
    String? globalRoot,
  }) {
    return loadSkills(
      globalRoot: globalRoot,
      projectRoot: workspacePath == null
          ? null
          : '$workspacePath/.agents/skills',
    );
  }

  /// Fresh disk read for one skill (project first, then global) — shared by
  /// the `skill` tool and `/skill` resolution so session-installed skills are
  /// immediately usable (Anybuff `loadSkillFromDisk` priority).
  static SkillDefinition? loadSkillByName(
    String name, {
    required String? workspacePath,
    String? globalRoot,
  }) {
    final map = skillsForContext(workspacePath: workspacePath, globalRoot: globalRoot);
    final hit = map[name];
    if (hit == null) return null;
    // Re-read from disk so content reflects any edit since the scan.
    try {
      final content = File(hit.filePath).readAsStringSync();
      final dirName = _fileNameOf(_parentOf(hit.filePath));
      return SkillParser.parseSkillFileContent(
        content,
        directoryName: dirName,
        filePath: hit.filePath,
        scope: hit.scope,
        fileCount: hit.fileCount,
      );
    } catch (_) {
      return hit;
    }
  }

  /// `<available_skills>` XML for the `skill` tool description (Anybuff
  /// format). Hides `disable-model-invocation` skills; empty list → ''.
  static String formatAvailableSkillsXml(
    Map<String, SkillDefinition> skills,
  ) {
    final visible = skills.values
        .where((s) => !s.disableModelInvocation)
        .toList(growable: false)
      ..sort((a, b) => a.name.compareTo(b.name));
    if (visible.isEmpty) return '';
    final buf = StringBuffer('<available_skills>');
    for (final s in visible) {
      buf
        ..write('<skill><name>')
        ..write(_xmlEscape(s.name))
        ..write('</name><description>')
        ..write(_xmlEscape(s.description))
        ..write('</description></skill>');
    }
    buf.write('</available_skills>');
    return buf.toString();
  }

  static String _xmlEscape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  // ==========================================================================
  // Install / delete / import
  // ==========================================================================

  /// Installs a single SKILL.md into the global root under [name]/SKILL.md.
  ///
  /// Fail-fast order (never leaves a half-written skill): name regex → full
  /// document parse (name must equal folder) → containment in root → exists
  /// gate (a real SKILL.md, not an empty folder) → confirm → write.
  static Future<InstallResult> installSkill({
    required String name,
    required String content,
    bool confirm = false,
    SkillInstallSource source = SkillInstallSource.manual,
    String? globalRoot,
  }) async {
    if (!SkillParser.isValidSkillName(name)) {
      return InstallResult.failure('invalid_name');
    }
    final dirName = name;
    final parsed = SkillParser.parseSkillFileContent(
      content,
      directoryName: dirName,
      filePath: '$dirName/SKILL.md',
    );
    if (parsed == null) return InstallResult.failure('invalid_skill');

    final root = globalRoot ?? await globalSkillsRoot();
    final folder = Directory('$root/$name');
    if (!_isInsideRoot(root, folder.path)) {
      return InstallResult.failure('invalid_path');
    }
    final target = File('${folder.path}/SKILL.md');
    String stampedContent;
    try {
      if (target.existsSync() &&
          _fileNameOf(target.path).toLowerCase() ==
              SkillParser.skillFileName.toLowerCase()) {
        if (!confirm) return InstallResult.existsConflict();
      }
      folder.createSync(recursive: true);
      stampedContent = stampProvenance(content, source);
      await target.writeAsString(stampedContent, flush: true);
    } catch (e) {
      return InstallResult.failure('write_failed: $e');
    }
    final saved = SkillParser.parseSkillFileContent(
      stampedContent,
      directoryName: name,
      filePath: target.path,
      scope: SkillScope.global,
      fileCount: 1,
    );
    if (saved == null) return InstallResult.failure('write_failed');
    return InstallResult.success(saved);
  }

  /// Installs a whole skill folder (GitHub download / folder import).
  ///
  /// All files land in a unique temp dir first, then rename into place with
  /// bounded Windows EPERM/EBUSY backoff; overwrite moves the old folder
  /// aside and rolls back on failure — a skill is installed completely or
  /// not at all (a half skill loads, advertises itself, and points at
  /// silently dropped attachments).
  static Future<InstallResult> installSkillMulti({
    required String name,
    required Map<String, String> files,
    bool confirm = false,
    SkillInstallSource source = SkillInstallSource.manual,
    String? globalRoot,
  }) async {
    if (!SkillParser.isValidSkillName(name)) {
      return InstallResult.failure('invalid_name');
    }
    final skillMd = files.entries
        .where((e) => e.key.toLowerCase() == 'skill.md')
        .map((e) => e.value)
        .firstOrNull;
    if (skillMd == null) return InstallResult.failure('missing_skill_md');
    final parsed = SkillParser.parseSkillFileContent(
      skillMd,
      directoryName: name,
      filePath: '$name/SKILL.md',
    );
    if (parsed == null) return InstallResult.failure('invalid_skill');

    final root = globalRoot ?? await globalSkillsRoot();
    final folder = Directory('$root/$name');
    if (!_isInsideRoot(root, folder.path)) {
      return InstallResult.failure('invalid_path');
    }
    final hasExistingSkill = _skillFileIn(folder.path) != null;
    if (hasExistingSkill && !confirm) {
      return InstallResult.existsConflict();
    }
    // Validate EVERY relative path before touching the filesystem — an
    // early return below the temp-dir creation would skip the catch's temp
    // cleanup and leak a `.{name}_install_*` directory into the shared root.
    for (final key in files.keys) {
      if (!isSafeRelPath(key)) {
        return InstallResult.failure('unsafe_path: $key');
      }
    }
    // Stamp once up front: the provenance metadata lives both on disk and in
    // the SkillDefinition we return (parse of the raw text would lose it).
    final stampedSkillMd = stampProvenance(skillMd, source);

    Directory? tempDir;
    Directory? backupDir;
    try {
      final parent = folder.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      tempDir = await parent.createTemp('.${name}_install_');
      for (final entry in files.entries) {
        final target = File(
          '${tempDir.path}/${entry.key.replaceAll('/', Platform.pathSeparator)}',
        );
        await target.parent.create(recursive: true);
        final content = entry.key.toLowerCase() == 'skill.md'
            ? stampedSkillMd
            : entry.value;
        await target.writeAsString(content, flush: true);
      }

      var backupCreated = false;
      if (folder.existsSync()) {
        // Move the old folder aside BEFORE the rename-into-place — Dart's
        // Directory.rename on Windows throws PathExistsException when the
        // target exists (no REPLACE_EXISTING semantics for directories), so
        // the target must be vacated first AND the backup path must not
        // pre-exist (createTemp would create it — use a unique free path).
        // Rollback restores it on failure.
        backupDir = _uniqueSiblingPath(parent, '.${name}_old_');
        backupCreated = true;
        await _renameWithRetry(folder, backupDir);
      }
      try {
        // Flow analysis proves tempDir is non-null here (assigned above).
        await _renameWithRetry(tempDir, folder);
        tempDir = null; // moved into place
      } catch (_) {
        // Roll back: restore the old folder before reporting failure.
        if (backupCreated) {
          try {
            await _renameWithRetry(backupDir!, folder);
          } catch (_) {}
        }
        rethrow;
      }
      try {
        if (backupCreated) {
          final backup = backupDir;
          if (backup != null && backup.existsSync()) {
            backup.deleteSync(recursive: true);
          }
        }
      } catch (_) {}
    } catch (e) {
      // Best-effort temp cleanup.
      try {
        tempDir?.deleteSync(recursive: true);
      } catch (_) {}
      return InstallResult.failure('install_failed: $e');
    }

    final saved = SkillParser.parseSkillFileContent(
      stampedSkillMd,
      directoryName: name,
      filePath: '${folder.path}/SKILL.md',
      scope: SkillScope.global,
      fileCount: countSkillFiles(folder.path),
    );
    if (saved == null) return InstallResult.failure('write_failed');
    return InstallResult.success(saved);
  }

  /// Deletes a GLOBAL skill folder. Allowed on mobile only — the desktop
  /// `~/.agents/skills/` directory is shared with Claude Code / Anybuff, so
  /// removal there is the user's manual job (UI shows guidance instead).
  static Future<DeleteResult> deleteSkill(
    String name, {
    required bool mobilePlatform,
    String? globalRoot,
  }) async {
    if (!mobilePlatform) {
      return const DeleteResult(ok: false, error: 'notSupported');
    }
    if (!SkillParser.isValidSkillName(name)) {
      return DeleteResult(ok: false, error: 'invalid_name');
    }
    final root = globalRoot ?? await globalSkillsRoot();
    final folder = Directory('$root/$name');
    if (!_isInsideRoot(root, folder.path)) {
      return DeleteResult(ok: false, error: 'invalid_path');
    }
    if (!_isInstalledSkillDir(folder.path)) {
      // Not an installed skill directory (root itself, unrelated folder…).
      return DeleteResult(ok: false, error: 'not_a_skill');
    }
    try {
      await folder.delete(recursive: true);
    } catch (e) {
      return DeleteResult(ok: false, error: 'delete_failed: $e');
    }
    return DeleteResult.success();
  }

  /// Imports a local `.md` file (or, when it sits inside a skill folder with
  /// attachments, the whole folder after `confirmFolder`).
  static Future<ImportResult> importSkillFile({
    required String sourcePath,
    bool confirm = false,
    bool confirmFolder = false,
    String? globalRoot,
  }) async {
    final file = File(sourcePath);
    if (!file.existsSync()) return ImportResult.failure('file_not_found');
    String content;
    try {
      content = await file.readAsString();
    } catch (e) {
      return ImportResult.failure('read_failed: $e');
    }
    final name = SkillParser.extractSkillName(content);
    if (name == null || !SkillParser.isValidSkillName(name)) {
      return ImportResult.failure('invalid_skill');
    }

    // Folder awareness (desktop): a picked <skill>/SKILL.md with sibling
    // attachments installs the whole folder — but only after the user sees
    // the file list and confirms.
    final parentDir = file.parent;
    final parentName = _fileNameOf(parentDir.path);
    final attachments = <String, String>{};
    if (parentName == name) {
      final files = _collectFolderFiles(parentDir.path, relativeTo: parentDir.path);
      if (files.length > 1) {
        if (!confirmFolder) {
          return ImportResult.confirmFolder(files.keys.toList(growable: false)..sort());
        }
        for (final entry in files.entries) {
          try {
            attachments[entry.key] = await File(entry.value).readAsString();
          } catch (_) {
            // Unreadable attachment — skip rather than abort the import.
          }
        }
      }
    }

    if (attachments.isNotEmpty) {
      final install = await installSkillMulti(
        name: name,
        files: attachments,
        confirm: confirm,
        source: SkillInstallSource.file,
        globalRoot: globalRoot,
      );
      if (!install.ok) {
        return ImportResult(
          ok: false,
          exists: install.exists,
          error: install.error,
        );
      }
      return ImportResult.success(install.skill!);
    }
    final install = await installSkill(
      name: name,
      content: content,
      confirm: confirm,
      source: SkillInstallSource.file,
      globalRoot: globalRoot,
    );
    if (!install.ok) {
      return ImportResult(
        ok: false,
        exists: install.exists,
        error: install.error,
      );
    }
    return ImportResult.success(install.skill!);
  }

  /// Counts files in a skill folder (any depth) — no symlink following, and
  /// `.git` / `node_modules` are skipped (Anybuff `scanSkillFolder`).
  static int countSkillFiles(String skillDir) {
    var count = 0;
    void walk(String dirPath) {
      Directory dir;
      try {
        dir = Directory(dirPath);
        if (!dir.existsSync()) return;
        for (final e in dir.listSync(followLinks: false)) {
          final name = _fileNameOf(e.path);
          if (e is Directory) {
            if (name == '.git' || name == 'node_modules') continue;
            walk(e.path);
          } else if (e is File) {
            count++;
          }
        }
      } catch (_) {}
    }

    walk(skillDir);
    return count;
  }

  /// Pure-text provenance stamp into the frontmatter `metadata:` block (no
  /// YAML round-trip — the rest of the document stays byte-identical).
  /// Best-effort: any parse hiccup returns the original content.
  static String stampProvenance(String content, SkillInstallSource source) {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final sourceLine = '  source: ${source.value}';
      final installedLine = '  installedAt: $now';
      final lines = LineSplitter.split(content).toList();
      if (lines.isEmpty || lines.first.trim() != '---') return content;

      // Find the frontmatter end and any existing metadata block bounds.
      var fmEnd = -1;
      var metadataStart = -1;
      var metadataEndExclusive = -1;
      for (var i = 1; i < lines.length; i++) {
        final t = lines[i].trim();
        if (t == '---') {
          fmEnd = i;
          break;
        }
        if (!lines[i].startsWith(' ') &&
            !lines[i].startsWith('\t') &&
            t.startsWith('metadata:')) {
          metadataStart = i;
        } else if (metadataStart >= 0 && metadataEndExclusive < 0) {
          if (t.isNotEmpty && !lines[i].startsWith(' ') && !lines[i].startsWith('\t')) {
            metadataEndExclusive = i;
          }
        }
      }
      if (fmEnd < 0) return content;

      if (metadataStart < 0) {
        lines.insert(fmEnd, 'metadata:');
        lines.insert(fmEnd + 1, sourceLine);
        lines.insert(fmEnd + 2, installedLine);
      } else {
        final end = (metadataEndExclusive < 0 ? fmEnd : metadataEndExclusive);
        // Replace / insert source + installedAt inside the metadata block.
        var sourceIdx = -1;
        var installedIdx = -1;
        for (var i = metadataStart + 1; i < end; i++) {
          final t = lines[i].trim();
          if (t.startsWith('source:')) sourceIdx = i;
          if (t.startsWith('installedAt:')) installedIdx = i;
        }
        if (sourceIdx >= 0) {
          lines[sourceIdx] = sourceLine;
        } else {
          lines.insert(end, sourceLine);
          if (installedIdx >= 0) installedIdx++;
        }
        final end2 = (metadataEndExclusive < 0 ? fmEnd + 3 : metadataEndExclusive + 1);
        var installedIdx2 = -1;
        for (var i = metadataStart + 1; i < end2 && i < lines.length; i++) {
          final t = lines[i].trim();
          if (t.startsWith('installedAt:')) installedIdx2 = i;
        }
        if (installedIdx2 >= 0) {
          lines[installedIdx2] = installedLine;
        } else {
          lines.insert(end2, installedLine);
        }
      }
      return '${lines.join('\n')}\n';
    } catch (_) {
      return content;
    }
  }

  // ==========================================================================
  // Path helpers
  // ==========================================================================

  /// Containment check — [candidate] must be inside [root] (defense in depth
  /// alongside name validation; mirrors resolveSafePath's spirit).
  static bool _isInsideRoot(String root, String candidate) {
    final normalizedRoot = _normalize(root);
    final normalizedCandidate = _normalize(candidate);
    if (normalizedCandidate == normalizedRoot) return false;
    return normalizedCandidate.startsWith(normalizedRoot);
  }

  /// Repo-relative path whitelist: no `..`, absolute paths, backslashes, or
  /// `:` (Windows ADS). Used by the GitHub downloader and multi-install.
  static bool isSafeRelPath(String path) {
    if (path.isEmpty) return false;
    if (path.contains('\\')) return false;
    if (path.contains(':')) return false;
    if (path.startsWith('/')) return false;
    if (path.startsWith('~')) return false;
    for (final seg in path.split('/')) {
      if (seg.isEmpty || seg == '.' || seg == '..') return false;
    }
    return true;
  }

  static String _normalize(String path) {
    var p = path.replaceAll('\\', '/');
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  static String _fileNameOf(String path) {
    final p = _normalize(path);
    final idx = p.lastIndexOf('/');
    return idx < 0 ? p : p.substring(idx + 1);
  }

  static String _parentOf(String path) {
    final p = _normalize(path);
    final idx = p.lastIndexOf('/');
    return idx <= 0 ? p : p.substring(0, idx);
  }

  /// Collects all files under [root] as relative POSIX paths → absolute.
  static Map<String, String> _collectFolderFiles(
    String dirPath, {
    required String relativeTo,
  }) {
    final out = <String, String>{};
    void walk(String dir) {
      Directory d;
      try {
        d = Directory(dir);
        if (!d.existsSync()) return;
        for (final e in d.listSync(followLinks: false)) {
          final name = _fileNameOf(e.path);
          if (e is Directory) {
            if (name == '.git' || name == 'node_modules') continue;
            walk(e.path);
          } else if (e is File) {
            final rel = _normalize(e.path)
                .substring(_normalize(relativeTo).length + 1)
                .replaceAll('\\', '/');
            out[rel] = e.path;
          }
        }
      } catch (_) {}
    }

    walk(dirPath);
    return out;
  }

  /// A unique sibling directory path that does NOT exist yet — renaming onto
  /// an existing directory fails on Windows, so backups need a free target.
  static Directory _uniqueSiblingPath(Directory parent, String prefix) {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    for (var i = 0; i < 100; i++) {
      final candidate = Directory('${parent.path}/$prefix${stamp}_$i');
      if (!candidate.existsSync()) return candidate;
    }
    return Directory('${parent.path}/$prefix${stamp}_fallback');
  }

  /// Bounded rename with backoff for Windows EPERM/EBUSY (AV / indexer lock),
  /// same semantics as §3.14's renameWithRetry.
  static Future<void> _renameWithRetry(
    FileSystemEntity from,
    FileSystemEntity to,
  ) async {
    const attempts = 5;
    var delayMs = 50;
    for (var i = 0; i < attempts; i++) {
      try {
        await from.rename(to.path);
        return;
      } on FileSystemException catch (e) {
        final code = e.osError?.errorCode ?? 0;
        final transient = code == 5 /* EPERM-ACCESS */ ||
            code == 32 /* EBUSY/SHARING */ ||
            code == 33 /* ELOCK */;
        if (!transient || i == attempts - 1) rethrow;
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        delayMs *= 2;
      }
    }
  }

  /// True when [path] exists as a directory containing a SKILL.md —
  /// guards deleteSkill against removing unrelated folders.
  static bool _isInstalledSkillDir(String path) {
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) return false;
      for (final e in dir.listSync(followLinks: false)) {
        if (e is File &&
            _fileNameOf(e.path).toLowerCase() ==
                SkillParser.skillFileName.toLowerCase()) {
          return true;
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }
}

/// firstOrNull shim (collection package not imported here).
extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
