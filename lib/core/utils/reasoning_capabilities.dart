import '../services/model_catalog/model_catalog.dart';

enum ReasoningTransport { openAi, claude, google }

class ReasoningBudget {
  static const int off = 0;
  static const int auto = -1;
  static const int light = 1024;
  static const int medium = 16000;
  static const int heavy = 32000;
  static const int xhigh = 64000;
  static const int max = 128000;

  static bool isOff(int? budget) =>
      budget != null && budget != auto && budget < light;

  static int bucket(
    int? budget, {
    bool allowXhigh = false,
    bool allowMax = false,
  }) {
    if (budget == null || budget == auto) return auto;
    if (budget < light) return off;
    if (budget < medium) return light;
    if (budget < heavy) return medium;
    if (budget < xhigh) return heavy;
    if (budget < max) return allowXhigh ? xhigh : heavy;
    if (allowMax) return max;
    return allowXhigh ? xhigh : heavy;
  }
}

class ReasoningBudgetSelection {
  const ReasoningBudgetSelection(this.value);

  // A null value means inherit the global setting. Modal dismissal is a null
  // result, so callers can distinguish cancellation from an explicit inherit.
  final int? value;
}

class ReasoningCapabilities {
  const ReasoningCapabilities({
    this.supportsXhigh = false,
    this.supportsMax = false,
    this.supportsAdaptiveThinking = false,
    this.thinkingAlwaysOn = false,
    this.samplingRequiresNone = false,
    this.claudeOffBetweenTools = false,
    this.claudeOffEffort,
    this.samplingUnsupported = false,
    this.openAiEfforts = const <String>{},
    this.openAiOffFallback,
  });

  final bool supportsXhigh;
  final bool supportsMax;
  final bool supportsAdaptiveThinking;
  final bool thinkingAlwaysOn;
  final bool samplingRequiresNone;

  /// Claude Sonnet 5.5+ rejects `thinking: {type: disabled}`; its Off tier is
  /// `between_tools` instead (Anthropic's lowest adaptive setting).
  final bool claudeOffBetweenTools;

  /// Effort to send when an always-thinking Claude model is switched off.
  /// Anthropic clamps Off to the lowest explicit tier instead of disabling.
  final String? claudeOffEffort;

  /// The model rejects temperature/top_p regardless of reasoning state
  /// (models.dev `temperature: false`). Distinct from
  /// [samplingRequiresNone], which only strips them while reasoning.
  final bool samplingUnsupported;
  final Set<String> openAiEfforts;
  final String? openAiOffFallback;

  static const unsupported = ReasoningCapabilities();

  /// Overlay catalog facts on top of the regex baseline (plan batch 1 §7.2).
  ///
  /// Only fields the catalog actually publishes are replaced:
  /// - effort tiers drive `openAiEfforts` and the Xhigh/Max display flags;
  /// - `temperature: false` sets [samplingUnsupported];
  /// - an explicit `reasoning: false` clears reasoning capabilities.
  /// Missing fields keep the regex baseline so unknown entries cannot
  /// silently downgrade a model.
  static ReasoningCapabilities fromCatalog(
    ReasoningCapabilities base,
    CatalogModel catalog,
  ) {
    final samplingUnsupported = catalog.temperatureSupported == false;
    if (catalog.reasoning == false) {
      return ReasoningCapabilities(
        samplingRequiresNone: base.samplingRequiresNone,
        samplingUnsupported: samplingUnsupported,
      );
    }
    final efforts = catalog.efforts;
    final hasEfforts = efforts.isNotEmpty;
    return ReasoningCapabilities(
      supportsXhigh: hasEfforts
          ? efforts.contains('xhigh')
          : base.supportsXhigh,
      supportsMax: hasEfforts ? efforts.contains('max') : base.supportsMax,
      supportsAdaptiveThinking: base.supportsAdaptiveThinking,
      thinkingAlwaysOn: base.thinkingAlwaysOn,
      samplingRequiresNone: base.samplingRequiresNone,
      claudeOffBetweenTools: base.claudeOffBetweenTools,
      claudeOffEffort: base.claudeOffEffort,
      samplingUnsupported: samplingUnsupported,
      openAiEfforts: hasEfforts
          ? efforts
          : (catalog.reasoning == true ? const <String>{} : base.openAiEfforts),
      openAiOffFallback: base.openAiOffFallback,
    );
  }

  String normalizeOpenAiEffort(String effort) {
    final normalized = effort.trim().toLowerCase();
    if (normalized.isEmpty || normalized == 'auto') return normalized;
    if (openAiEfforts.isEmpty || openAiEfforts.contains(normalized)) {
      return normalized;
    }
    if (normalized == 'off') return openAiOffFallback ?? normalized;

    final candidates = switch (normalized) {
      'low' => const ['low', 'medium', 'high', 'xhigh', 'max'],
      'medium' => const ['medium', 'high', 'xhigh', 'max', 'low'],
      'high' => const ['high', 'xhigh', 'max', 'medium', 'low'],
      'xhigh' => const ['xhigh', 'high', 'max', 'medium', 'low'],
      'max' => const ['max', 'xhigh', 'high', 'medium', 'low'],
      _ => const <String>[],
    };
    for (final candidate in candidates) {
      if (openAiEfforts.contains(candidate)) return candidate;
    }
    return normalized;
  }

  static ReasoningCapabilities forModel(
    ReasoningTransport transport,
    String modelId,
  ) {
    final id = modelId.trim().toLowerCase();
    if (id.isEmpty) return unsupported;

    switch (transport) {
      case ReasoningTransport.openAi:
        return _openAiCapabilities(id);
      case ReasoningTransport.claude:
        return _claudeCapabilities(id);
      case ReasoningTransport.google:
        return _googleCapabilities(id);
    }
  }

  /// Gemini 3.x (incl. 3.8 Flash) expose a thinkingLevel dial rather than a
  /// raw token budget; their wire mapping tops out at 'high', so the Xhigh
  /// tier is advertised for UI purposes and clamps to the same level.
  static ReasoningCapabilities _googleCapabilities(String id) {
    final match = RegExp(r'gemini-(\d+)', caseSensitive: false).firstMatch(id);
    final major = int.tryParse(match?.group(1) ?? '');
    if (major != null && major >= 3) {
      return const ReasoningCapabilities(supportsXhigh: true);
    }
    return unsupported;
  }

  static ReasoningCapabilities _openAiCapabilities(String id) {
    // OpenRouter Auto routes each prompt to a capable model; its router may
    // enable reasoning on its own, so the reasoning dial must be reachable
    // (Off/Auto tiers at minimum). No xhigh tier is advertised here — the
    // router decides which model handles the prompt, so a single documented
    // effort set would be a guess (plan O2: “efforts 空、可停用”).
    if (id == 'openrouter/auto' || id == 'auto') {
      return const ReasoningCapabilities();
    }
    // GPT-5 base restores its own documented tiers rather than inheriting the
    // 5.5 shape (plan M1).
    if (RegExp(
      r'(?:^|[/_:@])gpt-5(?:$|[-.@])(?![\d])',
      caseSensitive: false,
    ).hasMatch(id)) {
      return const ReasoningCapabilities(
        samplingRequiresNone: true,
        openAiEfforts: <String>{'minimal', 'low', 'medium', 'high'},
        openAiOffFallback: 'minimal',
      );
    }
    if (_containsModel(id, r'(?:^|[/_:@])kimi-k3(?:$|[-.])')) {
      return const ReasoningCapabilities(
        supportsMax: true,
        thinkingAlwaysOn: true,
        openAiEfforts: {'low', 'high', 'max'},
        openAiOffFallback: 'low',
      );
    }
    if (id.contains('deepseek')) {
      // DeepSeek v4 family (incl. v4.1 Flash) supports the max effort tier;
      // older v3.x models top out at xhigh.
      final isV4 = id.contains('deepseek-v4');
      return ReasoningCapabilities(
        supportsXhigh: true,
        supportsMax: isV4,
        openAiEfforts: isV4
            ? const {'low', 'medium', 'high', 'xhigh', 'max'}
            : const {'low', 'medium', 'high', 'xhigh'},
      );
    }
    // Meta Muse Spark (dev.meta.ai OpenAI-compatible Model API):
    // reasoning_effort minimal|low|medium|high|xhigh; the model ALWAYS
    // reasons, so Off remaps to 'minimal' instead of being dropped. 'max'
    // is advertised but not yet exposed by the API (2026-09).
    if (id.contains('muse-spark') || id.contains('muse_spark')) {
      return const ReasoningCapabilities(
        supportsXhigh: true,
        thinkingAlwaysOn: true,
        openAiEfforts: {'minimal', 'low', 'medium', 'high', 'xhigh'},
        openAiOffFallback: 'minimal',
      );
    }
    // GLM 5.x (incl. 5.3 / 5.3 Flash): supports xhigh-class effort.
    // Zhipu-like hosts get the vendor thinking knob in ChatApiService and
    // strip reasoning_effort; aggregator hosts receive reasoning_effort.
    if (id.contains('glm-5') || id.contains('glm5')) {
      return const ReasoningCapabilities(supportsXhigh: true);
    }

    final match = RegExp(
      r'(?:^|[/_:@])gpt-5\.(\d+)(?:$|[-.:@])',
      caseSensitive: false,
    ).firstMatch(id);
    final minor = int.tryParse(match?.group(1) ?? '');
    if (minor == null) return unsupported;

    final isCodexOrChat = _containsModel(
      id,
      r'gpt-5\.(?:3|4|5)-(?:codex|chat-latest)(?:$|[-.:@])',
    );
    if (minor == 2) {
      return const ReasoningCapabilities(supportsXhigh: true);
    }
    if (minor == 3 && isCodexOrChat) {
      return const ReasoningCapabilities(supportsXhigh: true);
    }
    if (minor == 4) {
      if (isCodexOrChat) return unsupported;
      return const ReasoningCapabilities(supportsXhigh: true);
    }
    if (minor == 5) {
      if (isCodexOrChat) return unsupported;
      final isPro = _containsModel(id, r'gpt-5\.5-pro(?:$|[-.:@])');
      if (isPro) {
        return const ReasoningCapabilities(supportsXhigh: true);
      }
      return const ReasoningCapabilities(
        supportsXhigh: true,
        samplingRequiresNone: true,
      );
    }
    if (minor == 6) {
      // GPT-5.6 Luna (official docs): Reasoning.effort supports none, low,
      // medium (default), high, xhigh, max, and the model rejects
      // temperature / top_p while reasoning (as GPT-5.5 does).
      final isLuna = _containsModel(id, r'gpt-5\.6-luna(?:$|[-.:@])');
      return ReasoningCapabilities(
        supportsXhigh: true,
        supportsMax: true,
        samplingRequiresNone: isLuna,
        openAiEfforts: isLuna
            ? const {'none', 'low', 'medium', 'high', 'xhigh', 'max'}
            : const <String>{},
        openAiOffFallback: isLuna ? 'none' : null,
      );
    }
    return unsupported;
  }

  static ReasoningCapabilities _claudeCapabilities(String id) {
    if (id.contains('deepseek')) {
      return const ReasoningCapabilities(
        supportsXhigh: true,
        supportsMax: true,
      );
    }
    final isFable = id.contains('fable') || id.contains('mythos');
    final version = _claudeVersion(id);
    if (!isFable && version == null) return unsupported;

    final major = version?.major ?? 5;
    final minor = version?.minor ?? 0;
    final family = version?.family ?? '';
    final alwaysOn = isFable || (family == 'opus' && major == 5 && minor >= 5);
    final adaptive = alwaysOn || major > 4 || (major == 4 && minor >= 6);
    if (!adaptive) return unsupported;

    // Claude 4.7+ rejects sampling parameters outright, not only while a
    // thinking block is active.
    final adaptiveOnly = alwaysOn || major > 4 || (major == 4 && minor >= 7);
    final supportsXhigh =
        isFable || major == 5 || (major == 4 && family == 'opus' && minor >= 7);
    final supportsMax =
        supportsXhigh ||
        (major == 4 && (family == 'opus' || family == 'sonnet') && minor == 6);

    return ReasoningCapabilities(
      supportsXhigh: supportsXhigh,
      supportsMax: supportsMax,
      supportsAdaptiveThinking: true,
      thinkingAlwaysOn: alwaysOn,
      samplingRequiresNone: adaptiveOnly,
      claudeOffBetweenTools: family == 'sonnet' && major == 5 && minor >= 5,
      claudeOffEffort: alwaysOn ? 'low' : null,
    );
  }

  /// Parses `claude-opus-4.8`, `claude-sonnet-5-5` and the reversed
  /// `claude-5-5-haiku` form. Eight-digit snapshot dates are suffixes, never
  /// minor versions (`claude-opus-4-20250514` is 4.0).
  static ({String family, int major, int minor})? _claudeVersion(String id) {
    final match = RegExp(
      r'claude-(?:(opus|sonnet|haiku)-(\d+)(?:[.-](\d{1,2})(?!\d))?'
      r'|(\d+)(?:[.-](\d{1,2})(?!\d))?-(opus|sonnet|haiku))'
      r'(?:$|[._:@/-])',
      caseSensitive: false,
    ).firstMatch(id);
    if (match == null) return null;
    final major = int.tryParse(match.group(2) ?? match.group(4) ?? '');
    if (major == null) return null;
    return (
      family: (match.group(1) ?? match.group(6) ?? '').toLowerCase(),
      major: major,
      minor: int.tryParse(match.group(3) ?? match.group(5) ?? '0') ?? 0,
    );
  }

  static bool _containsModel(String id, String pattern) =>
      RegExp(pattern, caseSensitive: false).hasMatch(id);
}
