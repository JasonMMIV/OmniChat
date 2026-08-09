import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/flutter_logger.dart';

/// Live API Key 儲存（§5.8）。
///
/// 正式值放 `flutter_secure_storage`（Android Keystore / Windows DPAPI）；
/// 讀取時若 secure storage 沒有值，會自動從舊的 SharedPreferences 位置
/// （`live_api_key_v1`）遷移：寫入 secure storage 後刪除舊值，避免明文殘留。
class LiveApiKeyStore {
  LiveApiKeyStore({FlutterSecureStorage? secureStorage})
      : _secure = secureStorage ?? const FlutterSecureStorage();

  /// secure storage 的 key（不與其他欄位共用）。
  static const String secureKey = 'live_api_key_secure_v1';

  /// 舊版 SharedPreferences 位置（§5.8 遷移來源；v1.13 之前 API Key 存這裡）。
  static const String legacyPrefsKey = 'live_api_key_v1';

  final FlutterSecureStorage _secure;

  /// 讀取 API Key：優先 secure storage；不存在時從舊 SharedPreferences
  /// 位置遷移（寫入 secure + 刪除舊值）。任何平台異常都退回 legacy / null，
  /// 不讓設定載入因 secure storage 失敗而中斷。
  Future<String?> read() async {
    String? secure;
    try {
      secure = await _secure.read(key: secureKey);
    } catch (e) {
      FlutterLogger.log('secure read failed: $e', tag: 'live-api');
    }
    if (secure != null && secure.isNotEmpty) {
      // secure 是權威值；若舊位置仍有殘留（例如降版又寫回），順手清掉。
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(legacyPrefsKey)) {
        await prefs.remove(legacyPrefsKey);
      }
      return secure;
    }
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(legacyPrefsKey);
    if (legacy != null && legacy.isNotEmpty) {
      try {
        await _secure.write(key: secureKey, value: legacy);
        await prefs.remove(legacyPrefsKey);
      } catch (e) {
        FlutterLogger.log('secure migrate failed: $e', tag: 'live-api');
      }
      return legacy;
    }
    return null;
  }

  /// 寫入 API Key 到 secure storage，並清除舊 SharedPreferences 位置。
  Future<void> write(String value) async {
    try {
      await _secure.write(key: secureKey, value: value);
    } catch (e) {
      FlutterLogger.log('secure write failed: $e', tag: 'live-api');
      rethrow;
    }
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(legacyPrefsKey)) {
      await prefs.remove(legacyPrefsKey);
    }
  }

  /// 刪除 API Key（secure + legacy 兩處都清）。
  Future<void> delete() async {
    try {
      await _secure.delete(key: secureKey);
    } catch (e) {
      FlutterLogger.log('secure delete failed: $e', tag: 'live-api');
      rethrow;
    }
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(legacyPrefsKey)) {
      await prefs.remove(legacyPrefsKey);
    }
  }
}
