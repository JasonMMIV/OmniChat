import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:io' show HttpException;
import 'package:http/http.dart' as http;
import 'settings_provider.dart';
import '../models/provider_oauth.dart';
import '../services/auth/oauth_http_client.dart';
import '../services/auth/oauth_pkce.dart';
import '../services/network/dio_http_client.dart';
import '../services/api_key_manager.dart';
import '../services/model_catalog/model_catalog.dart';
import '../services/model_catalog/model_catalog_service.dart';
import '../services/api/opencode.dart';
import 'package:OmniChat/secrets/fallback.dart';
import '../services/api/google_service_account_auth.dart';
import '../services/auth/provider_oauth_service.dart';
import '../utils/reasoning_overrides.dart';
import '../utils/provider_url.dart';

enum ModelType { chat, embedding }

/// Input/output modalities. Values and order intentionally match the
/// models.dev catalog strings and upstream Kelivo's `Modality` enum, so a
/// catalog value maps 1:1 (`Modality.values.byName`).
///
/// Only input modalities are ever advertised in the UI badges; `audio` /
/// `video` in a catalog output list must not imply native chat audio output
/// (multimodal plan §2.1-5).
enum Modality { text, image, audio, video, pdf }

enum ModelAbility { tool, reasoning }

class ModelInfo {
  final String id;
  final String displayName;
  final ModelType type;
  final List<Modality> input;
  final List<Modality> output;
  final List<ModelAbility> abilities;

  /// Effective input window in tokens (`limit.input` of the models.dev
  /// catalog, else `limit.context`, or the user's override). Null when
  /// unknown. Display only for the chip; the compaction/ring window resolves
  /// the same value through its own chain.
  final int? contextWindow;

  /// Declared max output tokens (`limit.output` of the models.dev catalog,
  /// or the user's override). Null when unknown.
  final int? maxOutput;

  ModelInfo({
    required this.id,
    required this.displayName,
    this.type = ModelType.chat,
    this.input = const [Modality.text],
    this.output = const [Modality.text],
    this.abilities = const [],
    this.contextWindow,
    this.maxOutput,
  });

  /// `null` arguments keep the current value. `contextWindow` / `maxOutput`
  /// therefore cannot be cleared through [copyWith]; override resolution
  /// always builds a new object with the base as the fallback instead.
  ModelInfo copyWith({
    String? id,
    String? displayName,
    ModelType? type,
    List<Modality>? input,
    List<Modality>? output,
    List<ModelAbility>? abilities,
    int? contextWindow,
    int? maxOutput,
  }) => ModelInfo(
    id: id ?? this.id,
    displayName: displayName ?? this.displayName,
    type: type ?? this.type,
    input: input ?? this.input,
    output: output ?? this.output,
    abilities: abilities ?? this.abilities,
    contextWindow: contextWindow ?? this.contextWindow,
    maxOutput: maxOutput ?? this.maxOutput,
  );
}

class ModelRegistry {
  // Updated model groups to reflect new series
  // Vision-capable models (text + image input)
  static final RegExp vision = RegExp(
    // GPT family incl. 4o, 4.1, 5 (exclude gpt-5-chat), and OpenAI o* series
    r'(gpt-4o|gpt-4\.1|gpt-5(?!-chat)|o\d|gemini|claude|kimi-k2([-.])(?:5|6|7)|doubao.+1([-.])6|grok-4|step-3|intern-s1|muse-spark)',
    caseSensitive: false,
  );
  // Tool-using models
  static final RegExp tool = RegExp(
    (r'(gpt-4o|gpt-4\.1|gpt-oss|gpt-5(?!-chat)|o\d|'
            r'gemini|claude|'
            r'qwen-?3|doubao.+1([-.])6|grok-4|kimi-k(?:2|3)|'
            r'step-3|intern-s1|glm-4([-.])(?:5|6|7)|glm-5|minimax-m2|'
            r'deepseek-(?:r1|v3|v4|chat|v3\.1|v3\.2)|'
            r'deepseek-reasoner|'
            r'mimo-v2-flash|muse-spark'
            r')')
        .replaceAll(' ', ''),
    caseSensitive: false,
  );
  // Audio-input families that predate catalog coverage / appear under
  // aggregator ids the catalog does not know. Only consulted on a catalog
  // miss (the catalog hit returns early below).
  static final RegExp audioInput = RegExp(
    r'(qwen.*(omni|audio)|gemini.*(audio|native-audio|omni)|gpt-4o.*audio|step.*audio|glm.*(omni|audio))',
    caseSensitive: false,
  );
  // Native PDF input families (Claude / Gemini / GPT-4.1+ / Grok).
  static final RegExp pdfInput = RegExp(
    r'(claude|gemini-\d|gpt-(4\.1|4o|5)|grok-\d)',
    caseSensitive: false,
  );
  // Native video-input families.
  static final RegExp videoInput = RegExp(
    r'(gemini-\d|qwen.*(vl|omni)|minimax-m3|doubao|step-3|glm-4.?v)',
    caseSensitive: false,
  );

  static final RegExp reasoning = RegExp(
    (r'(gpt-oss|gpt-5(?!-chat)|o\d|'
            r'gemini-(?:2\.5|3).*|gemini-(?:flash-latest|pro-latest)|'
            r'gemini-3-pro-image-preview|'
            r'claude|'
            r'qwen-?3|doubao.+1([-.])6|grok-4|kimi-k(?:2|3)|'
            r'step-3|intern-s1|glm-4([-.])(?:5|6|7)|glm-5|minimax-m2|'
            r'deepseek-(?:r1|v3\.1|v3\.2|v4)|'
            r'deepseek-reasoner|'
            r'mimo-v2-flash|muse-spark'
            r')')
        .replaceAll(' ', ''),
    caseSensitive: false,
  );

  /// Map a models.dev catalog modality string to [Modality]. Unknown values
  /// return null — they must never silently become `text` (plan §7 F7).
  static Modality? modalityFromCatalogValue(String raw) {
    final value = raw.trim().toLowerCase();
    for (final m in Modality.values) {
      if (m.name == value) return m;
    }
    return null;
  }

  static String modalityToCatalogValue(Modality m) => m.name;

  /// Version stamped on `modelOverrides[id]['input']` by the model detail
  /// sheet. Missing/older means the override predates audio/video/pdf and
  /// must not be treated as an intentional exclusion of those modalities.
  static const int inputOverrideVersion = 2;

  /// Shared parser for `modelOverrides[id]['input' | 'output']`.
  ///
  /// Returns null when the key is absent / not a list, so callers keep the
  /// inferred list. Unknown entries are skipped (not mapped to `text`, which
  /// used to silently downgrade audio/video/pdf).
  static List<Modality>? parseModalities(Object? raw) {
    if (raw is! List) return null;
    final out = <Modality>[];
    for (final entry in raw) {
      final mod = modalityFromCatalogValue(entry.toString());
      if (mod != null && !out.contains(mod)) out.add(mod);
    }
    return out.isEmpty ? null : out;
  }

  /// Shared parser for `modelOverrides[id]['abilities']`.
  ///
  /// An explicit empty list is preserved: "no abilities" is a valid user
  /// choice and must not silently re-enable the inferred defaults. Malformed
  /// non-empty lists return null so callers keep the inferred values.
  static List<ModelAbility>? parseAbilities(Object? raw) {
    if (raw is! List) return null;
    final out = <ModelAbility>[];
    for (final entry in raw) {
      final value = entry.toString().trim().toLowerCase();
      final ability = switch (value) {
        'reasoning' => ModelAbility.reasoning,
        'tool' => ModelAbility.tool,
        _ => null,
      };
      if (ability != null && !out.contains(ability)) out.add(ability);
    }
    if (out.isEmpty && raw.isNotEmpty) return null;
    return out;
  }

  /// Apply the user's per-model override on top of an inferred [ModelInfo].
  ///
  /// This is the single override reader for the transport, the model picker,
  /// the provider page and the model detail sheet (multimodal plan §7 F7).
  static ModelInfo applyOverride(ModelInfo base, Map? override) {
    if (override == null) return base;
    ModelType? type;
    final rawType = (override['type'] as String?)?.trim().toLowerCase();
    if (rawType == 'embedding') {
      type = ModelType.embedding;
    } else if (rawType == 'chat') {
      type = ModelType.chat;
    }
    final name = (override['name'] as String?)?.trim();
    final input = parseModalities(override['input']);
    final output = parseModalities(override['output']);
    final abilities = parseAbilities(override['abilities']);
    final contextWindow = parseIntOverride(override['contextWindow']);
    final maxOutput = parseIntOverride(override['maxOutput']);

    // Legacy override migration (multimodal rollout): before the Modality
    // enum grew, every saved model detail wrote `input: ['text','image']`.
    // Those values cannot represent an intentional audio/video/pdf exclusion,
    // so merge the inferred new modalities back in. A version-2 override is
    // respected verbatim (the user can explicitly remove them).
    List<Modality>? effectiveInput;
    if (input != null) {
      effectiveInput = List<Modality>.of(input);
      final version = override['inputV'];
      final legacy =
          version is! num || version.toInt() < inputOverrideVersion;
      if (legacy) {
        for (final modality in base.input) {
          final isNewDimension =
              modality == Modality.audio ||
              modality == Modality.video ||
              modality == Modality.pdf;
          if (isNewDimension && !effectiveInput.contains(modality)) {
            effectiveInput.add(modality);
          }
        }
      }
    }

    return base.copyWith(
      displayName: (name != null && name.isNotEmpty) ? name : base.displayName,
      type: type ?? base.type,
      input: effectiveInput ?? base.input,
      output: output ?? base.output,
      abilities: abilities ?? base.abilities,
      contextWindow: contextWindow ?? base.contextWindow,
      maxOutput: maxOutput ?? base.maxOutput,
    );
  }

  /// Resolve the effective model info for a logical key in [cfg]: map the
  /// upstream `apiModelId` (normalizing OpenCode ids), infer capabilities from
  /// that id, then apply the per-model override.
  ///
  /// Single source of truth for the transport and the capability checks; it
  /// replaces readers that parsed raw `modelOverrides` maps on their own.
  static ModelInfo effectiveForModel(ProviderConfig cfg, String modelId) {
    final rawOverride = cfg.modelOverrides[modelId];
    final override = rawOverride is Map ? rawOverride : null;
    var upstreamId = modelId;
    final raw = (override?['apiModelId'] ?? override?['api_model_id'])
        ?.toString()
        .trim();
    if (raw != null && raw.isNotEmpty) upstreamId = raw;
    if (isOpenCodeBaseUrl(cfg.baseUrl)) {
      upstreamId = normalizeOpenCodeModelId(upstreamId);
    }
    return applyOverride(
      infer(ModelInfo(id: upstreamId, displayName: upstreamId)),
      override,
    );
  }

  /// Shared parser for user-editable integer overrides (`contextWindow` /
  /// `maxOutput`). Returns null for absent / non-numeric / non-positive
  /// values so callers keep the inferred value.
  static int? parseIntOverride(Object? raw) {
    if (raw is num) {
      final value = raw.toInt();
      return value > 0 ? value : null;
    }
    if (raw is String) {
      final value = int.tryParse(raw.trim());
      return value != null && value > 0 ? value : null;
    }
    return null;
  }

  /// Infer capabilities for a model, consulting the models.dev catalog first
  /// (global model id) and falling back to the built-in regexes on a miss.
  static ModelInfo infer(ModelInfo base) =>
      _inferWithCatalog(base, ModelCatalog.instance?.lookup(modelId: base.id));

  /// Provider-aware variant used by provider model lists: a proxy/aggregator's
  /// same-named model resolves to its own catalog entry first.
  static ModelInfo inferForProvider(ModelInfo base, ProviderConfig cfg) {
    final catalog = ModelCatalog.instance;
    final normalizedId = isOpenCodeBaseUrl(cfg.baseUrl)
        ? normalizeOpenCodeModelId(base.id)
        : base.id;
    final probe = normalizedId == base.id
        ? base
        : base.copyWith(id: normalizedId);
    final inferred = _inferWithCatalog(
      probe,
      catalog?.lookup(
        providerId: cfg.catalogProviderId,
        host: cfg.catalogHost,
        modelId: normalizedId,
      ),
    );
    // Keep the user's logical id/display name; only the capability probe uses
    // the bare upstream id. An empty base name must not erase a catalog name.
    return normalizedId == base.id
        ? inferred
        : inferred.copyWith(
            id: base.id,
            displayName: base.displayName.isEmpty
                ? inferred.displayName
                : base.displayName,
          );
  }

  static ModelInfo _inferWithCatalog(ModelInfo base, CatalogModel? catalog) {
    final id = base.id.toLowerCase();
    final inMods = <Modality>[...base.input];
    final outMods = <Modality>[...base.output];
    final ab = <ModelAbility>[...base.abilities];
    // If model id contains 'image' (or matches image-family ids like
    // dall-e-* / sensenova-u1-fast), treat it as an image model:
    // - Output includes image
    // - Input includes image EXCEPT for known text-to-image-only models
    //   (dall-e-3, sensenova-u1-fast): no image input -> not edit-capable
    //   via /images/edits. dall-e-2 keeps image input (OpenAI supports its
    //   edits endpoint).
    // - No tool or reasoning abilities
    if (id.contains('image') ||
        RegExp(r'(dall-e-|sensenova-u1-fast)').hasMatch(id)) {
      final textToImageOnly =
          id.contains('dall-e-3') || id.contains('sensenova-u1-fast');
      if (!outMods.contains(Modality.image)) outMods.add(Modality.image);
      if (!textToImageOnly && !inMods.contains(Modality.image)) {
        inMods.add(Modality.image);
      }
      ab.removeWhere(
        (x) => x == ModelAbility.tool || x == ModelAbility.reasoning,
      );
      return base.copyWith(
        input: inMods,
        output: outMods,
        abilities: ab,
        // Image-family ids still have catalog token limits; keep them so the
        // chip and the sheet's Token limits defaults do not disappear.
        contextWindow: catalog?.effectiveInputWindow,
        maxOutput: catalog?.output,
      );
    }
    if (catalog != null) {
      // Catalog hit: capabilities come from the catalog, not the regexes
      // (plan D1). Output modality deliberately stays on the existing image-id
      // rules so `/images` routing cannot change.
      if (catalog.imageInput && !inMods.contains(Modality.image)) {
        inMods.add(Modality.image);
      }
      // Multimodal plan A1: the catalog already carries audio/video/pdf —
      // project them instead of dropping the data on the floor.
      for (final raw in catalog.inputModalities) {
        final mod = modalityFromCatalogValue(raw);
        if (mod != null && !inMods.contains(mod)) inMods.add(mod);
      }
      if (catalog.toolCall == true) {
        if (!ab.contains(ModelAbility.tool)) ab.add(ModelAbility.tool);
      } else if (catalog.toolCall == false) {
        ab.remove(ModelAbility.tool);
      }
      if (catalog.reasoning == true) {
        if (!ab.contains(ModelAbility.reasoning)) {
          ab.add(ModelAbility.reasoning);
        }
      } else if (catalog.reasoning == false) {
        ab.remove(ModelAbility.reasoning);
      }
      return base.copyWith(
        input: inMods,
        output: outMods,
        abilities: ab,
        contextWindow: catalog.effectiveInputWindow,
        maxOutput: catalog.output,
      );
    }
    if (vision.hasMatch(id)) {
      if (!inMods.contains(Modality.image)) inMods.add(Modality.image);
    }
    // Multimodal plan A1: minimal family rules, catalog-miss only.
    if (audioInput.hasMatch(id) && !inMods.contains(Modality.audio)) {
      inMods.add(Modality.audio);
    }
    if (pdfInput.hasMatch(id) && !inMods.contains(Modality.pdf)) {
      inMods.add(Modality.pdf);
    }
    if (videoInput.hasMatch(id) && !inMods.contains(Modality.video)) {
      inMods.add(Modality.video);
    }
    if (tool.hasMatch(id) && !ab.contains(ModelAbility.tool))
      ab.add(ModelAbility.tool);
    if (reasoning.hasMatch(id) && !ab.contains(ModelAbility.reasoning))
      ab.add(ModelAbility.reasoning);
    return base.copyWith(input: inMods, output: outMods, abilities: ab);
  }
}

abstract class BaseProvider {
  Future<List<ModelInfo>> listModels(ProviderConfig cfg);
  Future<String> getBalance(ProviderConfig cfg);
}

class _JsonUtils {
  static dynamic getByPath(dynamic json, String path) {
    if (path.isEmpty) return json;
    final parts = path.split('.');
    dynamic current = json;
    for (var part in parts) {
      if (current == null) return null;
      // Handle array access like balance_infos[0]
      if (part.contains('[') && part.endsWith(']')) {
        final openBracket = part.indexOf('[');
        final key = part.substring(0, openBracket);
        final index = int.tryParse(
          part.substring(openBracket + 1, part.length - 1),
        );
        if (key.isNotEmpty) {
          current = current[key];
        }
        if (current is List && index != null && index < current.length) {
          current = current[index];
        } else {
          return null;
        }
      } else {
        if (current is Map) {
          current = current[part];
        } else {
          return null;
        }
      }
    }
    return current;
  }

  static dynamic eval(dynamic json, String expr) {
    if (expr.contains(' - ')) {
      final parts = expr.split(' - ');
      if (parts.length == 2) {
        final v1 = getByPath(json, parts[0].trim());
        final v2 = getByPath(json, parts[1].trim());
        final n1 = v1 is num ? v1 : num.tryParse(v1?.toString() ?? '0') ?? 0;
        final n2 = v2 is num ? v2 : num.tryParse(v2?.toString() ?? '0') ?? 0;
        return n1 - n2;
      }
    }
    return getByPath(json, expr);
  }
}

class _Http {
  static http.Client clientFor(ProviderConfig cfg) {
    final enabled = cfg.proxyEnabled == true;
    final host = (cfg.proxyHost ?? '').trim();
    final portStr = (cfg.proxyPort ?? '').trim();
    final user = (cfg.proxyUsername ?? '').trim();
    final pass = (cfg.proxyPassword ?? '').trim();
    if (enabled && host.isNotEmpty && portStr.isNotEmpty) {
      final port = int.tryParse(portStr) ?? 8080;
      return DioHttpClient(
        proxy: NetworkProxyConfig(
          enabled: true,
          host: host,
          port: port,
          username: user.isEmpty ? null : user,
          password: pass.isEmpty ? null : pass,
        ),
      );
    }
    return DioHttpClient();
  }
}

class OpenAIProvider extends BaseProvider {
  @override
  Future<List<ModelInfo>> listModels(ProviderConfig cfg) async {
    final key = ProviderManager._effectiveApiKey(cfg);
    final client = _Http.clientFor(cfg);
    try {
      final uri = Uri.parse('${cfg.baseUrl}/models');
      final headers = <String, String>{};
      if (key.isNotEmpty) headers['Authorization'] = 'Bearer $key';
      final res = await client.get(uri, headers: headers);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = (jsonDecode(res.body)['data'] as List?) ?? [];
        return [
          for (final e in data)
            if (e is Map && e['id'] is String)
              ModelRegistry.inferForProvider(
                ModelInfo(
                  id: e['id'] as String,
                  displayName: e['id'] as String,
                ),
                cfg,
              ),
        ];
      }
      return [];
    } finally {
      client.close();
    }
  }

  @override
  Future<String> getBalance(ProviderConfig cfg) async {
    if (cfg.balanceEnabled != true || (cfg.balanceApiPath ?? '').isEmpty)
      return '';
    final key = ProviderManager._effectiveApiKey(cfg);
    final client = _Http.clientFor(cfg);
    try {
      final base = cfg.baseUrl.endsWith('/')
          ? cfg.baseUrl.substring(0, cfg.baseUrl.length - 1)
          : cfg.baseUrl;
      final path = cfg.balanceApiPath!.startsWith('/')
          ? cfg.balanceApiPath!
          : '/${cfg.balanceApiPath!}';
      final uri = cfg.balanceApiPath!.startsWith('http')
          ? Uri.parse(cfg.balanceApiPath!)
          : Uri.parse('$base$path');

      final headers = <String, String>{};
      if (key.isNotEmpty) headers['Authorization'] = 'Bearer $key';

      // OpenRouter specific headers to avoid blocking and comply with docs
      if (uri.host.contains('openrouter')) {
        headers['HTTP-Referer'] = 'https://github.com/MixinNetwork/OmniChat';
        headers['X-Title'] = 'OmniChat';
        headers['User-Agent'] = 'OmniChat/1.0';
      }

      print('[Balance Debug] Request: $uri');
      print('[Balance Debug] Headers: $headers');

      final res = await client.get(uri, headers: headers);

      print('[Balance Debug] Status: ${res.statusCode}');
      print('[Balance Debug] Body: ${res.body}');

      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body);
        final value = _JsonUtils.eval(data, cfg.balanceResultKey ?? '');
        print(
          '[Balance Debug] Extracted value: $value using key: ${cfg.balanceResultKey}',
        );
        if (value != null) {
          if (value is num) {
            // If it's a small number, assume it's USD and format it.
            // If it's a large number, might be points/tokens.
            if (value < 1000) return '\$${value.toStringAsFixed(2)}';
            return value.toString();
          }
          return value.toString();
        }
      }
      return '';
    } catch (_) {
      return '';
    } finally {
      client.close();
    }
  }
}

class ClaudeProvider extends BaseProvider {
  static const String anthropicVersion = '2023-06-01';
  @override
  Future<List<ModelInfo>> listModels(ProviderConfig cfg) async {
    final key = ProviderManager._effectiveApiKey(cfg);
    final client = _Http.clientFor(cfg);
    try {
      final uri = Uri.parse('${cfg.baseUrl}/models');
      final headers = <String, String>{'anthropic-version': anthropicVersion};
      if (key.isNotEmpty) headers['x-api-key'] = key;
      final res = await client.get(uri, headers: headers);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final obj = jsonDecode(res.body) as Map<String, dynamic>;
        final data = (obj['data'] as List?) ?? [];
        return [
          for (final e in data)
            if (e is Map && e['id'] is String)
              ModelRegistry.inferForProvider(
                ModelInfo(
                  id: e['id'] as String,
                  displayName:
                      (e['display_name'] as String?) ?? (e['id'] as String),
                ),
                cfg,
              ),
        ];
      }
      return [];
    } finally {
      client.close();
    }
  }

  @override
  Future<String> getBalance(ProviderConfig cfg) async {
    // Anthropic official API doesn't have a simple balance endpoint for keys.
    // If user provided a custom one via ProviderConfig, we could try OpenAI logic.
    if (cfg.balanceEnabled == true && (cfg.balanceApiPath ?? '').isNotEmpty) {
      return await OpenAIProvider().getBalance(cfg);
    }
    return '';
  }
}

class GoogleProvider extends BaseProvider {
  String _buildUrl(ProviderConfig cfg) {
    if (cfg.vertexAI == true &&
        (cfg.location?.isNotEmpty == true) &&
        (cfg.projectId?.isNotEmpty == true)) {
      final loc = cfg.location!;
      final proj = cfg.projectId!;
      return 'https://aiplatform.googleapis.com/v1/projects/$proj/locations/$loc/publishers/google/models';
    }
    final base = cfg.baseUrl.endsWith('/')
        ? cfg.baseUrl.substring(0, cfg.baseUrl.length - 1)
        : cfg.baseUrl;
    return '$base/models';
  }

  @override
  Future<List<ModelInfo>> listModels(ProviderConfig cfg) async {
    final client = _Http.clientFor(cfg);
    try {
      final url = _buildUrl(cfg);
      final headers = <String, String>{};
      if (cfg.vertexAI == true) {
        final jsonStr = (cfg.serviceAccountJson ?? '').trim();
        if (jsonStr.isNotEmpty) {
          try {
            final token = await GoogleServiceAccountAuth.getAccessTokenFromJson(
              jsonStr,
            );
            headers['Authorization'] = 'Bearer $token';
            final proj = (cfg.projectId ?? '').trim();
            if (proj.isNotEmpty) headers['X-Goog-User-Project'] = proj;
          } catch (_) {}
        } else {
          final key = ProviderManager._effectiveApiKey(cfg);
          if (key.isNotEmpty) {
            // Fallback: treat apiKey as a bearer token if user pasted one
            headers['Authorization'] = 'Bearer $key';
          }
        }
      } else {
        final key = ProviderManager._effectiveApiKey(cfg);
        if (key.isNotEmpty) {
          headers['x-goog-api-key'] = key;
        }
      }
      final res = await client.get(Uri.parse(url), headers: headers);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final obj = jsonDecode(res.body) as Map<String, dynamic>;
        final arr = (obj['models'] as List?) ?? [];
        final out = <ModelInfo>[];
        for (final e in arr) {
          if (e is Map) {
            final name = (e['name'] as String?) ?? '';
            final id = name.startsWith('models/')
                ? name.substring('models/'.length)
                : name;
            final displayName = (e['displayName'] as String?) ?? id;
            final methods =
                (e['supportedGenerationMethods'] as List?)
                    ?.map((m) => m.toString())
                    .toSet() ??
                {};
            if (!(methods.contains('generateContent') ||
                methods.contains('embedContent')))
              continue;
            out.add(
              ModelRegistry.inferForProvider(
                ModelInfo(
                  id: id,
                  displayName: displayName,
                  type: methods.contains('generateContent')
                      ? ModelType.chat
                      : ModelType.embedding,
                ),
                cfg,
              ),
            );
          }
        }
        return out;
      }
      return [];
    } finally {
      client.close();
    }
  }

  @override
  Future<String> getBalance(ProviderConfig cfg) async {
    if (cfg.balanceEnabled == true && (cfg.balanceApiPath ?? '').isNotEmpty) {
      return await OpenAIProvider().getBalance(cfg);
    }
    return '';
  }
}

class NeuralwattProvider extends BaseProvider {
  String _base(ProviderConfig cfg) {
    final raw = cfg.baseUrl.trim().isEmpty
        ? 'https://api.neuralwatt.com/v1'
        : cfg.baseUrl.trim();
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  @override
  Future<List<ModelInfo>> listModels(ProviderConfig cfg) async {
    final key = ProviderManager._effectiveApiKey(cfg);
    final client = _Http.clientFor(cfg);
    try {
      final uri = Uri.parse('${_base(cfg)}/models');
      final headers = <String, String>{};
      if (key.isNotEmpty) headers['Authorization'] = 'Bearer $key';

      final res = await client.get(uri, headers: headers);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final obj = jsonDecode(res.body) as Map<String, dynamic>;
        final data = (obj['data'] as List?) ?? const <dynamic>[];
        return [
          for (final e in data)
            if (e is Map && e['id'] is String)
              _fromModelJson(e.cast<String, dynamic>(), cfg),
        ];
      }
      return [];
    } finally {
      client.close();
    }
  }

  ModelInfo _fromModelJson(Map<String, dynamic> e, ProviderConfig cfg) {
    final id = e['id'] as String;
    final meta = e['metadata'];
    final metaMap = meta is Map
        ? meta.cast<String, dynamic>()
        : const <String, dynamic>{};
    final displayName = (metaMap['display_name'] as String?)?.trim();
    final capsRaw = metaMap['capabilities'];
    final caps = capsRaw is Map
        ? capsRaw.cast<String, dynamic>()
        : const <String, dynamic>{};
    final deprecated = metaMap['deprecated'] == true;

    final input = <Modality>[Modality.text];
    if (caps['vision'] == true && !input.contains(Modality.image)) {
      input.add(Modality.image);
    }

    final abilities = <ModelAbility>[];
    if (caps['tools'] == true) abilities.add(ModelAbility.tool);
    if (caps['reasoning'] == true || caps['reasoning_effort'] == true) {
      abilities.add(ModelAbility.reasoning);
    }

    final name = (displayName != null && displayName.isNotEmpty)
        ? displayName
        : id;

    final effectiveName = deprecated ? '$name (deprecated)' : name;

    return ModelRegistry.inferForProvider(
      ModelInfo(
        id: id,
        displayName: effectiveName,
        input: input,
        output: const [Modality.text],
        abilities: abilities,
      ),
      cfg,
    );
  }

  @override
  Future<String> getBalance(ProviderConfig cfg) async {
    final key = ProviderManager._effectiveApiKey(cfg);
    if (key.trim().isEmpty) return '';

    final client = _Http.clientFor(cfg);
    try {
      final uri = Uri.parse('${_base(cfg)}/quota');
      final res = await client.get(
        uri,
        headers: {'Authorization': 'Bearer $key'},
      );

      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body);
        final value = _JsonUtils.eval(data, 'balance.credits_remaining_usd');
        if (value is num) return '\$${value.toStringAsFixed(2)}';
        if (value != null) return value.toString();
      }
      return '';
    } catch (_) {
      return '';
    } finally {
      client.close();
    }
  }
}

class ProviderManager {
  static String _effectiveApiKey(ProviderConfig cfg) {
    try {
      if (cfg.multiKeyEnabled == true && (cfg.apiKeys?.isNotEmpty == true)) {
        final sel = ApiKeyManager().selectForProvider(cfg);
        if (sel.key != null) return sel.key!.key;
      }
    } catch (_) {}
    return cfg.apiKey;
  }

  /// Treat Neuralwatt as OpenAI-compatible for chat API request format.
  static ProviderKind _apiKind(ProviderConfig cfg) {
    final kind = ProviderConfig.classify(
      cfg.id,
      explicitType: cfg.providerType,
    );
    return kind == ProviderKind.neuralwatt ? ProviderKind.openai : kind;
  }

  // Per-model override helpers (duplicated logic from ChatApiService)
  static Map<String, dynamic> _modelOverride(
    ProviderConfig cfg,
    String modelId,
  ) {
    final ov = cfg.modelOverrides[modelId];
    if (ov is Map<String, dynamic>) return ov;
    return const <String, dynamic>{};
  }

  static Map<String, String> _customHeaders(
    ProviderConfig cfg,
    String modelId,
  ) {
    final ov = _modelOverride(cfg, modelId);
    final list = (ov['headers'] as List?) ?? const <dynamic>[];
    final out = <String, String>{};
    for (final e in list) {
      if (e is Map) {
        final name = (e['name'] ?? e['key'] ?? '').toString().trim();
        final value = (e['value'] ?? '').toString();
        if (name.isNotEmpty) out[name] = value;
      }
    }
    return out;
  }

  static dynamic _parseOverrideValue(String v) {
    final s = v.trim();
    if (s.isEmpty) return s;
    if (s == 'true') return true;
    if (s == 'false') return false;
    if (s == 'null') return null;
    final i = int.tryParse(s);
    if (i != null) return i;
    final d = double.tryParse(s);
    if (d != null) return d;
    if ((s.startsWith('{') && s.endsWith('}')) ||
        (s.startsWith('[') && s.endsWith(']'))) {
      try {
        return jsonDecode(s);
      } catch (_) {}
    }
    return v;
  }

  static Map<String, dynamic> _customBody(ProviderConfig cfg, String modelId) {
    final ov = _modelOverride(cfg, modelId);
    final list = (ov['body'] as List?) ?? const <dynamic>[];
    final out = <String, dynamic>{};
    for (final e in list) {
      if (e is Map) {
        final key = (e['key'] ?? e['name'] ?? '').toString().trim();
        final val = (e['value'] ?? '').toString();
        if (key.isNotEmpty) out[key] = _parseOverrideValue(val);
      }
    }
    return out;
  }

  static BaseProvider forConfig(ProviderConfig cfg) {
    final kind = ProviderConfig.classify(
      cfg.id,
      explicitType: cfg.providerType,
    );
    switch (kind) {
      case ProviderKind.google:
        return GoogleProvider();
      case ProviderKind.claude:
        return ClaudeProvider();
      case ProviderKind.neuralwatt:
        return NeuralwattProvider();
      case ProviderKind.openai:
      default:
        return OpenAIProvider();
    }
  }

  static Future<List<ModelInfo>> listModels(ProviderConfig cfg) async {
    // OAuth accounts never use the API-key `/models` path: the subscription
    // endpoints have their own listing (plan §4.2 G6). Abilities/modalities
    // come from the synced override the service wrote, so inference here is
    // only a display fallback.
    if (cfg.oauthProvider != null) {
      final entries = await ProviderOAuthService.instance.fetchModels(cfg);
      return <ModelInfo>[
        for (final entry in entries)
          if (entry.id.trim().isNotEmpty)
            ModelRegistry.inferForProvider(
              ModelInfo(id: entry.id, displayName: entry.displayName),
              cfg,
            ),
      ];
    }
    final models = await forConfig(cfg).listModels(cfg);
    // Catalog refresh trigger (plan batch 1 §6.3): a successful provider list
    // fetch is a good moment to pick up new models. Fire-and-forget — the
    // list must render immediately.
    if (models.isNotEmpty) refreshCatalogIfStale(cfg);
    return models;
  }

  /// Refresh the models.dev catalog when it is older than 30 days, reusing the
  /// provider's proxy client. Never throws; failures keep the current catalog.
  ///
  /// OpenCode is refreshed first on its own 1-day cadence; the overlay is what
  /// carries Console/Zen/Go-only models that models.dev may not know yet.
  static void refreshCatalogIfStale(ProviderConfig cfg, {int days = 30}) {
    _runCatalogRefresh((client) async {
      if (isOpenCodeBaseUrl(cfg.baseUrl)) {
        await ModelCatalogService.instance.refreshOpenCodeIfStale(
          days: 1,
          client: client,
        );
      }
      await ModelCatalogService.instance.refreshIfStale(
        days: days,
        client: client,
      );
    }, cfg);
  }

  /// Refresh the catalog when [apiModelId] is unknown, so a newly added model
  /// can pick up its window/capabilities. Catalog hits skip the request.
  static void refreshCatalogForModel(ProviderConfig cfg, String apiModelId) {
    _runCatalogRefresh((client) async {
      if (isOpenCodeBaseUrl(cfg.baseUrl)) {
        await ModelCatalogService.instance.refreshOpenCodeForModel(
          apiModelId,
          providerId: cfg.catalogProviderId,
          host: cfg.catalogHost,
          client: client,
        );
      }
      await ModelCatalogService.instance.refreshForModel(
        apiModelId,
        client: client,
      );
    }, cfg);
  }

  static void _runCatalogRefresh(
    Future<void> Function(http.Client client) body,
    ProviderConfig cfg,
  ) {
    unawaited(
      Future<void>(() async {
        http.Client? client;
        try {
          client = _Http.clientFor(cfg);
          await body(client);
        } catch (_) {
          // The catalog is an enhancement; a failed refresh is a no-op.
        } finally {
          client?.close();
        }
      }),
    );
  }

  static Future<String> getBalance(ProviderConfig cfg) {
    return forConfig(cfg).getBalance(cfg);
  }

  static Future<void> testConnection(
    ProviderConfig cfg,
    String modelId, {
    bool useStream = false,
  }) async {
    // Kimi's per-model protocol decides whether this is Claude Messages or
    // OpenAI chat completions (plan M6).
    cfg = cfg.forModelProtocol(modelId);
    // Codex subscription endpoints are stream-only.
    if (cfg.oauthProvider == OAuthProvider.chatgpt) useStream = true;
    final kind = _apiKind(cfg);
    final inner = _Http.clientFor(cfg);
    // Connection tests must go through the same auth/shaping wrapper as chat;
    // otherwise every OAuth account is tested with empty API-key headers.
    final client = cfg.oauthProvider == null
        ? inner
        : OAuthHttpClient(
            inner: inner,
            config: cfg,
            sessionId: oauthStableUuid('${cfg.id}:$modelId:connection'),
          );
    try {
      if (kind == ProviderKind.openai) {
        final url = Uri.parse(
          resolveProviderRequestUrl(
            baseUrl: cfg.baseUrl,
            providerType: 'openai',
            modelId: modelId,
            chatPath: cfg.chatPath,
            useResponses: cfg.useResponseApi == true,
          ).url,
        );
        final body = cfg.useResponseApi == true
            ? {
                'model': modelId,
                'input': [
                  {'role': 'user', 'content': 'hello'},
                ],
                if (useStream) 'stream': true,
              }
            : {
                'model': modelId,
                'messages': [
                  {'role': 'user', 'content': 'hello'},
                ],
                if (useStream) 'stream': true,
              };
        // Merge custom body overrides
        final extra = _customBody(cfg, modelId);
        if (extra.isNotEmpty) (body as Map<String, dynamic>).addAll(extra);
        // Merge custom headers overrides
        // SiliconFlow fallback key for built-in free models when no API key provided
        String apiKey = _effectiveApiKey(cfg);
        try {
          if ((cfg.id) == 'SiliconFlow') {
            final host = Uri.tryParse(cfg.baseUrl)?.host.toLowerCase() ?? '';
            if (host.contains('siliconflow') && apiKey.trim().isEmpty) {
              final m = modelId.toLowerCase();
              final allowed =
                  m == 'thudm/glm-4-9b-0414' || m == 'qwen/qwen3-8b';
              final fb = siliconflowFallbackKey.trim();
              if (allowed && fb.isNotEmpty) apiKey = fb;
            }
          }
        } catch (_) {}
        final headers = <String, String>{
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        };
        headers.addAll(_customHeaders(cfg, modelId));
        final res = await client.post(
          url,
          headers: headers,
          body: jsonEncode(body),
        );
        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw HttpException('HTTP ${res.statusCode}: ${res.body}');
        }
        // For streaming, verify the response contains SSE data
        if (useStream) {
          final contentType = res.headers['content-type'] ?? '';
          if (!contentType.contains('text/event-stream') && res.body.isEmpty) {
            throw HttpException('Stream response expected but not received');
          }
        }
        return;
      } else if (kind == ProviderKind.claude) {
        final url = Uri.parse(
          resolveProviderRequestUrl(
            baseUrl: cfg.baseUrl,
            providerType: 'claude',
            modelId: modelId,
          ).url,
        );
        final body = {
          'model': modelId,
          'max_tokens': 8,
          'messages': [
            {'role': 'user', 'content': 'hello'},
          ],
          if (useStream) 'stream': true,
        };
        final extra = _customBody(cfg, modelId);
        if (extra.isNotEmpty) (body as Map<String, dynamic>).addAll(extra);
        final headers = <String, String>{
          'x-api-key': cfg.apiKey,
          'anthropic-version': ClaudeProvider.anthropicVersion,
          'Content-Type': 'application/json',
        };
        headers.addAll(_customHeaders(cfg, modelId));
        final res = await client.post(
          url,
          headers: headers,
          body: jsonEncode(body),
        );
        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw HttpException('HTTP ${res.statusCode}: ${res.body}');
        }
        // For streaming, verify the response contains SSE data
        if (useStream) {
          final contentType = res.headers['content-type'] ?? '';
          if (!contentType.contains('text/event-stream') && res.body.isEmpty) {
            throw HttpException('Stream response expected but not received');
          }
        }
        return;
      } else if (kind == ProviderKind.google) {
        // Generative Language API (default) or Vertex AI when vertexAI == true
        final ov = _modelOverride(cfg, modelId);
        // Resolve upstream/api model id for this logical key when present.
        String upstreamId = modelId;
        try {
          final raw = (ov['apiModelId'] ?? ov['api_model_id'])
              ?.toString()
              .trim();
          if (raw != null && raw.isNotEmpty) upstreamId = raw;
        } catch (_) {}

        final url = resolveProviderRequestUrl(
          baseUrl: cfg.baseUrl,
          providerType: 'google',
          modelId: upstreamId,
          vertexAI: cfg.vertexAI == true,
          location: cfg.location,
          projectId: cfg.projectId,
          isStream: useStream,
        ).url;
        // Determine if model outputs images (override wins; otherwise inference)
        bool wantsImageOutput = false;
        if (ov['output'] is List) {
          final outList = (ov['output'] as List)
              .map((e) => e.toString().toLowerCase())
              .toList();
          wantsImageOutput = outList.contains('image');
        } else {
          wantsImageOutput = ModelRegistry.infer(
            ModelInfo(id: upstreamId, displayName: upstreamId),
          ).output.contains(Modality.image);
        }
        final body = {
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': 'hello'},
              ],
            },
          ],
          if (wantsImageOutput)
            'generationConfig': {
              'responseModalities': ['TEXT', 'IMAGE'],
            },
        };
        final headers = <String, String>{'Content-Type': 'application/json'};
        if (cfg.vertexAI == true) {
          final jsonStr = (cfg.serviceAccountJson ?? '').trim();
          if (jsonStr.isNotEmpty) {
            try {
              final token =
                  await GoogleServiceAccountAuth.getAccessTokenFromJson(
                    jsonStr,
                  );
              headers['Authorization'] = 'Bearer $token';
            } catch (_) {}
          } else if (cfg.apiKey.isNotEmpty) {
            headers['Authorization'] = 'Bearer ${cfg.apiKey}';
          }
        } else {
          if (cfg.apiKey.isNotEmpty) {
            headers['x-goog-api-key'] = cfg.apiKey;
          }
        }
        headers.addAll(_customHeaders(cfg, modelId));
        final extra = _customBody(cfg, modelId);
        if (extra.isNotEmpty) (body as Map<String, dynamic>).addAll(extra);
        final res = await client.post(
          Uri.parse(url),
          headers: headers,
          body: jsonEncode(body),
        );
        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw HttpException('HTTP ${res.statusCode}: ${res.body}');
        }
        // For streaming, verify the response is not empty
        if (useStream && res.body.isEmpty) {
          throw HttpException('Stream response expected but not received');
        }
        return;
      }
    } finally {
      client.close();
    }
  }

  /// Experimental (branch `experiment/reasoning-overrides`): probe which
  /// reasoning-effort values a model actually accepts on the OpenAI-compatible
  /// transport. Sends one tiny request ("hi", 16-token cap) per effort value,
  /// strictly serial, ALWAYS user-triggered from the model detail sheet —
  /// never called automatically.
  ///
  /// A baseline request without the effort parameter runs first; if it fails
  /// the whole probe aborts with [ReasoningProbeException]. Unknown outcomes
  /// (timeouts, 5xx, other statuses) are reported as [ReasoningProbeStatus.unknown]
  /// and never auto-applied — the caller shows a confirmation dialog and the
  /// user decides.
  static Future<ReasoningProbeSummary> probeReasoning(
    ProviderConfig cfg,
    String modelId, {
    http.Client? client,
    List<String>? efforts,
    void Function(String effort, int index, int total)? onProgress,
    bool Function()? isCancelled,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (_apiKind(cfg) != ProviderKind.openai) {
      throw ReasoningProbeException('probe_unsupported_transport');
    }

    // Resolve the upstream model id (mirrors ChatApiService._apiModelId).
    String upstream = modelId;
    try {
      final ov = _modelOverride(cfg, modelId);
      final raw = (ov['apiModelId'] ?? ov['api_model_id'])?.toString().trim();
      if (raw != null && raw.isNotEmpty) upstream = raw;
    } catch (_) {}

    final useResponses = cfg.useResponseApi == true;
    final base = cfg.baseUrl.endsWith('/')
        ? cfg.baseUrl.substring(0, cfg.baseUrl.length - 1)
        : cfg.baseUrl;
    final path = useResponses
        ? '/responses'
        : (cfg.chatPath ?? '/chat/completions');
    final url = Uri.parse('$base$path');

    final ownedClient = client == null;
    final http.Client c = client ?? _Http.clientFor(cfg);
    try {
      final summary = ReasoningProbeSummary();
      final ladder = (efforts == null || efforts.isEmpty)
          ? ReasoningOverride.allEfforts
          : efforts;

      // Whether the request accepts a token cap, and under which key.
      // OpenAI's newer reasoning models reject `max_tokens` in favor of
      // `max_completion_tokens`; some strict validators reject both.
      String? tokenCapKey = 'max_tokens';

      Map<String, dynamic> buildBody(String? effort) {
        final body = useResponses
            ? <String, dynamic>{
                'model': upstream,
                'input': [
                  {'role': 'user', 'content': 'hi'},
                ],
              }
            : <String, dynamic>{
                'model': upstream,
                'messages': [
                  {'role': 'user', 'content': 'hi'},
                ],
              };
        // User custom body merged first; probe keys win below.
        try {
          final extra = _customBody(cfg, modelId);
          if (extra.isNotEmpty) body.addAll(extra);
        } catch (_) {}
        if (effort != null) {
          if (useResponses) {
            body['reasoning'] = {'summary': 'auto', 'effort': effort};
          } else {
            body['reasoning_effort'] = effort;
          }
        }
        if (tokenCapKey != null) {
          // Responses API has its own top-level token-cap key; the chat
          // completions key is configurable because newer OpenAI reasoning
          // models reject `max_tokens` in favor of `max_completion_tokens`.
          body[useResponses ? 'max_output_tokens' : tokenCapKey] = 16;
        }
        return body;
      }

      Future<http.Response?> send(Map<String, dynamic> body) async {
        final headers = <String, String>{'Content-Type': 'application/json'};
        final key = _effectiveApiKey(cfg);
        if (key.isNotEmpty) headers['Authorization'] = 'Bearer $key';
        try {
          headers.addAll(_customHeaders(cfg, modelId));
        } catch (_) {}
        try {
          return await c
              .post(url, headers: headers, body: jsonEncode(body))
              .timeout(timeout);
        } catch (_) {
          return null;
        }
      }

      // Baseline: no effort parameter. Verifies reachability + auth and
      // negotiates the token-cap key before the ladder starts.
      {
        var res = await send(buildBody(null));
        if (res == null) {
          throw ReasoningProbeException('baseline_timeout');
        }
        if (res.statusCode < 200 || res.statusCode >= 300) {
          final lower = res.body.toLowerCase();
          if (tokenCapKey == 'max_tokens' &&
              lower.contains('max_completion_tokens')) {
            tokenCapKey = 'max_completion_tokens';
            res = await send(buildBody(null));
            if (res == null) throw ReasoningProbeException('baseline_timeout');
          }
          if (res.statusCode < 200 || res.statusCode >= 300) {
            if (tokenCapKey != null &&
                res.body.toLowerCase().contains('max_completion_tokens') &&
                res.body.toLowerCase().contains('max_tokens')) {
              tokenCapKey = null;
              res = await send(buildBody(null));
            }
          }
          if (res == null || res.statusCode < 200 || res.statusCode >= 300) {
            throw ReasoningProbeException(
              'baseline_http_${res?.statusCode}',
              detail: res?.body,
            );
          }
        }
        summary.baselineOk = true;
      }

      var i = 0;
      for (final effort in ladder) {
        if (isCancelled?.call() ?? false) {
          summary.cancelled = true;
          break;
        }
        i++;
        onProgress?.call(effort, i, ladder.length);
        final res = await send(buildBody(effort));
        if (res != null && res.statusCode >= 200 && res.statusCode < 300) {
          summary.supported.add(effort);
          // "Really reasoning" signal: usage.reasoning_tokens > 0 when the
          // provider reports it. Advisory only, never a hard conclusion.
          try {
            final data = jsonDecode(res.body);
            final usage = data is Map ? data['usage'] : null;
            final details = usage is Map
                ? (usage['completion_tokens_details'] ??
                      usage['output_tokens_details'])
                : null;
            if (details is Map) {
              final rt = details['reasoning_tokens'];
              if (rt is num && rt > 0) {
                summary.reasoningTokenEfforts.add(effort);
              }
            }
          } catch (_) {}
        } else if (res != null &&
            (res.statusCode == 400 ||
                res.statusCode == 404 ||
                res.statusCode == 422)) {
          // Strict validators name the offending key; if the token cap (not
          // the effort) is the problem, retry once without it before
          // concluding the effort itself is rejected.
          final lower = res.body.toLowerCase();
          final mentionsEffort =
              lower.contains('reasoning_effort') ||
              lower.contains("'effort'") ||
              lower.contains('reasoning.effort');
          final mentionsCap =
              lower.contains('max_tokens') ||
              lower.contains('max_output_tokens') ||
              lower.contains('max_completion_tokens');
          if (tokenCapKey != null && mentionsCap && !mentionsEffort) {
            final saved = tokenCapKey;
            tokenCapKey = null;
            final retry = await send(buildBody(effort));
            if (retry != null &&
                retry.statusCode >= 200 &&
                retry.statusCode < 300) {
              summary.supported.add(effort);
            } else {
              tokenCapKey = saved;
              summary.unsupported.add(effort);
            }
          } else {
            summary.unsupported.add(effort);
          }
        } else {
          // 429 / 5xx / timeout / anything else: inconclusive, never applied.
          summary.unknown.add(effort);
        }
        // Be gentle with rate limits between ladder steps.
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      return summary;
    } finally {
      if (ownedClient) c.close();
    }
  }
}

/// Probe outcome for a single effort value.
enum ReasoningProbeStatus { supported, unsupported, unknown }

/// Raised when the probe cannot even start (baseline failed) or the transport
/// is not OpenAI-compatible.
class ReasoningProbeException implements Exception {
  ReasoningProbeException(this.code, {this.detail});
  final String code;
  final String? detail;
  @override
  String toString() =>
      'ReasoningProbeException($code${detail == null ? '' : ': $detail'})';
}

/// Aggregated probe result. `supported` entries in ladder order are what the
/// confirmation dialog offers to write into `modelOverrides[modelId]['reasoning']`.
class ReasoningProbeSummary {
  bool baselineOk = false;
  bool cancelled = false;
  final List<String> supported = [];
  final List<String> unsupported = [];
  final List<String> unknown = [];
  final Set<String> reasoningTokenEfforts = {};

  ReasoningProbeStatus statusFor(String effort) {
    if (supported.contains(effort)) return ReasoningProbeStatus.supported;
    if (unsupported.contains(effort)) return ReasoningProbeStatus.unsupported;
    return ReasoningProbeStatus.unknown;
  }

  /// Lowest accepted effort — the suggested `offFallback` when `none` is not
  /// supported (Off cannot truly disable thinking, so remap to the floor).
  String? get suggestedOffFallback {
    if (supported.isEmpty) return null;
    if (supported.contains('none')) return 'none';
    for (final e in ReasoningOverride.allEfforts) {
      if (supported.contains(e)) return e;
    }
    return null;
  }

  /// True when the model never accepted `none` — the UI should hide the Off
  /// tile (thinkingAlwaysOn), mirroring the Muse Spark behavior.
  bool get suggestedThinkingAlwaysOn =>
      baselineOk && supported.isNotEmpty && !supported.contains('none');

  /// Build the storage map for `modelOverrides[modelId]['reasoning']`.
  /// Returns `null` when the probe found nothing supported — there is no
  /// conclusive data to write, and applying would actively pin Xhigh/Max to
  /// false for a model that may just have been rate-limited.
  Map<String, dynamic>? toOverrideMap() {
    if (supported.isEmpty) return null;
    final ovr = ReasoningOverride(
      hasEfforts: true,
      efforts: {...supported},
      hasOffFallback: suggestedOffFallback != null,
      offFallback: suggestedOffFallback,
      hasSupportsXhigh: true,
      supportsXhigh: supported.contains('xhigh'),
      hasSupportsMax: true,
      supportsMax: supported.contains('max'),
      hasThinkingAlwaysOn: true,
      thinkingAlwaysOn: suggestedThinkingAlwaysOn,
      hasSamplingRequiresNone: false,
      samplingRequiresNone: false,
      hasAdaptiveThinking: false,
      adaptiveThinking: false,
    );
    return ovr.toMap();
  }
}
