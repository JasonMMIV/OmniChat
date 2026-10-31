import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

/// Thrown when another live app process holds the exclusive maintenance lock.
class ChatMaintenanceLockBusy implements Exception {
  const ChatMaintenanceLockBusy(this.ownerPid);

  final int? ownerPid;

  @override
  String toString() =>
      'ChatMaintenanceLockBusy: another instance (pid ${ownerPid ?? '?'}) '
      'is updating chat storage.';
}

/// Exclusive, crash-recoverable maintenance guard for pre-migration backup,
/// migration, schema upgrade, publish, clearAllData, reset, and legacy
/// retirement (§8.2/§8.10).
///
/// Normal SQLite reads/writes do NOT take this lock; they rely on one
/// connection per process, WAL and `busy_timeout`. Re-acquisition inside the
/// same process is re-entrant and returns the held handle, so a gate that
/// passes the lock down to the importer does not self-block.
class ChatMaintenanceLock {
  ChatMaintenanceLock._(this._file, this._token);

  static ChatMaintenanceLock? _active;
  static int _depth = 0;

  final File _file;
  final String _token;

  static bool get isHeld => _active != null;

  /// Acquires (or re-enters) the lock. Waits up to [timeout] for another live
  /// process, recovers a lock owned by a dead PID, and never force-breaks a
  /// live one.
  static Future<ChatMaintenanceLock> acquire(
    Directory directory, {
    String purpose = 'maintenance',
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final active = _active;
    if (active != null) {
      _depth++;
      return active;
    }

    final file = File(
      '${directory.path}${Platform.pathSeparator}chat_v2.maintenance.lock',
    );
    final deadline = DateTime.now().add(timeout);
    final token = const Uuid().v4();
    var emptyReads = 0;

    while (true) {
      try {
        await file.create(exclusive: true);
        final handle = await file.open(mode: FileMode.write);
        try {
          await handle.writeString(
            jsonEncode(<String, dynamic>{
              'format': 1,
              'pid': pid,
              'token': token,
              'purpose': purpose,
              'acquiredAtUtc': DateTime.now().toUtc().toIso8601String(),
            }),
          );
          await handle.flush();
        } finally {
          await handle.close();
        }
        final lock = ChatMaintenanceLock._(file, token);
        _active = lock;
        _depth = 1;
        return lock;
      } on FileSystemException {
        final owner = await _readOwner(file);
        if (owner == null) {
          // A crash can leave an empty/partial lock file. Give a concurrent
          // writer a moment; only delete after repeated empty reads.
          emptyReads++;
          if (emptyReads >= 3) {
            await _deleteIfOwned(file, null);
            emptyReads = 0;
            continue;
          }
          if (DateTime.now().isAfter(deadline)) {
            throw const ChatMaintenanceLockBusy(null);
          }
          await Future<void>.delayed(const Duration(milliseconds: 150));
          continue;
        }
        emptyReads = 0;

        final ownerPid = owner['pid'] is int
            ? owner['pid'] as int
            : int.tryParse('${owner['pid']}');
        if (ownerPid != null && ownerPid == pid) {
          // Same process, not held by the static guard (e.g. a previous test
          // or an isolate that died): stale by definition.
          await _deleteIfOwned(file, owner['token']?.toString());
          continue;
        }
        if (ownerPid != null && await _pidAlive(ownerPid)) {
          if (DateTime.now().isAfter(deadline)) {
            throw ChatMaintenanceLockBusy(ownerPid);
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }
        // Dead owner: recover the stale lock.
        await _deleteIfOwned(file, owner['token']?.toString());
      }
    }
  }

  Future<void> release() async {
    if (!identical(_active, this)) return;
    if (_depth > 1) {
      _depth--;
      return;
    }
    _depth = 0;
    _active = null;
    await _deleteIfOwned(_file, _token);
  }

  static Future<Map<String, dynamic>?> _readOwner(File file) async {
    try {
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _deleteIfOwned(File file, String? token) async {
    try {
      final owner = await _readOwner(file);
      if (owner == null) {
        // Only an explicitly empty/partial lock may be removed without a
        // token; a parsed owner always requires an exact token match.
        if (token == null && await file.exists()) await file.delete();
        return;
      }
      if (token == null || owner['token'] != token) return;
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  static Future<bool> _pidAlive(int ownerPid) async {
    if (ownerPid <= 0) return false;
    try {
      if (Platform.isWindows) {
        final result = await Process.run(
          'tasklist',
          <String>['/FI', 'PID eq $ownerPid', '/NH'],
        );
        if (result.exitCode != 0) return true;
        return result.stdout.toString().contains('$ownerPid');
      }
      final result = await Process.run('kill', <String>['-0', '$ownerPid']);
      return result.exitCode == 0;
    } catch (_) {
      return true;
    }
  }
}
