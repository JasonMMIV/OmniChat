// Learned Claude max_tokens ceilings (see claude_max_tokens.dart).
//
// When `/v1/messages` rejects a request with a ceiling-shaped 400
// (`max_tokens: N > M, which is the maximum allowed …`, or one of the
// third-party wordings parsed by claude_max_tokens.dart), M is a fact about
// the model and is persisted here as `providerId/modelId → ceilingTokens`,
// so subsequent requests start at M instead of paying a 400 round trip.
//
// Keys use the LOGICAL model id (the app-facing model key) — the same
// convention as LearnedContextWindows; the wire id is resolved from it per
// request, so a changed `apiModelId` mapping keeps the learning.
//
// Like LearnedContextWindows these are device observations rather than user
// preferences: the prefs key is listed in
// `SharedPreferencesAsync._localOnlyKeys` and therefore never travels with a
// backup.
//
// Repeated learning keeps the MINIMUM observed value — an inflated ceiling
// would put the request back into a reject-and-retry loop on every message,
// while a stale-low one only limits output (and a fresh 400 that names a
// higher ceiling never happens, since we start from the stored value).
library;

import 'package:flutter/foundation.dart';

import 'learned_int_map.dart';

class LearnedMaxOutputCaps {
  LearnedMaxOutputCaps._();

  static const String prefsKey = 'learned_output_caps_v1';

  /// Sanity band: nothing below Anthropic's thinking-budget minimum and
  /// nothing above the largest declared output (300k batch beta) makes
  /// sense as a stored ceiling.
  static const int _minTokens = 1024;
  static const int _maxTokens = 300000;

  static final LearnedIntMap _store = LearnedIntMap(
    prefsKey: prefsKey,
    debugLabel: 'LearnedMaxOutputCaps',
    isValid: (value) => value >= _minTokens && value <= _maxTokens,
  );

  /// The learned ceiling for this provider/model, or `null`.
  static Future<int?> lookup(String providerId, String modelId) =>
      _store.lookup(providerId, modelId);

  /// Synchronous cache read (populated after the first [lookup]/[record]).
  static int? peek(String providerId, String modelId) =>
      _store.peek(providerId, modelId);

  /// Record a ceiling stated by the server. Keeps the minimum observed
  /// value; never throws.
  static Future<void> record(
    String providerId,
    String modelId,
    int ceilingTokens,
  ) => _store.record(providerId, modelId, ceilingTokens);

  /// Test seam: reset in-memory state.
  @visibleForTesting
  static void debugReset() => _store.debugReset();
}
