// Shared OAuth model-list effort normalization.
//
// Codex publishes `supported_reasoning_levels` as objects, Claude publishes
// `capabilities.effort` as a map, and Grok/Kimi use string or object lists.
// Only the standard OmniChat effort vocabulary survives; Codex-only modes such
// as `ultra`/`persistent` are intentionally dropped because they are not raw
// Responses API effort values.

import '../../utils/reasoning_overrides.dart';

/// Normalizes an effort list from a provider model payload.
///
/// Accepts a comma-separated string, a list of strings, or a list of objects
/// such as Codex's `{effort, description}`. Unknown values are dropped so an
/// endpoint cannot inject an invalid effort into `modelOverrides`.
Set<String> normalizeOAuthReasoningEfforts(Object? raw) {
  final out = <String>{};

  void addValue(Object? value) {
    if (value is String) {
      for (final part in value.split(',')) {
        final effort = part.trim().toLowerCase();
        if (ReasoningOverride.allEfforts.contains(effort)) out.add(effort);
      }
      return;
    }
    if (value is Map) {
      final nested =
          value['effort'] ?? value['level'] ?? value['value'] ?? value['name'];
      if (nested != null) addValue(nested);
    }
  }

  if (raw is List) {
    for (final value in raw) {
      addValue(value);
    }
  } else {
    addValue(raw);
  }
  return out;
}

/// Parses Anthropic's `capabilities.effort` map, where each standard effort
/// key carries `{supported: true/false}`. Non-map inputs fall back to the
/// ordinary list/string normalizer.
Set<String> normalizeOAuthCapabilityEfforts(Object? raw) {
  if (raw is! Map) return normalizeOAuthReasoningEfforts(raw);
  final out = <String>{};
  for (final entry in raw.entries) {
    final effort = entry.key.toString().trim().toLowerCase();
    if (!ReasoningOverride.allEfforts.contains(effort)) continue;
    final value = entry.value;
    if (value is bool) {
      if (value) out.add(effort);
    } else if (value is Map) {
      // Anthropic publishes an explicit `supported` leaf. Missing means
      // unknown, so do not advertise the tier without a true value.
      final supported = value['supported'];
      if (supported == true ||
          (supported is String && supported.trim().toLowerCase() == 'true')) {
        out.add(effort);
      }
    } else if (value is String) {
      final supported = value.trim().toLowerCase();
      if (supported == 'supported' || supported == 'true') out.add(effort);
    }
  }
  return out;
}
