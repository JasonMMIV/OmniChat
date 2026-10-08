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

  /// Text variant of [installSkillMultiBytes] for callers that already hold
  /// UTF-8 text. Attachments that may be binary (PNG/PDF/font/zip references)
  /// must go through the bytes variant — a text round-trip mangles them.
  static Future<InstallResult> installSkillMulti({
    required String name,
    required Map<String, String> files,
    bool confirm = false,
    SkillInstallSource source = SkillInstallSource.manual,
    String? globalRoot,
  }) {
    return installSkillMultiBytes(
      name: name,
      files: {
        for (final entry in files.entries) entry.key: utf8.encode(entry.value),
      },
      confirm: confirm,
      source: source,
      globalRoot: globalRoot,
    );
  }

  /// Installs a whole skill folder (GitHub download / folder import).
  ///
  /// All files land in a unique temp dir first, then rename into place with
  /// bounded Windows EPERM/EBUSY backoff; overwrite moves the old folder
  /// aside and rolls back on failure — a skill is installed completely or
  /// not at all (a half skill loads, advertises itself, and points at
  /// silently dropped attachments).
  ///
  /// Every attachment is written byte-for-byte (2026-10-08): skill folders
  /// carry binary references (images, PDFs, fonts, archives), and the old
  /// text-only payload dropped them on import and corrupted them on GitHub
  /// download.
  static Future<InstallResult> installSkillMultiBytes({
    required String name,
    required Map<String, List<int>> files,
    bool confirm = false,
    SkillInstallSource source = SkillInstallSource.manual,
    String? globalRoot,
  }) async {
    if (!SkillParser.isValidSkillName(name)) {
      return InstallResult.failure('invalid_name');
    }
    final skillMdBytes = files.entries
        .where((e) => e.key.toLowerCase() == 'skill.md')
        .map((e) => e.value)
        .firstOrNull;
    if (skillMdBytes == null) return InstallResult.failure('missing_skill_md');
    // SKILL.md is text by contract; tolerate odd encodings rather than
    // refusing the install (provenance stamping rewrites it as UTF-8).
    final skillMd = utf8.decode(skillMdBytes, allowMalformed: true);
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
        final payload = entry.key.toLowerCase() == 'skill.md'
            ? utf8.encode(stampedSkillMd)
            : entry.value;
        await target.writeAsBytes(payload, flush: true);
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

  /// Test seam for [folderImportSupported] — never set in production.
  static bool? debugFolderImportOverride;

  /// Folder-aware *file* import needs a real on-disk skill folder. The desktop
  /// dialog returns real paths outright; on Android the picker's cache copy is
  /// flat and its parent belongs to other picks (or other apps), so the answer
  /// comes from the ORIGINAL document URI instead
  /// ([androidFolderPathFromDocumentUri], passed in as `sourceIdentifier`) —
  /// and is false outright when that cannot be resolved. iOS has no equivalent
  /// here, so its file route stays single-file. Anybuff declares the identical
  /// capability (`pickedFilesShareFolder: false`) for Android for the same
  /// reason. Android recovers the real folder through the original document
  /// URI; iOS keeps the explicit single-file note instead.
  static bool get folderImportSupported =>
      debugFolderImportOverride ??
      !(Platform.isAndroid || Platform.isIOS);

  /// Test seam for the external-storage root [androidFolderPathFromDocumentUri]
  /// maps the `primary` volume onto — never set in production.
  static String? debugAndroidExternalStorageRoot;

  static String get _androidExternalStorageRoot =>
      debugAndroidExternalStorageRoot ?? '/storage/emulated/0';

  /// The real folder a picked document belongs to, or null when this pick
  /// cannot be trusted to carry one: desktop answers with the picked file's
  /// own folder, mobile only when the original document URI resolves to a real
  /// directory (see [androidFolderPathFromDocumentUri]).
  static String? _importFolderForPick(File pickedFile, String? sourceIdentifier) {
    final String? folder;
    if (folderImportSupported) {
      folder = pickedFile.parent.path;
    } else if (sourceIdentifier == null || sourceIdentifier.isEmpty) {
      return null;
    } else {
      folder = androidFolderPathFromDocumentUri(sourceIdentifier);
    }
    if (folder == null) return null;
    // A skills ROOT is a container of skills, never a skill itself: a document
    // sitting directly inside one (`<root>/SKILL.md`) must not turn every
    // installed skill's files into one new skill folder (Anybuff refuses the
    // same shape). Applies to both routes — the folder list would otherwise
    // look legitimate, and the install could overwrite the very skill it swept.
    if (_isSkillsRootDocument(folder)) return null;
    try {
      if (!Directory(folder).existsSync()) return null;
    } catch (_) {
      return null;
    }
    return folder;
  }

  /// Whether a picked document can bring its folder along ([importSkillFile]'s
  /// folder gate). The UI asks this to warn when a mobile pick will install the
  /// SKILL.md alone — it must mirror [_importFolderForPick] exactly (guards
  /// included), or a pick the service silently refuses would still look like a
  /// clean success.
  static bool pickCarriesItsFolder(String sourcePath, String? sourceIdentifier) {
    if (sourcePath.isEmpty) return false;
    return _importFolderForPick(File(sourcePath), sourceIdentifier) != null;
  }

  /// True when [skillDirPath] is a skills root rather than a skill folder —
  /// i.e. its parent is the convention container (`.agents` / `.claude`).
  static bool _isSkillsRootDocument(String skillDirPath) {
    final parent = _fileNameOf(_parentOf(skillDirPath));
    return parent == '.agents' || parent == '.claude';
  }

  /// Maps an Android SAF document URI (file_picker's `PlatformFile.identifier`)
  /// to the real directory of the picked file, or null when the pick cannot be
  /// resolved.
  ///
  /// Why this exists: Android's file picker copies every pick FLAT into the app
  /// cache (`cacheDir/file_picker/<stamp>/<name>`), so a cache parent is a
  /// picker staging area, not the skill folder — scanning it would sweep
  /// unrelated picks into the skill ([folderImportSupported]). The ORIGINAL
  /// document URI is still handed to Dart, and for the built-in "Files"
  /// provider its document id carries the volume plus the real path
  /// (`primary:Download/my-skill/SKILL.md`), readable directly because the app
  /// already holds all-files access for its workspace picker
  /// (`MANAGE_EXTERNAL_STORAGE`). That gives Android the desktop gesture back:
  /// pick `SKILL.md` → the whole folder comes with it.
  ///
  /// Deliberately narrow (fail-safe): only the external-storage provider is
  /// understood. Cloud providers and the Downloads provider hand back shapes
  /// (`downloads`, `msf:…`, `raw:…`) whose path mapping is a lie, and reading
  /// the wrong directory would install unrelated files into a skill — anything
  /// not understood returns null and the caller keeps the single-file import.
  static String? androidFolderPathFromDocumentUri(String identifier) {
    final Uri uri;
    try {
      uri = Uri.parse(identifier);
    } catch (_) {
      return null;
    }
    if (uri.scheme != 'content') return null;
    // `pathSegments` is percent-decoded, so segment 1 is the document id —
    // 'primary:Download/my-skill/SKILL.md' or 'raw:/storage/…/SKILL.md'.
    final segments = uri.pathSegments;
    if (segments.length < 2) return null;
    final isTree = segments.first == 'tree';
    final docId = segments[1];
    // A docId is provider data, not a path this app controls: a `..` segment
    // must be REFUSED rather than resolved. The app holds all-files access, so
    // a traversal would read fine and the caller would install whatever it
    // found — outside the volume the picker vouched for.
    if (_hasParentSegment(docId)) return null;

    if (uri.authority == _externalStorageAuthority) {
      final sep = docId.indexOf(':');
      if (sep <= 0 || sep == docId.length - 1) return null;
      final volumeId = docId.substring(0, sep);
      final relative = docId.substring(sep + 1);
      final String volumeRoot;
      if (volumeId.toLowerCase() == 'primary') {
        volumeRoot = _androidExternalStorageRoot;
      } else if (_removableVolumeId.hasMatch(volumeId)) {
        volumeRoot = '/storage/$volumeId'; // removable volume (SD card)
      } else {
        return null; // pseudo-volumes: 'msf', 'raw'…
      }
      // Normalized once here so both shapes come back in the POSIX shape the
      // rest of the service compares and joins with (a Windows test seam would
      // otherwise leak its separators into the returned path).
      final full = _normalize('$volumeRoot/$relative');
      // A `/document/` id names the picked FILE → its folder; a `/tree/` id
      // names the folder itself (the folder picker's shape).
      final folder = isTree ? full : _parentOf(full);
      // The volume root itself is a container of everything — a document
      // sitting directly on it must not turn the whole volume into one scan.
      return _isInsideRoot(volumeRoot, folder) ? folder : null;
    }

    if (uri.authority == _downloadsAuthority) {
      // AOSP DownloadStorageProvider: a plain file carries `raw:<absolute
      // path>` — the "Downloads" entry of the system picker, which is where a
      // downloaded skill zip usually gets opened from. The other ids it hands
      // out (`msf:`/`msd:` MediaStore-backed files, `downloads` for the root)
      // encode no readable path at all and are refused.
      if (!docId.startsWith('raw:')) return null;
      final absolute = _normalize(docId.substring(4));
      if (!absolute.startsWith('/')) return null;
      final folder = isTree ? absolute : _parentOf(absolute);
      return _isInsideSharedStorage(folder) ? folder : null;
    }

    return null; // any other provider: no trustworthy path mapping
  }

  static const String _externalStorageAuthority =
      'com.android.externalstorage.documents';
  static const String _downloadsAuthority =
      'com.android.providers.downloads.documents';
  static final RegExp _removableVolumeId =
      RegExp(r'^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$');

  /// True when any segment of [docIdOrPath] is `..` (see the traversal rule in
  /// [androidFolderPathFromDocumentUri]).
  static bool _hasParentSegment(String docIdOrPath) {
    for (final segment in docIdOrPath.split('/')) {
      if (segment == '..') return true;
    }
    return false;
  }

  /// True when [path] sits inside a shared-storage volume the app may read:
  /// the primary volume ([_androidExternalStorageRoot]) or a removable one
  /// (`/storage/XXXX-XXXX/…`). The volume root itself stays excluded — it is a
  /// container, never a skill folder.
  static bool _isInsideSharedStorage(String path) {
    final normalized = _normalize(path);
    if (_isInsideRoot(_androidExternalStorageRoot, normalized)) return true;
    // A removable volume (`/storage/XXXX-XXXX/…`) is its own root. The volume
    // id is matched explicitly: taking the third segment as a root on faith
    // would let `/storage/emulated/0` pass as "inside /storage/emulated", i.e.
    // re-admit the very volume root this is meant to exclude.
    final segments = normalized.split('/');
    if (segments.length < 4 || segments.first != '' || segments[1] != 'storage') {
      return false;
    }
    final volumeId = segments[2];
    if (!_removableVolumeId.hasMatch(volumeId)) return false;
    return _isInsideRoot('/storage/$volumeId', normalized);
  }

  /// Imports a local `.md` file (or, when it sits in a folder with sibling
  /// attachments, the whole folder after `confirmFolder`).
  ///
  /// Folder awareness does NOT require folder name == frontmatter name
  /// (2026-10-08): a downloaded zip (`my-skill-main/`) or a hand-made folder
  /// used to defeat that gate and silently install the SKILL.md alone,
  /// dropping every reference file the skill points at. Any sibling file
  /// (outside `.git` / `node_modules` / `__pycache__` / dot-entries) now
  /// triggers the two-step confirm; `skipFolder` imports the picked document
  /// alone for callers that declined it.
  static Future<ImportResult> importSkillFile({
    required String sourcePath,
    bool confirm = false,
    bool confirmFolder = false,
    bool skipFolder = false,
    String? globalRoot,
    String? sourceIdentifier,
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

    final skillDirPath = _importFolderForPick(file, sourceIdentifier);
    if (skillDirPath != null && !skipFolder) {
      // Siblings = the skill folder. The picked file is never one of them:
      // it becomes SKILL.md below, whatever its own name is.
      final parentDir = Directory(skillDirPath);
      final pickedName = _fileNameOf(file.path);
      final siblings = _collectFolderFiles(
        parentDir.path,
        relativeTo: parentDir.path,
      )..remove(pickedName);
      if (siblings.isNotEmpty) {
        if (!confirmFolder) {
          return ImportResult.confirmFolder(
            siblings.keys.toList(growable: false)..sort(),
            name: name,
          );
        }
        // Byte-exact payloads: a binary reference (PNG/PDF/font) is a
        // legitimate attachment, and the pre-fix text read silently
        // dropped every file that was not valid UTF-8 — after the user had
        // already confirmed the full folder list.
        final files = <String, List<int>>{};
        for (final entry in siblings.entries) {
          if (entry.key.toLowerCase() ==
              SkillParser.skillFileName.toLowerCase()) {
            continue; // the picked document wins over a same-named sibling
          }
          try {
            files[entry.key] = await File(entry.value).readAsBytes();
          } catch (e) {
            // Never install a partial folder: a skill pointing at a
            // silently missing reference file is the worst failure mode.
            return ImportResult.failure('read_failed: $e');
          }
        }
        try {
          files[SkillParser.skillFileName] = await file.readAsBytes();
        } catch (e) {
          return ImportResult.failure('read_failed: $e');
        }
        final folderInstall = await installSkillMultiBytes(
          name: name,
          files: files,
          confirm: confirm,
          source: SkillInstallSource.file,
          globalRoot: globalRoot,
        );
        if (!folderInstall.ok) {
          return ImportResult(
            ok: false,
            exists: folderInstall.exists,
            error: folderInstall.error,
          );
        }
        return ImportResult.success(folderInstall.skill!);
      }
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

  /// Imports a picked *folder* as one whole skill (2026-10-08 iOS/Android
  /// review follow-up).
  ///
  /// Why this sits next to [importSkillFile]: a file pick can only be trusted
  /// to carry its own folder where the picker returns real paths, so on mobile
  /// the file route installs SKILL.md alone ([folderImportSupported]) and every
  /// attachment is lost. A folder pick returns the real tree instead, which is
  /// what makes the desktop-grade whole-folder install available on mobile.
  ///
  /// Accepted shapes: `<picked>/SKILL.md` (the picked folder IS the skill) and
  /// a single wrapper level (`my-skill-main/SKILL.md` — a release zip unzipped
  /// in the Files app). Two or more SKILL.md-carrying subfolders is not a
  /// skill but a skills *root*: installing it would sweep every skill into one
  /// folder, so it is refused (Anybuff's ADR-29 guard against picking
  /// `~/.agents`).
  /// Reserved (2026-10-08, second round): no UI offers a folder pick any more
  /// — the file route resolves the real folder on Android, and the Downloads
  /// category is covered by the `raw:` mapping — so nothing in the app calls
  /// this at present. It is kept because it is platform-neutral and already
  /// covered by tests: a folder entry (iOS included, once security-scoped
  /// access is solved) is the natural consumer.
  static Future<ImportResult> importSkillFolder({
    required String folderPath,
    bool confirm = false,
    bool confirmFolder = false,
    String? globalRoot,
  }) async {
    // An empty path must be refused BEFORE touching the filesystem: `File('')`
    // and `Directory('')` resolve against the process working directory, so a
    // blank pick could otherwise read (and install from) wherever the app
    // happens to run.
    final picked = folderPath.trim();
    if (picked.isEmpty || !Directory(picked).existsSync()) {
      return ImportResult.failure('folder_not_found');
    }
    final candidates = _skillFoldersIn(picked);
    if (candidates.isEmpty) return ImportResult.failure('skill_md_not_found');
    if (candidates.length > 1) return ImportResult.failure('multiple_skills');
    final skillDir = candidates.single;

    // A real on-disk folder means the relative paths ARE the skill's own
    // structure — `references/x.md` lands as `references/x.md`, which a
    // flattened mobile file pick can never preserve.
    final collected = _collectFolderFiles(skillDir, relativeTo: skillDir);
    final document = pickSkillDocument(collected.keys);
    if (document == null) return ImportResult.failure('skill_md_not_found');
    final skillKey = document.key;
    final shadowed = document.shadowed;

    String content;
    try {
      content = await File(collected[skillKey]!).readAsString();
    } catch (e) {
      return ImportResult.failure('read_failed: $e');
    }
    final name = SkillParser.extractSkillName(content);
    if (name == null || !SkillParser.isValidSkillName(name)) {
      return ImportResult.failure('invalid_skill');
    }

    // Whatever the picked document is called (`skill.md`, `Skill.md`), it
    // becomes the one name the loader reads — same rule as the file flow.
    final planned = <String>[
      for (final key in collected.keys)
        if (!shadowed.contains(key))
          key == skillKey ? SkillParser.skillFileName : key,
    ]..sort();
    if (planned.length > 1 && !confirmFolder) {
      return ImportResult.confirmFolder(planned, name: name);
    }
    final files = <String, List<int>>{};
    for (final entry in collected.entries) {
      if (shadowed.contains(entry.key)) continue;
      final target = entry.key == skillKey
          ? SkillParser.skillFileName
          : entry.key;
      try {
        files[target] = await File(entry.value).readAsBytes();
      } catch (e) {
        // Never install a partial folder: a skill that points at silently
        // missing reference files is the worst failure mode (file flow rule).
        return ImportResult.failure('read_failed: $e');
      }
    }
    final install = await installSkillMultiBytes(
      name: name,
      files: files,
      confirm: confirm,
      source: SkillInstallSource.file,
      globalRoot: globalRoot,
    );
    if (!install.ok) {
      return ImportResult(
        ok: false,
        exists: install.exists,
        // Carry the name into the overwrite envelope too: the picked folder is
        // often NOT named after the skill (`my-skill-main/`), so a caller that
        // falls back to the folder name would ask the user about the wrong
        // skill.
        pendingName: name,
        error: install.error,
      );
    }
    return ImportResult.success(install.skill!);
  }

  /// Picks the skill document out of a folder's collected keys (`SKILL.md` or
  /// a case variant) and names the variants it shadows, or null when the
  /// folder carries none.
  ///
  /// Case variants inside ONE folder (`SKILL.md` next to `skill.md` — a
  /// copy/paste on a case-insensitive filesystem, a restored backup, or a
  /// hand-made folder) must not install twice: the loader reads whichever it
  /// happens to list first, so the second copy would shadow the stamped
  /// document, and `installSkillMultiBytes` would take the frontmatter name
  /// from the other one. The exact convention name wins; the rest are dropped,
  /// exactly like the file flow drops a same-named sibling. Pure (no IO), so
  /// the rule stays testable on hosts where the case cannot be built on disk.
  static ({String key, Set<String> shadowed})? pickSkillDocument(
    Iterable<String> keys,
  ) {
    final matches = keys
        .where(
          (key) =>
              _fileNameOf(key).toLowerCase() ==
              SkillParser.skillFileName.toLowerCase(),
        )
        .toList(growable: false);
    if (matches.isEmpty) return null;
    final key = matches.firstWhere(
      (k) => _fileNameOf(k) == SkillParser.skillFileName,
      orElse: () => matches.first,
    );
    return (
      key: key,
      shadowed: matches.where((k) => k != key).toSet(),
    );
  }

  /// Skill folders directly inside [folderPath] (depth ≤ 1): the picked folder
  /// itself when it carries a SKILL.md, otherwise its direct subfolders that
  /// do. Doubles as the resolution rule for a folder pick and as the "is this
  /// a skills root?" guard.
  static List<String> _skillFoldersIn(String folderPath) {
    if (_skillFileIn(folderPath) != null) return <String>[folderPath];
    final out = <String>[];
    try {
      final dir = Directory(folderPath);
      if (!dir.existsSync()) return out;
      for (final e in dir.listSync(followLinks: false)) {
        if (e is! Directory) continue;
        final name = _fileNameOf(e.path);
        if (name.startsWith('.')) continue;
        if (name == 'node_modules' || name == '__pycache__') continue;
        if (_skillFileIn(e.path) != null) out.add(e.path);
      }
    } catch (_) {
      return out;
    }
    return out;
  }

  /// Counts files in a skill folder (any depth) — no symlink following, and
  /// `.git` / `node_modules` / `__pycache__` plus dot-entries are skipped
  /// (Anybuff `scanSkillFolder`; the noise list mirrors the import scan so
  /// the badge counts exactly what an import would copy).
  static int countSkillFiles(String skillDir) {
    var count = 0;
    void walk(String dirPath) {
      Directory dir;
      try {
        dir = Directory(dirPath);
        if (!dir.existsSync()) return;
        for (final e in dir.listSync(followLinks: false)) {
          final name = _fileNameOf(e.path);
          if (name.startsWith('.')) continue;
          if (e is Directory) {
            if (name == 'node_modules' || name == '__pycache__') continue;
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
  /// `.git` / `node_modules` / `__pycache__` and dot-entries are skipped so
  /// the confirm list and the copy only carry what belongs to the skill.
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
          if (name.startsWith('.')) continue;
          if (e is Directory) {
            if (name == 'node_modules' || name == '__pycache__') continue;
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
