import '../../providers/settings_provider.dart';

/// Built-in tool name constants for API integrations.
/// Use these constants instead of raw strings to ensure consistency.
abstract class BuiltInToolNames {
  // Common
  static const search = 'search';

  // Google/Gemini specific
  static const urlContext = 'url_context';
  static const codeExecution = 'code_execution';
  static const youtube = 'youtube';

  // OpenAI specific
  static const codeInterpreter = 'code_interpreter';
  static const imageGeneration = 'image_generation';

  /// Normalize a tool name to snake_case format.
  /// Handles legacy camelCase formats for backward compatibility.
  static String normalize(String name) {
    final lower = name.trim().toLowerCase();
    switch (lower) {
      case 'urlcontext':
        return urlContext;
      case 'codeexecution':
        return codeExecution;
      case 'codeinterpreter':
        return codeInterpreter;
      case 'imagegeneration':
        return imageGeneration;
      default:
        return lower;
    }
  }

  /// Parse tool names from persisted settings and normalize them.
  ///
  /// Accepts legacy/unknown types defensively (e.g. null, non-iterables).
  /// Returns a mutable Set even when empty to avoid read-only mutation crashes.
  static Set<String> parseAndNormalize(Object? raw) {
    if (raw == null) return <String>{};
    if (raw is! Iterable) return <String>{};
    final out = <String>{};
    for (final e in raw) {
      final v = normalize(e.toString());
      if (v.isNotEmpty) out.add(v);
    }
    return out;
  }

  /// Resolve the upstream/vendor model id for a given logical model key
  /// (mirrors ChatApiService._apiModelId).
  static String effectiveModelId({
    required ProviderConfig? cfg,
    required String modelId,
  }) {
    try {
      final ov = cfg?.modelOverrides[modelId];
      if (ov is Map<String, dynamic>) {
        final raw = (ov['apiModelId'] ?? ov['api_model_id'])
            ?.toString()
            .trim();
        if (raw != null && raw.isNotEmpty) return raw;
      }
    } catch (_) {}
    return modelId;
  }

  /// Stable ordering for persisting tool lists (keeps UI diffs minimal).
  static List<String> orderedForStorage(Iterable<String> tools) {
    final remaining = Set<String>.from(tools);
    const preferredOrder = <String>[
      BuiltInToolNames.search,
      BuiltInToolNames.urlContext,
      BuiltInToolNames.codeExecution,
      BuiltInToolNames.youtube,
      BuiltInToolNames.codeInterpreter,
      BuiltInToolNames.imageGeneration,
    ];
    final out = <String>[
      for (final k in preferredOrder)
        if (remaining.remove(k)) k,
      ...remaining,
    ];
    return out;
  }
}

/// Utility class for checking provider-specific built-in tool support.
abstract class BuiltInToolsHelper {
  /// Check if a provider supports built-in tools configuration.
  static bool supportsBuiltInTools(ProviderKind kind) {
    return kind == ProviderKind.google || kind == ProviderKind.openai || kind == ProviderKind.neuralwatt;
  }

  /// Check if the provider/model combination supports search tool.
  static bool supportsSearch({
    required ProviderKind kind,
    required bool useResponseApi,
    String? modelId,
  }) {
    switch (kind) {
      case ProviderKind.google:
        return true;
      case ProviderKind.claude:
        return true;
      case ProviderKind.neuralwatt:
      case ProviderKind.openai:
        // OpenAI requires Responses API, or Grok models
        if (useResponseApi) return true;
        if (modelId != null && modelId.toLowerCase().contains('grok')) return true;
        return false;
    }
  }

  static String _normalizedModelId(String? modelId) =>
      (modelId ?? '').trim().toLowerCase();

  /// Whether the official Claude model supports the new dynamic web search
  /// tool version (`web_search_20260209` with dynamic filtering).
  static bool isClaudeDynamicWebSearchSupportedModel(String? modelId) {
    final normalized = _normalizedModelId(modelId);
    return normalized.contains('mythos') ||
        normalized == 'claude-opus-4-7' ||
        normalized == 'claude-opus-4-6' ||
        normalized == 'claude-sonnet-4-6';
  }

  /// Whether the provider/model combination supports Claude dynamic web search.
  static bool supportsClaudeDynamicWebSearchForModel({
    required ProviderConfig? cfg,
    required String? modelId,
  }) {
    if (cfg == null || (modelId ?? '').trim().isEmpty) return false;
    final kind = ProviderConfig.classify(
      cfg.id,
      explicitType: cfg.providerType,
    );
    if (kind != ProviderKind.claude) return false;
    final upstreamModelId = BuiltInToolNames.effectiveModelId(
      cfg: cfg,
      modelId: modelId!,
    );
    return isClaudeDynamicWebSearchSupportedModel(upstreamModelId);
  }

  /// Whether Claude dynamic web search is enabled for the model, i.e. the
  /// per-model override sets `webSearch.toolVersion = web_search_20260209`.
  static bool isClaudeDynamicWebSearchEnabled({
    required ProviderConfig? cfg,
    required String? modelId,
  }) {
    if (!supportsClaudeDynamicWebSearchForModel(cfg: cfg, modelId: modelId)) {
      return false;
    }
    if (cfg == null || modelId == null || modelId.trim().isEmpty) {
      return false;
    }
    final rawOv = cfg.modelOverrides[modelId];
    final ov = rawOv is Map ? rawOv : null;
    final rawWs = ov?['webSearch'];
    if (rawWs is! Map) return false;
    final ws = rawWs.cast<String, dynamic>();
    return ws['toolVersion'] == 'web_search_20260209' ||
        ws['tool_version'] == 'web_search_20260209';
  }

  /// The Claude built-in search server tool type to use: the new dynamic
  /// version (`web_search_20260209`) when enabled, otherwise the legacy
  /// `web_search_20250305`.
  static String claudeBuiltInSearchToolType({
    required ProviderConfig? cfg,
    required String? modelId,
  }) {
    return isClaudeDynamicWebSearchEnabled(cfg: cfg, modelId: modelId)
        ? 'web_search_20260209'
        : 'web_search_20250305';
  }

  /// Get active built-in tools from model overrides.
  static BuiltInToolsState getActiveTools({
    required ProviderConfig? cfg,
    required String? modelId,
  }) {
    if (cfg == null || modelId == null) {
      return const BuiltInToolsState();
    }

    final kind = ProviderConfig.classify(cfg.id, explicitType: cfg.providerType);
    final rawOv = cfg.modelOverrides[modelId];
    final ov = rawOv is Map ? rawOv : null;
    final builtInSet = BuiltInToolNames.parseAndNormalize(ov?['builtInTools']);

    bool searchActive = builtInSet.contains(BuiltInToolNames.search);
    bool codeExecutionActive = false;
    bool urlContextActive = false;
    bool youtubeActive = false;
    bool codeInterpreterActive = false;
    bool imageGenerationActive = false;

    if (kind == ProviderKind.google) {
      codeExecutionActive = builtInSet.contains(BuiltInToolNames.codeExecution);
      urlContextActive = builtInSet.contains(BuiltInToolNames.urlContext);
      youtubeActive = builtInSet.contains(BuiltInToolNames.youtube);
    } else if (kind == ProviderKind.openai || kind == ProviderKind.neuralwatt) {
      codeInterpreterActive = builtInSet.contains(BuiltInToolNames.codeInterpreter);
      imageGenerationActive = builtInSet.contains(BuiltInToolNames.imageGeneration);
    }

    return BuiltInToolsState(
      searchActive: searchActive,
      codeExecutionActive: codeExecutionActive,
      urlContextActive: urlContextActive,
      youtubeActive: youtubeActive,
      codeInterpreterActive: codeInterpreterActive,
      imageGenerationActive: imageGenerationActive,
    );
  }
}

/// State class representing active built-in tools.
class BuiltInToolsState {
  final bool searchActive;
  final bool codeExecutionActive;
  final bool urlContextActive;
  final bool youtubeActive;
  final bool codeInterpreterActive;
  final bool imageGenerationActive;

  const BuiltInToolsState({
    this.searchActive = false,
    this.codeExecutionActive = false,
    this.urlContextActive = false,
    this.youtubeActive = false,
    this.codeInterpreterActive = false,
    this.imageGenerationActive = false,
  });

  /// Returns true if any Gemini-specific built-in tool is active.
  bool get anyGeminiToolActive => codeExecutionActive || urlContextActive || youtubeActive;

  /// Returns true if any built-in tool that conflicts with MCP is active.
  bool get anyMcpConflictingToolActive => searchActive || codeExecutionActive || urlContextActive;
}
