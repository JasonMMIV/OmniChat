// models.dev catalog: parsed in-memory index and lookup ladder.
//
// Pure Dart (no Flutter imports) so the compaction/trimming layer can depend
// on it. The loading/caching/fetching side lives in `model_catalog_service.dart`.
//
// Lookup is exact (no fuzzy matching) in this order:
//   1. provider id + model id
//   2. provider host (from models.dev `provider.api`) + model id
//   3. global model id
//   4. `canonical_model_id`
//   5. normalized model id (lowercase, vendor/provider prefix and
//      `:variant` suffix stripped)
// A miss returns `null` — callers then fall back to their own rules.
library;

import 'dart:convert' as convert;

/// One provider-model entry from the catalog, reduced to the fields OmniChat
/// consumes.
class CatalogModel {
  const CatalogModel({
    required this.modelId,
    required this.providerId,
    this.context,
    this.input,
    this.output,
    this.imageInput = false,
    this.imageOutput = false,
    this.toolCall,
    this.reasoning,
    this.temperatureSupported,
    this.interleaved = false,
    this.interleavedField,
    this.efforts = const <String>{},
    this.hasToggle = false,
    this.budgetMin,
    this.budgetMax,
  });

  final String modelId;
  final String providerId;

  /// `limit.context` — total declared window (null when unknown).
  final int? context;

  /// `limit.input` — input cap; the compaction window prefers this.
  final int? input;

  /// `limit.output` — declared max output tokens.
  final int? output;

  final bool imageInput;
  final bool imageOutput;

  /// `tool_call` / `reasoning`: `null` means the catalog has no opinion
  /// (unknown), which is different from an explicit `false`.
  final bool? toolCall;
  final bool? reasoning;

  /// models.dev `temperature`: whether the model accepts temperature/top_p.
  /// `null` means the catalog has no opinion.
  final bool? temperatureSupported;

  /// `interleaved` present at all (bool true or an object).
  final bool interleaved;

  /// Named replay field when the catalog publishes one
  /// (`reasoning_content` / `reasoning_details`).
  final String? interleavedField;

  /// Effort tiers published under `reasoning_options[type=effort]`. Empty
  /// means "unknown", never "no reasoning".
  final Set<String> efforts;

  /// `reasoning_options[type=toggle]` present.
  final bool hasToggle;

  /// `reasoning_options[type=budget_tokens]` bounds (informational only).
  final int? budgetMin;
  final int? budgetMax;

  /// Output reserve used by the compaction trigger.
  int? get effectiveInputWindow => input ?? context;
}

class _ProviderEntry {
  _ProviderEntry(this.providerId, this.apiHost);

  final String providerId;
  final String apiHost;
  final Map<String, CatalogModel> models = <String, CatalogModel>{};
}

class ModelCatalog {
  ModelCatalog._({
    required Map<String, _ProviderEntry> byProviderId,
    required Map<String, List<CatalogModel>> byModelId,
    required Map<String, CatalogModel> byCanonicalId,
    required Map<String, List<CatalogModel>> byNormalizedId,
    required Map<String, String> providerByHost,
  })  : _byProviderId = byProviderId,
        _byModelId = byModelId,
        _byCanonicalId = byCanonicalId,
        _byNormalizedId = byNormalizedId,
        _providerByHost = providerByHost;

  /// Active catalog. `null` until [loadFromJsonString] (or a test) sets it.
  static ModelCatalog? instance;

  final Map<String, _ProviderEntry> _byProviderId;
  final Map<String, List<CatalogModel>> _byModelId;
  final Map<String, CatalogModel> _byCanonicalId;
  final Map<String, List<CatalogModel>> _byNormalizedId;
  final Map<String, String> _providerByHost;

  /// Known provider ids (models.dev keys, lowercase).
  Iterable<String> get providerIds => _byProviderId.keys;

  /// Parse [json] and install it as [instance].
  static void loadFromJsonString(String json) {
    instance = fromJsonString(json);
  }

  /// Drop the active catalog (used by startup failure paths and tests).
  static void debugReset() {
    instance = null;
  }

  /// Parse a pruned snapshot/refresh payload without touching [instance].
  static ModelCatalog fromJsonString(String json) {
    final decoded = jsonDecodeCatalog(json);
    return _build(decoded);
  }

  static ModelCatalog _build(Map<String, dynamic> root) {
    final byProviderId = <String, _ProviderEntry>{};
    final byModelId = <String, List<CatalogModel>>{};
    final byCanonicalId = <String, CatalogModel>{};
    final byNormalizedId = <String, List<CatalogModel>>{};
    final providerByHost = <String, String>{};

    final providerKeys = root.keys.toList()..sort();
    for (final providerKey in providerKeys) {
      final providerRaw = root[providerKey];
      if (providerRaw is! Map) continue;
      final providerId = providerKey.trim().toLowerCase();
      if (providerId.isEmpty) continue;
      final apiRaw = providerRaw['api'];
      final host = apiRaw is String ? normalizeHost(apiRaw) : '';
      final entry = _ProviderEntry(providerId, host);
      if (host.isNotEmpty && !providerByHost.containsKey(host)) {
        providerByHost[host] = providerId;
      }

      final modelsRaw = providerRaw['models'];
      if (modelsRaw is! Map) {
        byProviderId[providerId] = entry;
        continue;
      }

      final modelKeys = modelsRaw.keys.map((e) => e.toString()).toList()
        ..sort();
      for (final modelKey in modelKeys) {
        final modelRaw = modelsRaw[modelKey];
        if (modelRaw is! Map) continue;
        final modelId = modelKey.trim();
        if (modelId.isEmpty) continue;
        final model = _parseModel(modelId, providerId, modelRaw);
        if (model == null) continue;
        entry.models[modelId.toLowerCase()] = model;
        (byModelId[modelId.toLowerCase()] ??= <CatalogModel>[]).add(model);
        final normalized = normalizeModelId(modelId);
        if (normalized.isNotEmpty) {
          (byNormalizedId[normalized] ??= <CatalogModel>[]).add(model);
        }
        final canonicalRaw = modelRaw['canonical_model_id'];
        if (canonicalRaw is String && canonicalRaw.trim().isNotEmpty) {
          final key = canonicalRaw.trim().toLowerCase();
          byCanonicalId.putIfAbsent(key, () => model);
          final canonicalNormalized = normalizeModelId(canonicalRaw);
          if (canonicalNormalized.isNotEmpty) {
            (byNormalizedId[canonicalNormalized] ??= <CatalogModel>[])
                .add(model);
          }
        }
      }
      byProviderId[providerId] = entry;
    }

    return ModelCatalog._(
      byProviderId: byProviderId,
      byModelId: byModelId,
      byCanonicalId: byCanonicalId,
      byNormalizedId: byNormalizedId,
      providerByHost: providerByHost,
    );
  }

  static CatalogModel? _parseModel(
    String modelId,
    String providerId,
    Map raw,
  ) {
    int? readInt(Object? value) =>
        value is num && value > 0 ? value.toInt() : null;

    final limitRaw = raw['limit'];
    final limit = limitRaw is Map ? limitRaw : const <String, dynamic>{};

    final modalitiesRaw = raw['modalities'];
    final modalities =
        modalitiesRaw is Map ? modalitiesRaw : const <String, dynamic>{};
    final inputRaw = modalities['input'];
    final outputRaw = modalities['output'];
    final inputModalities = inputRaw is List
        ? inputRaw.map((e) => e.toString().toLowerCase()).toSet()
        : const <String>{};
    final outputModalities = outputRaw is List
        ? outputRaw.map((e) => e.toString().toLowerCase()).toSet()
        : const <String>{};

    var interleaved = false;
    String? interleavedField;
    final interleavedRaw = raw['interleaved'];
    if (interleavedRaw is bool) {
      interleaved = interleavedRaw;
    } else if (interleavedRaw is Map) {
      interleaved = true;
      final field = interleavedRaw['field'];
      if (field is String && field.trim().isNotEmpty) {
        interleavedField = field.trim();
      }
    }

    var efforts = const <String>{};
    var hasToggle = false;
    int? budgetMin;
    int? budgetMax;
    final optionsRaw = raw['reasoning_options'];
    if (optionsRaw is List) {
      final collected = <String>{};
      for (final option in optionsRaw) {
        if (option is! Map) continue;
        switch (option['type']) {
          case 'effort':
            final values = option['values'];
            if (values is List) {
              for (final v in values) {
                final value = v.toString().trim().toLowerCase();
                if (value.isNotEmpty) collected.add(value);
              }
            }
          case 'toggle':
            hasToggle = true;
          case 'budget_tokens':
            final min = option['min'];
            final max = option['max'];
            if (min is num && min > 0) budgetMin = min.toInt();
            if (max is num && max > 0) budgetMax = max.toInt();
        }
      }
      efforts = collected;
    }

    final temperatureRaw = raw['temperature'];

    return CatalogModel(
      modelId: modelId,
      providerId: providerId,
      context: readInt(limit['context']),
      input: readInt(limit['input']),
      output: readInt(limit['output']),
      imageInput: inputModalities.contains('image'),
      imageOutput: outputModalities.contains('image'),
      toolCall: raw['tool_call'] is bool ? raw['tool_call'] as bool : null,
      reasoning: raw['reasoning'] is bool ? raw['reasoning'] as bool : null,
      temperatureSupported:
          temperatureRaw is bool ? temperatureRaw : null,
      interleaved: interleaved,
      interleavedField: interleavedField,
      efforts: efforts,
      hasToggle: hasToggle,
      budgetMin: budgetMin,
      budgetMax: budgetMax,
    );
  }

  /// Exact-then-alias lookup. Provider hints narrow the match so a proxy's
  /// variant of a model can differ from the canonical entry.
  CatalogModel? lookup({
    String? providerId,
    String? host,
    required String modelId,
  }) {
    final id = modelId.trim().toLowerCase();
    if (id.isEmpty) return null;

    final pid = providerId?.trim().toLowerCase();
    if (pid != null && pid.isNotEmpty) {
      final viaProvider = _byProviderId[pid]?.models[id];
      if (viaProvider != null) return viaProvider;
    }

    final normalizedHost = normalizeHost(host);
    if (normalizedHost.isNotEmpty) {
      final providerKey = _providerByHost[normalizedHost];
      if (providerKey != null) {
        final viaHost = _byProviderId[providerKey]?.models[id];
        if (viaHost != null) return viaHost;
      }
    }

    final global = _byModelId[id];
    if (global != null && global.isNotEmpty) return global.first;

    final canonical = _byCanonicalId[id];
    if (canonical != null) return canonical;

    final normalized = _byNormalizedId[normalizeModelId(id)];
    if (normalized != null && normalized.isNotEmpty) return normalized.first;

    return null;
  }

  bool hasModel(String modelId) {
    final id = modelId.trim().toLowerCase();
    if (id.isEmpty) return false;
    return _byModelId.containsKey(id) ||
        _byCanonicalId.containsKey(id) ||
        _byNormalizedId.containsKey(normalizeModelId(id));
  }

  /// Compaction window: `limit.input` (input cap) wins over `limit.context`.
  int? windowTokens(
    String modelId, {
    String? providerId,
    String? host,
  }) {
    final model = lookup(providerId: providerId, host: host, modelId: modelId);
    return model?.effectiveInputWindow;
  }

  int? outputTokens(
    String modelId, {
    String? providerId,
    String? host,
  }) =>
      lookup(providerId: providerId, host: host, modelId: modelId)?.output;

  Set<String> efforts(
    String modelId, {
    String? providerId,
    String? host,
  }) =>
      lookup(providerId: providerId, host: host, modelId: modelId)?.efforts ??
      const <String>{};

  /// All models for a provider (used by tests and diagnostics).
  int get modelCount => _byModelId.values.fold(0, (sum, list) => sum + list.length);

  int get providerCount => _byProviderId.length;
}

/// Normalize a base URL / host into a comparable host:
/// lowercase, no scheme/path/port, `api.` and `www.` prefixes removed.
String normalizeHost(String? raw) {
  var host = (raw ?? '').trim().toLowerCase();
  if (host.isEmpty) return '';
  if (host.contains('://')) {
    try {
      host = Uri.parse(host).host.toLowerCase();
    } catch (_) {
      return '';
    }
  }
  final slash = host.indexOf('/');
  if (slash >= 0) host = host.substring(0, slash);
  if (host.startsWith('[')) {
    final close = host.indexOf(']');
    if (close > 0) host = host.substring(0, close + 1);
  } else {
    final colon = host.lastIndexOf(':');
    if (colon > 0) host = host.substring(0, colon);
  }
  for (final prefix in const ['api.', 'www.']) {
    if (host.startsWith(prefix)) {
      host = host.substring(prefix.length);
      break;
    }
  }
  return host;
}

/// Normalize a model id for step 5 of the lookup ladder. Only one vendor/
/// provider prefix is stripped; deeper paths stay intact.
String normalizeModelId(String? raw) {
  var id = (raw ?? '').trim().toLowerCase();
  if (id.isEmpty) return '';
  final colon = id.lastIndexOf(':');
  if (colon > 0) id = id.substring(0, colon);
  final slash = id.indexOf('/');
  if (slash > 0) id = id.substring(slash + 1);
  // Only strip a provider prefix (`openai.`, `anthropic.`), never a version
  // dot: `gpt-5.5` and `claude-sonnet-4.5` must survive intact, otherwise
  // their normalized form collapses to a bare minor version and matches an
  // unrelated model.
  final dot = id.indexOf('.');
  if (dot > 0 && dot + 1 < id.length) {
    final prefix = id.substring(0, dot);
    if (_providerPrefixPattern.hasMatch(prefix)) {
      id = id.substring(dot + 1);
    }
  }
  return id;
}

/// A dot prefix is only a provider name when it has no digits (`openai.`, not
/// the version dot in `gpt-5.5`).
final RegExp _providerPrefixPattern = RegExp(r'^[a-z][a-z_-]*$');

/// Resolve a provider config's identifiers to a models.dev provider id.
///
/// `ProviderConfig.id` is a user-defined key and `providerType` is only a
/// transport kind, so neither is guaranteed to be a models.dev id. Order:
/// explicit id/name match → base URL host match → transport default.
String? resolveCatalogProviderId({
  String? providerId,
  String? providerName,
  String? host,
  String? providerType,
}) {
  final catalog = ModelCatalog.instance;
  if (catalog == null) return null;

  bool known(String? value) {
    final key = (value ?? '').trim().toLowerCase();
    return key.isNotEmpty && catalog._byProviderId.containsKey(key);
  }

  final pid = (providerId ?? '').trim().toLowerCase();
  if (known(pid)) return pid;
  final pname = (providerName ?? '').trim().toLowerCase();
  if (known(pname)) return pname;
  final normalizedHost = normalizeHost(host);
  if (normalizedHost.isNotEmpty) {
    final viaHost = catalog._providerByHost[normalizedHost];
    if (viaHost != null) return viaHost;
  }
  switch ((providerType ?? '').trim().toLowerCase()) {
    case 'openai':
      return known('openai') ? 'openai' : null;
    case 'claude':
      return known('anthropic') ? 'anthropic' : null;
    case 'google':
      return known('google') ? 'google' : null;
    default:
      return null;
  }
}

Map<String, dynamic> jsonDecodeCatalog(String json) {
  final decoded = convert.jsonDecode(json);
  if (decoded is! Map) return const <String, dynamic>{};
  return decoded.cast<String, dynamic>();
}

/// Prune a raw models.dev `api.json` payload to the fields OmniChat keeps.
///
/// Used by both the runtime refresh path (cache file) and
/// `tool/build_model_catalog.dart` (bundled snapshot) so the two can never
/// diverge. Throws [FormatException] when the payload is not a provider map.
String pruneCatalogJson(String rawJson) {
  final decoded = convert.jsonDecode(rawJson);
  if (decoded is! Map) {
    throw const FormatException('models.dev payload is not a map');
  }
  final providers = <String, dynamic>{};
  final providerKeys = decoded.keys.map((e) => e.toString()).toList()..sort();
  for (final providerKey in providerKeys) {
    final provider = decoded[providerKey];
    if (provider is! Map) continue;
    final models = provider['models'];
    if (models is! Map) continue;
    final keptModels = <String, dynamic>{};
    final modelKeys = models.keys.map((e) => e.toString()).toList()..sort();
    for (final modelKey in modelKeys) {
      final model = models[modelKey];
      if (model is! Map) continue;
      final kept = _pruneModel(model);
      if (kept.isEmpty) continue;
      keptModels[modelKey] = kept;
    }
    if (keptModels.isEmpty) continue;
    final api = provider['api'];
    providers[providerKey] = <String, dynamic>{
      if (api is String && api.trim().isNotEmpty) 'api': api.trim(),
      'models': keptModels,
    };
  }
  return convert.jsonEncode(providers);
}

Map<String, dynamic> _pruneModel(Map model) {
  final out = <String, dynamic>{};

  final limit = model['limit'];
  if (limit is Map) {
    final kept = <String, dynamic>{};
    for (final key in const ['context', 'input', 'output']) {
      final value = limit[key];
      if (value is num && value > 0) kept[key] = value.toInt();
    }
    if (kept.isNotEmpty) out['limit'] = kept;
  }

  final modalities = model['modalities'];
  if (modalities is Map) {
    final kept = <String, dynamic>{};
    final input = modalities['input'];
    if (input is List) {
      final values = input.map((e) => e.toString()).toList();
      if (values.isNotEmpty) kept['input'] = values;
    }
    final output = modalities['output'];
    if (output is List) {
      final values = output.map((e) => e.toString()).toList();
      if (values.isNotEmpty) kept['output'] = values;
    }
    if (kept.isNotEmpty) out['modalities'] = kept;
  }

  if (model['tool_call'] is bool) out['tool_call'] = model['tool_call'];
  if (model['reasoning'] is bool) out['reasoning'] = model['reasoning'];
  if (model['temperature'] is bool) out['temperature'] = model['temperature'];

  final interleaved = model['interleaved'];
  if (interleaved is bool) {
    out['interleaved'] = interleaved;
  } else if (interleaved is Map) {
    final field = interleaved['field'];
    out['interleaved'] = <String, dynamic>{
      if (field is String && field.trim().isNotEmpty) 'field': field.trim(),
    };
  }

  final options = model['reasoning_options'];
  if (options is List) {
    final keptOptions = <Map<String, dynamic>>[];
    for (final option in options) {
      if (option is! Map) continue;
      final type = option['type'];
      if (type is! String) continue;
      final kept = <String, dynamic>{'type': type};
      final values = option['values'];
      if (values is List) {
        final strings = values
            .map((e) => e.toString().trim().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toList();
        if (strings.isNotEmpty) kept['values'] = strings;
      }
      final min = option['min'];
      if (min is num) kept['min'] = min.toInt();
      final max = option['max'];
      if (max is num) kept['max'] = max.toInt();
      keptOptions.add(kept);
    }
    if (keptOptions.isNotEmpty) out['reasoning_options'] = keptOptions;
  }

  final canonical = model['canonical_model_id'];
  if (canonical is String && canonical.trim().isNotEmpty) {
    out['canonical_model_id'] = canonical.trim();
  }

  return out;
}
