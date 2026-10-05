// Shared storage for learned per-model integer observations — currently the
// context windows ([LearnedContextWindows]) and the Claude output ceilings
// ([LearnedMaxOutputCaps]).
//
// The two stores differ only in their prefs key, accepted value band and
// debug label; the mechanics are identical:
//   * entries are `providerId/modelId → value` (both trimmed; a blank pair
//     is ignored),
//   * repeated learning keeps the MINIMUM observed value — an inflated
//     observation is the dangerous direction for both facts,
//   * the map is (de)serialised as one JSON string in SharedPreferences and
//     never travels with a backup (the key is listed in
//     `SharedPreferencesAsync._localOnlyKeys`),
//   * every failure is swallowed: learning is best-effort metadata.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LearnedIntMap {
  LearnedIntMap({
    required this.prefsKey,
    required this.debugLabel,
    required this.isValid,
  });

  final String prefsKey;
  final String debugLabel;

  /// Value sanity band (inclusive); values outside it are never stored.
  final bool Function(int value) isValid;

  final Map<String, int> _cache = <String, int>{};
  bool _loaded = false;

  static String _keyOf(String providerId, String modelId) =>
      '${providerId.trim()}/${modelId.trim()}';

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((k, v) {
        final value = v is num ? v.toInt() : int.tryParse('$v');
        if (k is String && value != null && value > 0) {
          _cache[k] = value;
        }
      });
    } catch (e) {
      if (kDebugMode) debugPrint('$debugLabel load failed: $e');
    }
  }

  /// The learned value for this provider/model, or `null`.
  Future<int?> lookup(String providerId, String modelId) async {
    await _ensureLoaded();
    return _cache[_keyOf(providerId, modelId)];
  }

  /// Synchronous cache read (populated after the first [lookup]/[record]).
  int? peek(String providerId, String modelId) =>
      _cache[_keyOf(providerId, modelId)];

  /// Record an observation. Values outside the store's band are dropped;
  /// the minimum observed value wins; never throws.
  Future<void> record(String providerId, String modelId, int value) async {
    if (!isValid(value)) return;
    final key = _keyOf(providerId, modelId);
    if (key == '/') return;
    await _ensureLoaded();
    final existing = _cache[key];
    if (existing != null && existing <= value) return;
    _cache[key] = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode(_cache));
    } catch (e) {
      if (kDebugMode) debugPrint('$debugLabel persist failed: $e');
    }
  }

  /// Test seam: reset in-memory state.
  @visibleForTesting
  void debugReset() {
    _cache.clear();
    _loaded = false;
  }
}
