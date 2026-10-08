// GitHub skill downloader (PLAN_AGENT_SKILLS.md §3.4).
//
// Two-step UX: list the repo's skill folders (folders directly containing a
// SKILL.md) → download one whole folder after the user picks it. SKILL.md is
// fetched first because its frontmatter name is the install key and the
// exists-gate must run before the remaining files are downloaded (bandwidth +
// rate-limit savings).
//
// Security (plan §11): every request URL is built from exactly two constant
// hosts + regex-validated owner/repo; `_ghFetch` re-checks the host (defense
// in depth). Every repo-relative path passes [SkillService.isSafeRelPath];
// one unsafe path aborts the whole download (never a silent skip). Executable
// extensions are skipped — meaningless for a skill and a malware vector.
//
// No file-count/byte caps on purpose (Anybuff 2026-10-03 decision): a cap
// produces half-installed skills, which are the most confusing failure mode.
// The candidate list shows the file count and the user decides.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../models/skill.dart';
import 'skill_parser.dart';
import 'skill_service.dart';

class GithubRepo {
  const GithubRepo({required this.owner, required this.repo});

  final String owner;
  final String repo;

  @override
  String toString() => '$owner/$repo';
}

class GithubSkillService {
  GithubSkillService._();

  static const String apiHost = 'api.github.com';
  static const String rawHost = 'raw.githubusercontent.com';
  static const String _userAgent = 'OmniChat';
  static const Duration _timeout = Duration(seconds: 15);

  /// Test seam: when set, all requests go through this client.
  static http.Client? debugHttpClient;

  static final RegExp _ownerPattern = RegExp(r'^[A-Za-z0-9-]{1,39}$');
  static final RegExp _repoPattern = RegExp(r'^[A-Za-z0-9._-]{1,100}$');

  /// Executables are meaningless for skills and a malware vector (§11).
  static const Set<String> dangerousExtensions = {
    'exe', 'apk', 'bat', 'cmd', 'ps1', 'vbs', 'dll', 'so', 'com', 'scr',
    'msi', 'sh',
  };

  /// Parses `owner/repo`, `github.com/owner/repo` or a full https URL.
  /// Any other host is rejected by NAME — the input never touches the network.
  static GithubRepo? parseGithubRepo(String input) {
    var s = input.trim();
    if (s.isEmpty) return null;
    s = s.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
    s = s.replaceFirst(RegExp(r'\.git$', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'/+$'), '');
    if (s.isEmpty) return null;
    final parts = s.split('/');
    if (parts.length == 3) {
      final host = parts[0].toLowerCase();
      if (host != 'github.com' && host != 'www.github.com') return null;
      parts.removeAt(0);
    } else if (parts.length != 2) {
      return null;
    }
    final owner = parts[0];
    final repo = parts[1];
    if (!_ownerPattern.hasMatch(owner)) return null;
    if (!_repoPattern.hasMatch(repo)) return null;
    if (owner.startsWith('-') || owner.endsWith('-')) return null;
    if (repo.startsWith('-') || repo.startsWith('.')) return null;
    if (repo == '.' || repo == '..') return null;
    return GithubRepo(owner: owner, repo: repo);
  }

  /// Lists every folder in [repoInput] that directly contains a SKILL.md.
  static Future<ListGithubSkillsResult> listGithubSkills(
    String repoInput,
  ) async {
    final repo = parseGithubRepo(repoInput);
    if (repo == null) {
      return ListGithubSkillsResult.failure('invalid_repo');
    }
    final trees = await _fetchTrees(repo);
    if (trees.error != null) {
      return ListGithubSkillsResult.failure(trees.error!);
    }
    final candidates = _findSkillFolders(trees.entries, repo.repo);
    if (candidates.isEmpty) {
      return ListGithubSkillsResult.failure('no_skills');
    }
    return ListGithubSkillsResult(
      ok: true,
      candidates: candidates,
      truncated: trees.truncated,
    );
  }

  /// Downloads one skill folder and installs it into the global root.
  static Future<DownloadGithubSkillResult> downloadGithubSkill({
    required String repoInput,
    required String path,
    bool confirm = false,
    String? globalRoot,
  }) async {
    final repo = parseGithubRepo(repoInput);
    if (repo == null) {
      return DownloadGithubSkillResult.failure('invalid_repo');
    }
    if (path.isNotEmpty && !SkillService.isSafeRelPath(path)) {
      return DownloadGithubSkillResult.failure('unsafe_path');
    }
    final trees = await _fetchTrees(repo);
    if (trees.error != null) {
      return DownloadGithubSkillResult.failure(trees.error!);
    }
    final prefix = path.isEmpty ? '' : '$path/';
    final folderEntries = trees.entries
        .where((e) => e.type == 'blob' && e.path.startsWith(prefix))
        .toList(growable: false);
    if (folderEntries.isEmpty) {
      return DownloadGithubSkillResult.failure('not_found');
    }

    final skillMdEntry = folderEntries.firstWhere(
      (e) => _baseName(e.path).toLowerCase() ==
          SkillParser.skillFileName.toLowerCase(),
      orElse: () => const _TreeEntry(path: '', type: ''),
    );
    if (skillMdEntry.path.isEmpty) {
      return DownloadGithubSkillResult.failure('no_skill_md');
    }

    // 1) SKILL.md first — its frontmatter name is the install key.
    final skillMdResponse = await _fetchRaw(repo, skillMdEntry.path);
    if (skillMdResponse.error != null) {
      return DownloadGithubSkillResult.failure(skillMdResponse.error!);
    }
    final skillMdBytes = skillMdResponse.bodyBytes!;
    // Frontmatter is text by contract; tolerate odd encodings here and let
    // the installer rewrite SKILL.md as UTF-8 (same rule as installSkillMulti).
    final skillMdContent =
        utf8.decode(skillMdBytes, allowMalformed: true);
    final name = SkillParser.extractSkillName(skillMdContent);
    if (name == null || !SkillParser.isValidSkillName(name)) {
      return DownloadGithubSkillResult.failure('invalid_skill');
    }

    // 2) Exists gate BEFORE downloading the rest.
    final root = globalRoot ?? await SkillService.globalSkillsRoot();
    final targetFile = File('$root/$name/SKILL.md');
    if (targetFile.existsSync() && !confirm) {
      return DownloadGithubSkillResult.existsConflict();
    }

    // 3) Download every remaining blob (dangerous extensions skipped,
    //    unsafe paths abort the whole download). Bodies stay bytes: a
    //    binary reference (image/font/PDF) must survive the round-trip —
    //    the pre-fix utf8.decode(allowMalformed) path wrote replacement
    //    characters over every non-text attachment.
    final files = <String, List<int>>{
      _relPath(skillMdEntry.path, prefix): skillMdBytes,
    };
    for (final entry in folderEntries) {
      if (entry.path == skillMdEntry.path) continue;
      final rel = _relPath(entry.path, prefix);
      if (!SkillService.isSafeRelPath(rel)) {
        return DownloadGithubSkillResult.failure('unsafe_path');
      }
      if (dangerousExtensions.contains(_extensionOf(rel))) continue;
      final response = await _fetchRaw(repo, entry.path);
      if (response.error != null) {
        // Any failure aborts — never leave half a skill behind.
        return DownloadGithubSkillResult.failure(response.error!);
      }
      files[rel] = response.bodyBytes!;
    }

    final install = await SkillService.installSkillMultiBytes(
      name: name,
      files: files,
      confirm: confirm,
      source: SkillInstallSource.github,
      globalRoot: root,
    );
    if (!install.ok) {
      return DownloadGithubSkillResult(
        ok: false,
        exists: install.exists,
        error: install.error,
      );
    }
    return DownloadGithubSkillResult.success(install.skill!);
  }

  // ==========================================================================
  // Internals
  // ==========================================================================

  static Future<_TreesResult> _fetchTrees(GithubRepo repo) async {
    final uri = Uri.https(
      apiHost,
      '/repos/${repo.owner}/${repo.repo}/git/trees/HEAD',
      {'recursive': '1'},
    );
    final response = await _ghFetch(uri);
    if (response == null) return const _TreesResult(error: 'network');
    if (response.statusCode == 404) {
      return const _TreesResult(error: 'not_found');
    }
    if (response.statusCode == 403 || response.statusCode == 429) {
      final remaining = response.headers['x-ratelimit-remaining'];
      if (remaining == '0' || response.statusCode == 429) {
        return const _TreesResult(error: 'rate_limit');
      }
      return const _TreesResult(error: 'forbidden');
    }
    if (response.statusCode != 200) {
      return const _TreesResult(error: 'network');
    }
    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final tree = (json['tree'] as List?) ?? const [];
      final entries = <_TreeEntry>[];
      for (final item in tree) {
        if (item is! Map) continue;
        final path = (item['path'] ?? '').toString();
        final type = (item['type'] ?? '').toString();
        if (path.isEmpty || type.isEmpty) continue;
        entries.add(_TreeEntry(path: path, type: type));
      }
      return _TreesResult(
        entries: entries,
        truncated: json['truncated'] == true,
      );
    } catch (_) {
      return const _TreesResult(error: 'parse_failed');
    }
  }

  static List<GithubSkillCandidate> _findSkillFolders(
    List<_TreeEntry> entries,
    String repoName,
  ) {
    final folders = <String, int>{};
    for (final e in entries) {
      if (e.type != 'blob') continue;
      if (_baseName(e.path).toLowerCase() !=
          SkillParser.skillFileName.toLowerCase()) {
        continue;
      }
      final idx = e.path.lastIndexOf('/');
      final folder = idx < 0 ? '' : e.path.substring(0, idx);
      folders[folder] = (folders[folder] ?? 0) + 1;
    }
    final out = <GithubSkillCandidate>[];
    folders.forEach((folder, _) {
      final prefix = folder.isEmpty ? '' : '$folder/';
      var fileCount = 0;
      for (final e in entries) {
        if (e.type != 'blob') continue;
        if (!e.path.startsWith(prefix)) continue;
        if (prefix.isNotEmpty && e.path == folder) continue;
        fileCount++;
      }
      out.add(
        GithubSkillCandidate(
          name: folder.isEmpty ? repoName : _baseName(folder),
          path: folder,
          fileCount: fileCount,
        ),
      );
    });
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  static Future<_RawResult> _fetchRaw(GithubRepo repo, String path) async {
    final uri = Uri.https(rawHost, '/${repo.owner}/${repo.repo}/HEAD/$path');
    final response = await _ghFetch(uri);
    if (response == null) return const _RawResult(error: 'network');
    if (response.statusCode == 404) return const _RawResult(error: 'not_found');
    if (response.statusCode != 200) return const _RawResult(error: 'network');
    return _RawResult(bodyBytes: response.bodyBytes);
  }

  /// Single fetch entry point — re-validates the host (defense in depth) and
  /// applies the timeout/user-agent contract.
  static Future<http.Response?> _ghFetch(Uri uri) async {
    if (uri.host != apiHost && uri.host != rawHost) return null;
    final client = debugHttpClient ?? http.Client();
    try {
      final request = http.Request('GET', uri)
        ..headers['User-Agent'] = _userAgent
        ..headers['Accept'] = 'application/vnd.github+json';
      final streamed = await client.send(request).timeout(_timeout);
      return await http.Response.fromStream(streamed).timeout(_timeout);
    } catch (_) {
      return null;
    } finally {
      if (debugHttpClient == null) client.close();
    }
  }

  static String _baseName(String path) {
    final idx = path.lastIndexOf('/');
    return idx < 0 ? path : path.substring(idx + 1);
  }

  static String _relPath(String path, String prefix) =>
      prefix.isEmpty ? path : path.substring(prefix.length);

  static String _extensionOf(String relPath) {
    final name = _baseName(relPath).toLowerCase();
    final idx = name.lastIndexOf('.');
    if (idx <= 0 || idx == name.length - 1) return '';
    return name.substring(idx + 1);
  }
}

class _TreeEntry {
  const _TreeEntry({required this.path, required this.type});

  final String path;
  final String type;
}

class _TreesResult {
  const _TreesResult({
    this.entries = const <_TreeEntry>[],
    this.truncated = false,
    this.error,
  });

  final List<_TreeEntry> entries;
  final bool truncated;
  final String? error;
}

class _RawResult {
  const _RawResult({this.bodyBytes, this.error});

  final List<int>? bodyBytes;
  final String? error;
}
