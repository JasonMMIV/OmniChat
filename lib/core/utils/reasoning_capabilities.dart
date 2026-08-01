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
    this.openAiEfforts = const <String>{},
    this.openAiOffFallback,
  });

  final bool supportsXhigh;
  final bool supportsMax;
  final bool supportsAdaptiveThinking;
  final bool thinkingAlwaysOn;
  final Set<String> openAiEfforts;
  final String? openAiOffFallback;

  static const unsupported = ReasoningCapabilities();

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
        return unsupported;
    }
  }

  static ReasoningCapabilities _openAiCapabilities(String id) {
    if (_containsModel(id, r'(?:^|[/_:@])kimi-k3(?:$|[-.])')) {
      return const ReasoningCapabilities(
        supportsMax: true,
        thinkingAlwaysOn: true,
        openAiEfforts: {'low', 'high', 'max'},
        openAiOffFallback: 'low',
      );
    }
    if (id.contains('deepseek')) {
      return const ReasoningCapabilities(
        supportsXhigh: true,
        openAiEfforts: {'low', 'medium', 'high', 'xhigh'},
      );
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
    if (minor == 4 || minor == 5) {
      if (isCodexOrChat) return unsupported;
      return const ReasoningCapabilities(supportsXhigh: true);
    }
    if (minor == 6) {
      return const ReasoningCapabilities(
        supportsXhigh: true,
        supportsMax: true,
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
    if (id.contains('fable') || id.contains('mythos')) {
      return const ReasoningCapabilities(
        supportsXhigh: true,
        supportsMax: true,
        supportsAdaptiveThinking: true,
        thinkingAlwaysOn: true,
      );
    }
    if (_containsModel(id, r'claude-(?:opus|sonnet)-5(?:$|[._:@/-])')) {
      return const ReasoningCapabilities(
        supportsXhigh: true,
        supportsMax: true,
        supportsAdaptiveThinking: true,
      );
    }
    if (_containsModel(id, r'claude-opus-4[-.]7(?:$|[-.:@])') ||
        _containsModel(id, r'claude-opus-4[-.]8(?:$|[-.:@])')) {
      return const ReasoningCapabilities(
        supportsXhigh: true,
        supportsMax: true,
        supportsAdaptiveThinking: true,
      );
    }
    if (_containsModel(id, r'claude-(?:opus|sonnet)-4[-.]6(?:$|[-.:@])')) {
      return const ReasoningCapabilities(
        supportsMax: true,
        supportsAdaptiveThinking: true,
      );
    }
    return unsupported;
  }

  static bool _containsModel(String id, String pattern) =>
      RegExp(pattern, caseSensitive: false).hasMatch(id);
}
