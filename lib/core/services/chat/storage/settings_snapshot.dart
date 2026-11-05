import 'dart:io';

import '../../backup/backup_preferences.dart';
import 'chat_database_files.dart';

/// Settings are not transactional. A restore snapshots the current
/// preferences, stages the archive's settings, and applies them only after the
/// chat database and files are committed. A failed apply is reported as a
/// partial success and the staged file is kept for an explicit retry.
class SettingsSnapshot {
  const SettingsSnapshot(this.files);

  final ChatDatabaseFiles files;

  /// Test seam: fail the next apply once. The pending file is kept.
  static bool debugFailOnApply = false;

  File get previous => files.restoreSettingsSnapshot;
  File get pending => files.restoreSettingsPending;

  Future<void> captureCurrent() async {
    final prefs = await SharedPreferencesAsync.instance;
    await files.writeJsonAtomically(previous, await prefs.snapshot());
  }

  Future<void> stageIncoming(Map<String, dynamic> settings) async {
    await files.writeJsonAtomically(pending, settings);
  }

  /// Applies the staged settings and removes the pending file. Returns false
  /// when there was nothing staged.
  Future<bool> applyPending() async {
    if (!await pending.exists()) return false;
    if (debugFailOnApply) {
      debugFailOnApply = false;
      throw const FileSystemException('Injected settings apply failure (debug).');
    }
    final data = await files.readJson(pending);
    if (data == null) {
      throw const FormatException('The staged settings snapshot is unreadable.');
    }
    final prefs = await SharedPreferencesAsync.instance;
    await prefs.restore(data);
    try {
      await pending.delete();
    } catch (_) {}
    // The pre-restore snapshot is no longer needed once the apply succeeded.
    await discardSnapshot();
    return true;
  }

  Future<bool> hasPending() => pending.exists();

  Future<void> discardSnapshot() async {
    try {
      if (await previous.exists()) await previous.delete();
    } catch (_) {}
  }

  Future<void> discardPending() async {
    try {
      if (await pending.exists()) await pending.delete();
    } catch (_) {}
  }
}
