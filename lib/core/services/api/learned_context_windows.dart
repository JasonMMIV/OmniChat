// R0 learned context windows (IMPORT_PLAN_COWORK.md P1-2).
//
// When a provider rejects a request with a context-overflow 400 whose
// message discloses the real window, the parsed value is persisted here:
// `providerId/modelId → windowTokens`. Window lookup order is
// learned → seed table → 1M fallback ([resolveContextWindowTokens]).
//
// Keys use the LOGICAL model id (the app-facing model key) — the same
// convention as LearnedMaxOutputCaps. Every read site (chat actions,
// message generation, the R0 trim path in the transport) keys by the
// logical id, and the pair survives `apiModelId` mapping changes.
//
// These are device observations, not user preferences — the prefs key is
// excluded from backup/restore via `SharedPreferencesAsync._localOnlyKeys`.
// Repeated learning keeps the MINIMUM observed value: windows learned from
// overflow errors are ceilings the request must fit under, so the more
// conservative value triggers compaction earlier and is always safe.
library;

import 'package:flutter/foundation.dart';

import 'context_overflow.dart'
    show learnedWindowMinTokens, learnedWindowMaxTokens;
import 'learned_int_map.dart';

class LearnedContextWindows {
  LearnedContextWindows._();

  static const String prefsKey = 'learned_context_windows_v1';

  static final LearnedIntMap _store = LearnedIntMap(
    prefsKey: prefsKey,
    debugLabel: 'LearnedContextWindows',
    // Sanity band mirrors the parser (4k–32M).
    isValid: (value) =>
        value >= learnedWindowMinTokens && value < learnedWindowMaxTokens,
  );

  /// The learned window for this provider/model, or `null`.
  static Future<int?> lookup(String providerId, String modelId) =>
      _store.lookup(providerId, modelId);

  /// Synchronous cache read (populated after the first [lookup]/[record]).
  static int? peek(String providerId, String modelId) =>
      _store.peek(providerId, modelId);

  /// Record a window learned from an overflow error. Sanity band mirrors
  /// the parser; keeps the minimum observed value; never throws.
  static Future<void> record(
    String providerId,
    String modelId,
    int windowTokens,
  ) => _store.record(providerId, modelId, windowTokens);

  /// Test seam: reset in-memory state.
  @visibleForTesting
  static void debugReset() => _store.debugReset();
}
