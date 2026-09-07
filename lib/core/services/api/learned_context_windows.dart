// R0 learned context windows (IMPORT_PLAN_COWORK.md P1-2).
//
// When a provider rejects a request with a context-overflow 400 whose
// message discloses the real window, the parsed value is persisted here:
// `providerId/modelId → windowTokens`. Window lookup order is
// learned → seed table → 1M fallback ([resolveContextWindowTokens]).
//
// These are device observations, not user preferences — the prefs key is
// excluded from backup/restore via `SharedPreferencesAsync._localOnlyKeys`.
// Repeated learning keeps the MINIMUM observed value: windows learned from
// overflow errors are ceilings the request must fit under, so the more
// conservative value triggers compaction earlier and is always safe.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'context_overflow.dart' show learnedWindowMinTokens, learnedWindowMaxTokens;

class LearnedContextWindows {
  LearnedContextWindows._();

  static const String prefsKey = 'learned_context_windows_v1';

  static final Map<String, int> _cache = <String, int>{};
  static bool _loaded = false;

  static String _keyOf(String providerId, String modelId) =>
      '${providerId.trim()}/${modelId.trim()}';

  static Future<void> _ensureLoaded() async {
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
      if (kDebugMode) debugPrint('LearnedContextWindows load failed: $e');
    }
  }

  /// The learned window for this provider/model, or `null`.
  static Future<int?> lookup(String providerId, String modelId) async {
    await _ensureLoaded();
    return _cache[_keyOf(providerId, modelId)];
  }

  /// Synchronous cache read (populated after the first [lookup]/[record]).
  static int? peek(String providerId, String modelId) =>
      _cache[_keyOf(providerId, modelId)];

  /// Record a window learned from an overflow error. Sanity band mirrors
  /// the parser (4k–32M); keeps the minimum observed value; never throws.
  static Future<void> record(
    String providerId,
    String modelId,
    int windowTokens,
  ) async {
    if (windowTokens < learnedWindowMinTokens ||
        windowTokens >= learnedWindowMaxTokens) {
      return;
    }
    final key = _keyOf(providerId, modelId);
    if (key == '/') return;
    await _ensureLoaded();
    final existing = _cache[key];
    if (existing != null && existing <= windowTokens) return;
    _cache[key] = windowTokens;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode(_cache));
    } catch (e) {
      if (kDebugMode) debugPrint('LearnedContextWindows persist failed: $e');
    }
  }

  /// Test seam: reset in-memory state.
  @visibleForTesting
  static void debugReset() {
    _cache.clear();
    _loaded = false;
  }
}
