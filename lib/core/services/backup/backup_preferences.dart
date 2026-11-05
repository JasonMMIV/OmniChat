import 'package:shared_preferences/shared_preferences.dart';

// ===== SharedPreferences async snapshot/restore helpers =====
class SharedPreferencesAsync {
  SharedPreferencesAsync._();
  static SharedPreferencesAsync? _inst;
  // Local-only UI state stays on device and is excluded from backups/restores.
  static const _localOnlyKeys = {
    // Web fetch: "allow private hosts" is device/network specific and must
    // never ride along through a backup (WEB_FETCH_PLAN.md §5.12).
    'web_fetch_allow_private_hosts_v1',
    'learned_context_windows_v1',
    'learned_output_caps_v1',
    // models.dev catalog refresh bookkeeping: device-local cache metadata.
    'model_catalog_fetched_at_v1',
    'model_catalog_etag_v1',
    // OpenCode overlay refresh bookkeeping: same device-local rule.
    'opencode_catalog_fetched_at_v1',
    'opencode_catalog_etag_v1',
    'window_width_v1',
    'window_height_v1',
    'window_pos_x_v1',
    'window_pos_y_v1',
    'window_maximized_v1',
    'display_chat_font_scale_v1',
    // Long-image export tiling: memory limits differ per device; never sync.
    'long_image_tiling_v1',
  };

  static Future<SharedPreferencesAsync> get instance async {
    _inst ??= SharedPreferencesAsync._();
    return _inst!;
  }

  Future<Map<String, dynamic>> snapshot() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    final map = <String, dynamic>{};
    for (final k in keys) {
      if (_localOnlyKeys.contains(k)) continue;
      map[k] = prefs.get(k);
    }
    return map;
  }

  Future<void> restore(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    for (final entry in data.entries) {
      final k = entry.key;
      final v = entry.value;
      if (_localOnlyKeys.contains(k)) continue;
      if (v is bool)
        await prefs.setBool(k, v);
      else if (v is int)
        await prefs.setInt(k, v);
      else if (v is double)
        await prefs.setDouble(k, v);
      else if (v is String)
        await prefs.setString(k, v);
      else if (v is List) {
        await prefs.setStringList(k, v.whereType<String>().toList());
      }
    }
  }

  Future<void> restoreSingle(String key, dynamic value) async {
    if (_localOnlyKeys.contains(key)) return;
    final prefs = await SharedPreferences.getInstance();
    if (value is bool)
      await prefs.setBool(key, value);
    else if (value is int)
      await prefs.setInt(key, value);
    else if (value is double)
      await prefs.setDouble(key, value);
    else if (value is String)
      await prefs.setString(key, value);
    else if (value is List) {
      await prefs.setStringList(key, value.whereType<String>().toList());
    }
  }

  /// Targeted snapshot of specific keys (third-party importer rollback, plan
  /// §3 Phase 1c). Absent keys are recorded as null so a rollback can remove
  /// them again. Unlike [snapshot], no local-only filtering applies: these
  /// are explicit importer keys.
  static Future<Map<String, Object?>> captureKeys(
    Iterable<String> keys,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    return <String, Object?>{
      for (final key in keys) key: prefs.get(key),
    };
  }

  /// Restores a [captureKeys] snapshot: null removes the key, other values
  /// are written back with their original type.
  static Future<void> restoreKeys(Map<String, Object?> snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    for (final entry in snapshot.entries) {
      final value = entry.value;
      try {
        if (value == null) {
          await prefs.remove(entry.key);
        } else if (value is bool) {
          await prefs.setBool(entry.key, value);
        } else if (value is int) {
          await prefs.setInt(entry.key, value);
        } else if (value is double) {
          await prefs.setDouble(entry.key, value);
        } else if (value is String) {
          await prefs.setString(entry.key, value);
        } else if (value is List) {
          await prefs.setStringList(entry.key, value.cast<String>());
        }
      } catch (_) {
        // One broken key must not abort the rollback of the remaining keys.
      }
    }
  }
}
