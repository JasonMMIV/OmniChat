import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/backup.dart';
import '../services/chat/chat_service.dart';
import '../services/backup/data_sync.dart';
import '../services/logging/flutter_logger.dart';
import '../services/chat/storage/chat_backup_restorer.dart';

class BackupProvider extends ChangeNotifier {
  final DataSync _dataSync;
  WebDavConfig _cfg;
  DropboxConfig _dropboxCfg;
  bool _busy = false;
  String? _message;

  /// Called after a successful restore. The memory provider uses this to drop
  /// its process-local cache so restored entries appear without a restart.
  final Future<void> Function()? onRestored;

  BackupProvider({
    required ChatService chatService,
    WebDavConfig? initialConfig,
    DropboxConfig? initialDropboxConfig,
    this.onRestored,
  })  : _dataSync = DataSync(chatService: chatService),
        _cfg = initialConfig ?? const WebDavConfig(),
        _dropboxCfg = initialDropboxConfig ?? const DropboxConfig();

  WebDavConfig get config => _cfg;
  DropboxConfig get dropboxConfig => _dropboxCfg;
  bool get busy => _busy;
  String? get message => _message;

  void updateConfig(WebDavConfig cfg) {
    _cfg = cfg;
    notifyListeners();
  }

  void updateDropboxConfig(DropboxConfig cfg) {
    _dropboxCfg = cfg;
    notifyListeners();
  }

  Future<void> test() async {
    _busy = true; _message = null; notifyListeners();
    try {
      await _dataSync.testWebdav(_cfg);
      _message = 'OK';
    } catch (e) {
      _message = e.toString();
    } finally {
      _busy = false; notifyListeners();
    }
  }

  Future<void> testDropbox(DropboxConfig cfg) async {
    _busy = true; _message = null; notifyListeners();
    try {
      await _dataSync.testDropbox(cfg);
      _message = 'OK';
    } catch (e) {
      _message = e.toString();
    } finally {
      _busy = false; notifyListeners();
    }
  }

  Future<void> backup() async {
    _busy = true; _message = null; notifyListeners();
    try {
      await _dataSync.backupToWebDav(_cfg);
      _message = 'Backup uploaded';
    } catch (e) {
      _message = e.toString();
    } finally {
      _busy = false; notifyListeners();
    }
  }

  Future<void> backupDropbox(DropboxConfig cfg) async {
    _busy = true; _message = null; notifyListeners();
    try {
      final uploadedPath = await _dataSync.backupToDropbox(cfg);
      _message = 'OK:$uploadedPath';
    } catch (e) {
      _message = e.toString();
    } finally {
      _busy = false; notifyListeners();
    }
  }

  Future<void> _notifyRestored() async {
    final callback = onRestored;
    if (callback == null) return;
    try {
      await callback();
    } catch (e, st) {
      FlutterLogger.log(
        'Backup restore callback failed: $e\n$st',
        tag: 'backup',
      );
    }
  }

  String _restoreMessage(ChatRestoreResult? result) {
    if (result != null && !result.settingsApplied) {
      return result.settingsError ??
          'Chat data was restored, but settings were not applied.';
    }
    return 'Restored';
  }

  Future<ChatRestoreResult?> restoreFromItem(BackupFileItem item, {RestoreMode mode = RestoreMode.overwrite}) async {
    _busy = true; _message = null; notifyListeners();
    try {
      final result = await _dataSync.restoreFromWebDav(_cfg, item, mode: mode);
      if (result != null) await _notifyRestored();
      _message = _restoreMessage(result);
      return result;
    } catch (e) { _message = e.toString(); return null; }
    finally { _busy = false; notifyListeners(); }
  }

  Future<ChatRestoreResult?> restoreDropboxFromItem(DropboxConfig cfg, BackupFileItem item, {RestoreMode mode = RestoreMode.overwrite}) async {
    _busy = true; _message = null; notifyListeners();
    try {
      final result = await _dataSync.restoreFromDropbox(cfg, item, mode: mode);
      if (result != null) await _notifyRestored();
      _message = _restoreMessage(result);
      return result;
    } catch (e) { _message = e.toString(); return null; }
    finally { _busy = false; notifyListeners(); }
  }

  Future<List<BackupFileItem>> listRemote() async {
    return _dataSync.listBackupFiles(_cfg);
  }

  Future<List<BackupFileItem>> listDropboxRemote(DropboxConfig cfg) async {
    return _dataSync.listDropboxBackupFiles(cfg);
  }

  Future<List<BackupFileItem>> deleteAndReload(BackupFileItem item) async {
    await _dataSync.deleteWebDavBackupFile(_cfg, item);
    return _dataSync.listBackupFiles(_cfg);
  }

  Future<List<BackupFileItem>> deleteAndReloadDropbox(DropboxConfig cfg, BackupFileItem item) async {
    await _dataSync.deleteDropboxBackupFile(cfg, item);
    return _dataSync.listDropboxBackupFiles(cfg);
  }

  Future<File> exportToFile() => _dataSync.exportToFile(_cfg);

  Future<ChatRestoreResult?> restoreFromLocalFile(File file, {RestoreMode mode = RestoreMode.overwrite}) async {
    _busy = true; _message = null; notifyListeners();
    try {
      final result = await _dataSync.restoreFromLocalFile(file, _cfg, mode: mode);
      if (result != null) await _notifyRestored();
      _message = _restoreMessage(result);
      return result;
    } catch (e) { _message = e.toString(); return null; }
    finally { _busy = false; notifyListeners(); }
  }
}


