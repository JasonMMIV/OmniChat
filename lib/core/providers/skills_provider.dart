// Agent Skills state management (PLAN_AGENT_SKILLS.md §4).
//
// Mirrors InstructionInjectionProvider's pattern: ChangeNotifier over a
// service layer. `globalSkills` is what the settings page manages (desktop
// `~/.agents/skills/` — shared with Claude Code / Anybuff, no in-app delete;
// mobile `<appData>/.agents/skills/` — full CRUD). Project skills are
// read-only auto-discovery merged in [skillsForContext].

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/platform_utils.dart';
import '../models/skill.dart';
import '../services/skills/github_skill_service.dart';
import '../services/skills/skill_parser.dart';
import '../services/skills/skill_service.dart';

class SkillsProvider extends ChangeNotifier {
  List<SkillDefinition> _globalSkills = const <SkillDefinition>[];
  bool _loading = false;
  String? _error;

  /// Resolved global root path (null until [initialize] ran).
  String? _globalRootPath;

  /// Last known project-scope skills — used only for the input-bar button
  /// visibility hint. Refreshed at message assembly (see
  /// [noteProjectSkills]) and on menu open.
  List<SkillDefinition> _lastProjectSkills = const <SkillDefinition>[];

  static const String _seededFlagKey = 'skills_example_seeded_v1';

  List<SkillDefinition> get globalSkills =>
      List<SkillDefinition>.unmodifiable(_globalSkills);
  bool get loading => _loading;
  String? get error => _error;

  /// Global root path (desktop home / mobile app data), for UI guidance text.
  String? get globalRootPath => _globalRootPath;

  bool get hasSkills => _globalSkills.isNotEmpty;

  /// Visibility hint for the input-bar skills button (global + last-known
  /// project skills). The popover/sheet refreshes at open time.
  bool get hasAnyKnownSkills =>
      _globalSkills.isNotEmpty || _lastProjectSkills.isNotEmpty;

  Future<void> initialize() async {
    try {
      _globalRootPath = await SkillService.globalSkillsRoot();
      _error = null;
    } catch (e) {
      _error = 'root_resolve_failed: $e';
      notifyListeners();
      return;
    }
    await _cleanupSeededExampleSkill();
    await refresh();
  }

  /// Rescans the global root (page open / install / delete / menu open).
  Future<void> refresh() async {
    _loading = true;
    notifyListeners();
    try {
      final map = SkillService.loadSkills(
        globalRoot: _globalRootPath ?? await SkillService.globalSkillsRoot(),
      );
      _globalSkills = map.values.where((s) => s.scope == SkillScope.global).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      _error = null;
    } catch (e) {
      // Transport/IO error is NOT an empty folder — keep the distinction so
      // the page can render an error row instead of the empty state.
      _error = 'scan_failed: $e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Global + project skills for the current message assembly / menu.
  /// Project layer overrides global on name collisions. Also updates the
  /// last-known project-skill hint for button visibility.
  Map<String, SkillDefinition> skillsForContext(String? workspacePath) {
    final map = SkillService.skillsForContext(
      workspacePath: workspacePath,
      globalRoot: _globalRootPath,
    );
    _lastProjectSkills = map.values
        .where((s) => s.scope == SkillScope.project)
        .toList(growable: false);
    return map;
  }

  /// Updates the last-known project-skill hint for [workspacePath]. Message
  /// assembly calls this each send so the input-bar button gate can see
  /// project-only setups (no global skills). Previously the hint refreshed
  /// only when the menu opened — and opening the menu required a visible
  /// button (the gate reads this very hint), so project-only setups never
  /// got a menu entry. Never throws (the discovery layer swallows unreadable
  /// roots); notifies only when the skill-name set changed.
  void noteProjectSkills(String? workspacePath) {
    // Project layer only — the global half of the gate reads
    // `_globalSkills`; this scan fills the project half.
    final map = SkillService.skillsForContext(
      workspacePath: workspacePath,
      globalRoot: null,
    );
    final next = map.values.toList(growable: false);
    final names = [for (final s in next) s.name]..sort();
    final prevNames = [for (final s in _lastProjectSkills) s.name]..sort();
    // Dedupe on the name set only: this hint is a non-emptiness gate, so
    // stale definitions after a same-named workspace switch are harmless
    // (and the menu rescans when it opens).
    if (listEquals(names, prevNames)) return;
    _lastProjectSkills = next;
    notifyListeners();
  }

  // ==========================================================================
  // Mutations
  // ==========================================================================

  Future<InstallResult> createSkill({
    required String name,
    required String description,
    required String body,
    bool confirm = false,
  }) async {
    final content = SkillParser.buildSkillDocument(
      name: name,
      description: description,
      body: body,
    );
    final result = await SkillService.installSkill(
      name: name,
      content: content,
      confirm: confirm,
      source: SkillInstallSource.manual,
      globalRoot: _globalRootPath,
    );
    if (result.ok) await refresh();
    return result;
  }

  Future<ImportResult> importSkill({
    required String sourcePath,
    bool confirm = false,
    bool confirmFolder = false,
  }) async {
    final result = await SkillService.importSkillFile(
      sourcePath: sourcePath,
      confirm: confirm,
      confirmFolder: confirmFolder,
      globalRoot: _globalRootPath,
    );
    if (result.ok) await refresh();
    return result;
  }

  Future<ListGithubSkillsResult> listGithubSkills(String repoInput) async {
    return GithubSkillService.listGithubSkills(repoInput);
  }

  Future<DownloadGithubSkillResult> downloadGithubSkill({
    required String repoInput,
    required String path,
    bool confirm = false,
  }) async {
    final result = await GithubSkillService.downloadGithubSkill(
      repoInput: repoInput,
      path: path,
      confirm: confirm,
      globalRoot: _globalRootPath,
    );
    if (result.ok) await refresh();
    return result;
  }

  /// Mobile-only (D6): the desktop `~/.agents/skills/` directory is shared
  /// with other tools, so the app never deletes from it.
  Future<DeleteResult> deleteSkill(String name) async {
    final result = await SkillService.deleteSkill(
      name,
      mobilePlatform: PlatformUtils.isMobile,
      globalRoot: _globalRootPath,
    );
    if (result.ok) await refresh();
    return result;
  }

  // ==========================================================================
  // One-time cleanup of the old example seed
  // =========================================================================

  /// Distinctive line of the seed this app used to write on first use. A
  /// folder is removed only when its SKILL.md still contains it verbatim, so
  /// a skill the user has since edited or repurposed is never touched.
  static const String _seededDescriptionSignature =
      'A minimal example showing the SKILL.md format.';

  /// Devices that ran the old first-use seed get the unmodified
  /// `example-skill` folder removed once: seeding no longer happens
  /// (2026-10-06 user feedback), desktop has no in-app delete, and the
  /// global dir is shared with other tools — leaving it would strand it.
  /// The flag is dropped afterwards; nothing is ever re-seeded.
  Future<void> _cleanupSeededExampleSkill() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(_seededFlagKey) ?? false)) return;
      final root = _globalRootPath;
      var done = true;
      if (root != null) {
        final folder = Directory('$root/example-skill');
        final skillFile = File('${folder.path}/SKILL.md');
        if (skillFile.existsSync()) {
          final content = await skillFile.readAsString();
          if (content.contains(_seededDescriptionSignature)) {
            try {
              await folder.delete(recursive: true);
            } catch (_) {
              done = false; // locked this run — retry next launch
            }
          }
          // Edited by the user → keep it; it belongs to them now.
        }
      }
      if (done) await prefs.remove(_seededFlagKey);
    } catch (_) {
      // Best-effort cleanup — never block startup.
    }
  }
}
