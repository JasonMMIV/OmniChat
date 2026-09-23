import 'reasoning_capabilities.dart';

/// Per-model reasoning-effort overrides.
///
/// Storage lives in the existing `ProviderConfig.modelOverrides[modelId]`
/// map under the `reasoning` key:
///
/// ```json
/// {
///   "v": 1,
///   "efforts": ["none", "low", "medium", "high", "xhigh", "max"],
///   "offFallback": "none",
///   "supportsXhigh": true,
///   "supportsMax": false,
///   "thinkingAlwaysOn": false,
///   "samplingRequiresNone": false,
///   "adaptiveThinking": false
/// }
/// ```
///
/// Parsing is lenient: a missing or wrongly-typed field falls back to the
/// built-in regex-based capability for that single field. When the whole
/// `reasoning` key is absent the model behaves exactly like before this
/// feature existed.
class ReasoningOverride {
  const ReasoningOverride({
    required this.hasEfforts,
    required this.efforts,
    required this.hasOffFallback,
    required this.offFallback,
    required this.hasSupportsXhigh,
    required this.supportsXhigh,
    required this.hasSupportsMax,
    required this.supportsMax,
    required this.hasThinkingAlwaysOn,
    required this.thinkingAlwaysOn,
    required this.hasSamplingRequiresNone,
    required this.samplingRequiresNone,
    required this.hasAdaptiveThinking,
    required this.adaptiveThinking,
  });

  /// Every supported effort value, in wire order (low -> max).
  static const List<String> allEfforts = <String>[
    'none',
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
  ];

  /// Storage key inside `modelOverrides[modelId]`.
  static const String storageKey = 'reasoning';

  final bool hasEfforts;
  final Set<String> efforts;
  final bool hasOffFallback;
  final String? offFallback;
  final bool hasSupportsXhigh;
  final bool supportsXhigh;
  final bool hasSupportsMax;
  final bool supportsMax;
  final bool hasThinkingAlwaysOn;
  final bool thinkingAlwaysOn;
  final bool hasSamplingRequiresNone;
  final bool samplingRequiresNone;
  final bool hasAdaptiveThinking;
  final bool adaptiveThinking;

  /// Parse the raw override map (the value stored under
  /// `modelOverrides[modelId]['reasoning']`). Returns `null` when the input
  /// is not a map so callers can fall back to built-in behavior entirely.
  static ReasoningOverride? fromMap(Object? raw) {
    if (raw is! Map) return null;
    return ReasoningOverride(
      hasEfforts: _effortsField(raw) != null,
      efforts: _effortsField(raw) ?? const <String>{},
      hasOffFallback: raw['offFallback'] is String,
      offFallback:
          raw['offFallback'] is String ? raw['offFallback'] as String : null,
      hasSupportsXhigh: raw['supportsXhigh'] is bool,
      supportsXhigh:
          raw['supportsXhigh'] is bool ? raw['supportsXhigh'] as bool : false,
      hasSupportsMax: raw['supportsMax'] is bool,
      supportsMax:
          raw['supportsMax'] is bool ? raw['supportsMax'] as bool : false,
      hasThinkingAlwaysOn: raw['thinkingAlwaysOn'] is bool,
      thinkingAlwaysOn: raw['thinkingAlwaysOn'] is bool
          ? raw['thinkingAlwaysOn'] as bool
          : false,
      hasSamplingRequiresNone: raw['samplingRequiresNone'] is bool,
      samplingRequiresNone: raw['samplingRequiresNone'] is bool
          ? raw['samplingRequiresNone'] as bool
          : false,
      hasAdaptiveThinking: raw['adaptiveThinking'] is bool,
      adaptiveThinking: raw['adaptiveThinking'] is bool
          ? raw['adaptiveThinking'] as bool
          : false,
    );
  }

  /// Lenient effort list: unknown strings are dropped; an empty result means
  /// "no opinion" (the merge falls back to the built-in effort set).
  static Set<String>? _effortsField(Map raw) {
    final list = raw['efforts'];
    if (list is! List) return null;
    final out = <String>{};
    for (final e in list) {
      if (e is String) {
        final v = e.trim().toLowerCase();
        if (v.isEmpty) continue;
        if (allEfforts.contains(v)) out.add(v);
      }
    }
    if (out.isEmpty) return null;
    return out;
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'v': 1,
        'efforts': [
          for (final e in allEfforts)
            if (efforts.contains(e)) e,
        ],
        if (hasOffFallback && offFallback != null) 'offFallback': offFallback,
        'supportsXhigh': supportsXhigh,
        'supportsMax': supportsMax,
        'thinkingAlwaysOn': thinkingAlwaysOn,
        'samplingRequiresNone': samplingRequiresNone,
        'adaptiveThinking': adaptiveThinking,
      };

  /// Extract the override from one `modelOverrides[modelId]` entry, returning
  /// `null` when absent (or not a map) so callers use built-in behavior.
  static ReasoningOverride? fromModelOverrides(Object? modelOverride) {
    if (modelOverride is! Map) return null;
    return fromMap(modelOverride[storageKey]);
  }

  /// Whether the override map expresses any opinion at all. An override
  /// parsed from an empty/unknown payload is treated as absent.
  ///
  /// Flag-only entries that merely turn everything off also count as absent:
  /// switching to custom mode and saving without checking anything used to
  /// persist all-false flags that masked built-in capabilities (tiles
  /// vanished). Only a positive flag (or efforts, or offFallback) is an
  /// opinion worth honoring.
  bool get isEmpty =>
      !hasEfforts &&
      !hasOffFallback &&
      !(hasSupportsXhigh && supportsXhigh) &&
      !(hasSupportsMax && supportsMax) &&
      !(hasThinkingAlwaysOn && thinkingAlwaysOn) &&
      !(hasSamplingRequiresNone && samplingRequiresNone) &&
      !(hasAdaptiveThinking && adaptiveThinking);

  ReasoningOverride copyWith({
    Set<String>? efforts,
    String? offFallback,
    bool clearOffFallback = false,
    bool? supportsXhigh,
    bool? supportsMax,
    bool? thinkingAlwaysOn,
    bool? samplingRequiresNone,
    bool? adaptiveThinking,
  }) => ReasoningOverride(
        hasEfforts: true,
        efforts: efforts ?? this.efforts,
        hasOffFallback: !clearOffFallback,
        offFallback:
            clearOffFallback ? null : (offFallback ?? this.offFallback),
        hasSupportsXhigh: true,
        supportsXhigh: supportsXhigh ?? this.supportsXhigh,
        hasSupportsMax: true,
        supportsMax: supportsMax ?? this.supportsMax,
        hasThinkingAlwaysOn: true,
        thinkingAlwaysOn: thinkingAlwaysOn ?? this.thinkingAlwaysOn,
        hasSamplingRequiresNone: true,
        samplingRequiresNone: samplingRequiresNone ?? this.samplingRequiresNone,
        hasAdaptiveThinking: true,
        adaptiveThinking: adaptiveThinking ?? this.adaptiveThinking,
      );
}

/// Field-wise merge: an override field only replaces the built-in value when
/// the user actually expressed an opinion for that field (has* flag true).
/// Everything else — including the whole built-in regex table — is untouched.
///
/// Xhigh/Max display support is derived from the effort set itself whenever
/// the override declares efforts: the tier tiles in the budget sheet and the
/// desktop popover are gated on `supportsXhigh`/`supportsMax`, while the
/// manual-customization UI only edits the effort set. Deriving keeps the two
/// representations in lockstep (a stored stale flag can never desync the
/// UI from the set that actually drives the wire).
ReasoningCapabilities mergeReasoningCapabilities(
  ReasoningCapabilities base,
  ReasoningOverride? override,
) {
  if (override == null || override.isEmpty) return base;
  return ReasoningCapabilities(
    supportsXhigh: override.hasEfforts
        ? override.efforts.contains('xhigh')
        : override.hasSupportsXhigh
            ? override.supportsXhigh
            : base.supportsXhigh,
    supportsMax: override.hasEfforts
        ? override.efforts.contains('max')
        : override.hasSupportsMax
            ? override.supportsMax
            : base.supportsMax,
    supportsAdaptiveThinking: override.hasAdaptiveThinking
        ? override.adaptiveThinking
        : base.supportsAdaptiveThinking,
    thinkingAlwaysOn: override.hasThinkingAlwaysOn
        ? override.thinkingAlwaysOn
        : base.thinkingAlwaysOn,
    samplingRequiresNone: override.hasSamplingRequiresNone
        ? override.samplingRequiresNone
        : base.samplingRequiresNone,
    openAiEfforts:
        override.hasEfforts ? override.efforts : base.openAiEfforts,
    openAiOffFallback: override.hasOffFallback
        ? override.offFallback
        : base.openAiOffFallback,
  );
}

/// One-stop resolver used by the experimental call sites:
/// built-in regex capability first, then the per-model override on top.
ReasoningCapabilities resolveReasoningCapabilities(
  ReasoningTransport transport,
  String modelId, {
  ReasoningOverride? override,
}) => mergeReasoningCapabilities(
      ReasoningCapabilities.forModel(transport, modelId),
      override,
    );

/// Transport-layer convenience: resolve capabilities for a call site that
/// holds the [ProviderConfig] (typed `dynamic` here to avoid a provider
/// import cycle).
ReasoningCapabilities reasoningCapabilitiesForCall(
  ReasoningTransport transport,
  String modelId,
  dynamic config,
) {
  ReasoningOverride? ovr;
  if (config != null) {
    try {
      final overrides = (config as dynamic).modelOverrides;
      if (overrides is Map) {
        // Callers pass either the logical key or the upstream model id
        // (ChatApiService's claude path resolves _apiModelId first). The
        // override map is keyed by the logical key, so a direct miss falls
        // back to a reverse lookup through `apiModelId`.
        ovr = ReasoningOverride.fromModelOverrides(overrides[modelId]);
        if (ovr == null) {
          final lowerId = modelId.toLowerCase();
          for (final entry in overrides.values) {
            if (entry is! Map) continue;
            final apiId =
                (entry['apiModelId'] ?? entry['api_model_id'])?.toString();
            if (apiId == null || apiId.trim().toLowerCase() != lowerId) {
              continue;
            }
            // Entries that merely share the upstream id but carry no
            // 'reasoning' data are skipped; falling through returns the
            // built-in result, which is the correct outcome for them.
            final candidate = ReasoningOverride.fromModelOverrides(entry);
            if (candidate != null) {
              ovr = candidate;
              break;
            }
          }
        }
      }
    } catch (_) {
      ovr = null;
    }
  }
  return resolveReasoningCapabilities(transport, modelId, override: ovr);
}
