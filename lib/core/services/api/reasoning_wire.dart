// Custom reasoning wire formats (plan batch 2).
//
// Pure Dart: the transport files pass a body map plus the call's resolved
// capabilities; nothing here imports Flutter, Hive or chat services, so both
// the four chat-completions copies and the Responses/Claude/Gemini paths can
// share one definition and the behaviour is unit-testable.
//
// `auto` always delegates to the extracted vendor chain, byte-for-byte the
// behaviour that existed inline before this file. An explicit wire only
// clears the keys it owns, so unrelated custom-body parameters survive.
library;

import '../../utils/reasoning_capabilities.dart';

class ReasoningWire {
  ReasoningWire._();

  static const String auto = 'auto';

  // OpenAI Chat Completions dialects.
  static const String chatEffort = 'chat.effort';
  static const String chatReasoningEffortObj = 'chat.reasoning_effort_obj';
  static const String chatReasoningBudgetObj = 'chat.reasoning_budget_obj';
  static const String chatThinkingBudget = 'chat.thinking_budget';
  static const String chatEnableThinking = 'chat.enable_thinking';
  static const String chatThinkingMode = 'chat.thinking_mode';
  static const String chatTemplateKwargs = 'chat.template_kwargs';
  static const String chatNone = 'chat.none';

  // OpenAI Responses dialects.
  static const String responsesEffort = 'responses.effort';
  static const String responsesNone = 'responses.none';

  // Claude Messages dialects.
  static const String claudeBudget = 'claude.budget';
  static const String claudeAdaptive = 'claude.adaptive';
  static const String claudeNone = 'claude.none';

  // Gemini generateContent dialects.
  static const String geminiBudget = 'gemini.budget';
  static const String geminiLevel = 'gemini.level';
  static const String geminiNone = 'gemini.none';

  static const Set<String> all = <String>{
    auto,
    chatEffort,
    chatReasoningEffortObj,
    chatReasoningBudgetObj,
    chatThinkingBudget,
    chatEnableThinking,
    chatThinkingMode,
    chatTemplateKwargs,
    chatNone,
    responsesEffort,
    responsesNone,
    claudeBudget,
    claudeAdaptive,
    claudeNone,
    geminiBudget,
    geminiLevel,
    geminiNone,
  };

  static const List<String> _chatKeys = <String>[
    'reasoning_effort',
    'reasoning',
    'thinking',
    'enable_thinking',
    'thinking_mode',
    'thinking_budget',
    'chat_template_kwargs',
    'reasoning_content',
    'reasoning_budget',
  ];

  static const Map<String, List<String>> _owns = <String, List<String>>{
    chatEffort: <String>['reasoning_effort', 'reasoning', 'thinking'],
    chatReasoningEffortObj: <String>[
      'reasoning_effort',
      'reasoning',
      'thinking',
    ],
    chatReasoningBudgetObj: <String>[
      'reasoning_effort',
      'reasoning',
      'thinking',
    ],
    chatThinkingBudget: <String>['reasoning_effort', 'reasoning', 'thinking'],
    chatEnableThinking: <String>[
      'reasoning_effort',
      'reasoning',
      'thinking',
      'enable_thinking',
      'thinking_budget',
    ],
    chatThinkingMode: <String>[
      'reasoning_effort',
      'reasoning',
      'thinking',
      'thinking_mode',
    ],
    chatTemplateKwargs: <String>[
      'reasoning_effort',
      'reasoning',
      'thinking',
      'chat_template_kwargs',
    ],
    chatNone: <String>[..._chatKeys],
  };

  /// Keys a dialect may write; cleared before writing so switching formats
  /// never leaves a stale representation behind.
  static List<String> ownedChatKeys(String wire) =>
      _owns[wire] ?? const <String>[];

  /// Unknown ids behave as `auto` (forward compatible with stored data).
  static String normalize(String? wire) {
    final value = (wire ?? '').trim();
    if (value.isEmpty) return auto;
    return all.contains(value) ? value : auto;
  }

  /// Whether [wire] asks for an explicit dialect (i.e. not `auto`).
  static bool isExplicit(String? wire) => normalize(wire) != auto;

  /// Toggle-only formats cannot express a token budget.
  static bool isToggleOnly(String wire) =>
      wire == chatThinkingMode ||
      wire == chatTemplateKwargs ||
      wire == chatEnableThinking;

  static List<String> optionsFor(ReasoningWireTransport transport) {
    switch (transport) {
      case ReasoningWireTransport.responses:
        return const <String>[auto, responsesEffort, responsesNone];
      case ReasoningWireTransport.claude:
        return const <String>[auto, claudeBudget, claudeAdaptive, claudeNone];
      case ReasoningWireTransport.gemini:
        return const <String>[auto, geminiBudget, geminiLevel, geminiNone];
      case ReasoningWireTransport.chat:
        return const <String>[
          auto,
          chatEffort,
          chatReasoningEffortObj,
          chatReasoningBudgetObj,
          chatThinkingBudget,
          chatEnableThinking,
          chatThinkingMode,
          chatTemplateKwargs,
          chatNone,
        ];
    }
  }
}

enum ReasoningWireTransport { chat, responses, claude, gemini }

/// Resolve the transport from a provider kind name + `useResponseApi`.
ReasoningWireTransport reasoningWireTransportFor({
  required String providerType,
  bool useResponseApi = false,
}) {
  switch (providerType.trim().toLowerCase()) {
    case 'claude':
      return ReasoningWireTransport.claude;
    case 'google':
      return ReasoningWireTransport.gemini;
    case 'openai':
    case 'neuralwatt':
    default:
      return useResponseApi
          ? ReasoningWireTransport.responses
          : ReasoningWireTransport.chat;
  }
}

/// Read `modelOverrides[logicalKey]['reasoningWire']`, falling back to a
/// reverse lookup through `apiModelId` (Claude paths pass the upstream id).
/// Returns a normalized wire id, or `null` when the model follows `auto`.
String? reasoningWireForCall(dynamic config, String modelId) {
  if (config == null) return null;
  try {
    final overrides = (config as dynamic).modelOverrides;
    if (overrides is! Map) return null;
    final direct = _wireFromEntry(overrides[modelId]);
    if (direct != null) return direct;
    final lowerId = modelId.trim().toLowerCase();
    for (final entry in overrides.values) {
      if (entry is! Map) continue;
      final apiId = (entry['apiModelId'] ?? entry['api_model_id'])?.toString();
      if (apiId == null || apiId.trim().toLowerCase() != lowerId) continue;
      final candidate = _wireFromEntry(entry);
      if (candidate != null) return candidate;
    }
  } catch (_) {}
  return null;
}

String? _wireFromEntry(Object? entry) {
  if (entry is! Map) return null;
  final raw = entry['reasoningWire'];
  if (raw is! String) return null;
  final normalized = ReasoningWire.normalize(raw);
  return normalized == ReasoningWire.auto ? null : normalized;
}

// ============================================================================
// Auto chains — extracted verbatim from ChatApiService. `auto` must remain
// byte-identical to the pre-dialect behaviour.
// ============================================================================

bool _isOff(int? budget) => ReasoningBudget.isOff(budget);

/// Vendor reasoning knobs for OpenAI Chat Completions hosts.
///
/// Callers only invoke this for non-Responses requests (the original inline
/// chain was gated on `useResponseApi != true`).
void applyAutoChatReasoningChain(
  Map<String, dynamic> body, {
  required String host,
  required String upstreamModelId,
  required bool isReasoning,
  required int? thinkingBudget,
  required bool isZhipu,
  required bool isMimo,
}) {
  final off = _isOff(thinkingBudget);
  if (host.contains('openrouter.ai')) {
    if (isReasoning) {
      // OpenRouter uses `reasoning.enabled/max_tokens`
      if (off) {
        body['reasoning'] = {'enabled': false};
      } else {
        final obj = <String, dynamic>{'enabled': true};
        if (thinkingBudget != null && thinkingBudget > 0) {
          obj['max_tokens'] = thinkingBudget;
        }
        body['reasoning'] = obj;
      }
      body.remove('reasoning_effort');
    } else {
      body.remove('reasoning');
      body.remove('reasoning_effort');
    }
  } else if (host.contains('dashscope') || host.contains('aliyun')) {
    // Aliyun DashScope: enable_thinking + thinking_budget
    if (isReasoning) {
      body['enable_thinking'] = !off;
      if (!off && thinkingBudget != null && thinkingBudget > 0) {
        body['thinking_budget'] = thinkingBudget;
      } else {
        body.remove('thinking_budget');
      }
    } else {
      body.remove('enable_thinking');
      body.remove('thinking_budget');
    }
    body.remove('reasoning_effort');
  } else if (isZhipu || isMimo) {
    // Zhipu (BigModel) / Xiaomi MiMo: thinking.type enabled/disabled
    if (isReasoning) {
      body['thinking'] = {'type': off ? 'disabled' : 'enabled'};
    } else {
      body.remove('thinking');
    }
    body.remove('reasoning_effort');
  } else if (host.contains('ark.cn-beijing.volces.com') ||
      host.contains('volc') ||
      host.contains('ark')) {
    // Volc Ark: thinking: { type: enabled|disabled }
    if (isReasoning) {
      body['thinking'] = {'type': off ? 'disabled' : 'enabled'};
    } else {
      body.remove('thinking');
    }
    body.remove('reasoning_effort');
  } else if (host.contains('intern-ai') ||
      host.contains('intern') ||
      host.contains('chat.intern-ai.org.cn')) {
    // InternLM (InternAI): thinking_mode boolean switch
    if (isReasoning) {
      body['thinking_mode'] = !off;
    } else {
      body.remove('thinking_mode');
    }
    body.remove('reasoning_effort');
  } else if (host.contains('siliconflow')) {
    // SiliconFlow: OFF -> enable_thinking: false; otherwise omit
    if (isReasoning) {
      if (off) {
        body['enable_thinking'] = false;
      } else {
        body.remove('enable_thinking');
      }
    } else {
      body.remove('enable_thinking');
    }
    body.remove('reasoning_effort');
  } else if (host.contains('deepseek') ||
      upstreamModelId.toLowerCase().contains('deepseek')) {
    if (isReasoning) {
      if (off) {
        body['reasoning_content'] = false;
        body.remove('reasoning_budget');
      } else {
        body['reasoning_content'] = true;
        if (thinkingBudget != null && thinkingBudget > 0) {
          body['reasoning_budget'] = thinkingBudget;
        } else {
          body.remove('reasoning_budget');
        }
      }
    } else {
      body.remove('reasoning_content');
      body.remove('reasoning_budget');
    }
  }
}

/// Dispatch for OpenAI Chat Completions: `auto` → vendor chain, otherwise the
/// selected dialect.
void applyChatReasoningWire(
  Map<String, dynamic> body, {
  required String? wire,
  required String host,
  required String upstreamModelId,
  required bool isReasoning,
  required int? thinkingBudget,
  required ReasoningCapabilities caps,
  required bool isZhipu,
  required bool isMimo,
  String effort = 'auto',
}) {
  final selected = ReasoningWire.normalize(wire);
  // Dialects are transport-scoped: a value saved for another transport (e.g.
  // after toggling the Responses API) is unknown here and falls back to auto.
  if (selected == ReasoningWire.auto ||
      ReasoningWire.ownedChatKeys(selected).isEmpty) {
    applyAutoChatReasoningChain(
      body,
      host: host,
      upstreamModelId: upstreamModelId,
      isReasoning: isReasoning,
      thinkingBudget: thinkingBudget,
      isZhipu: isZhipu,
      isMimo: isMimo,
    );
    return;
  }

  for (final key in ReasoningWire.ownedChatKeys(selected)) {
    body.remove(key);
  }
  if (!isReasoning) return;

  final off = _isOff(thinkingBudget);
  final alwaysOn = caps.thinkingAlwaysOn;
  final effectiveOff = off && !alwaysOn;
  final budget =
      thinkingBudget != null && thinkingBudget > 0 ? thinkingBudget : null;

  switch (selected) {
    case ReasoningWire.chatEffort:
      // Off: send the declared fallback (an always-thinking model keeps
      // reasoning on at that tier); otherwise omit the parameter entirely.
      if (off) {
        final fallback = caps.openAiOffFallback;
        if (fallback != null && fallback.trim().isNotEmpty) {
          body['reasoning_effort'] = fallback;
        }
      } else if (effort != 'auto' && effort.isNotEmpty) {
        body['reasoning_effort'] = effort;
      }
    case ReasoningWire.chatReasoningEffortObj:
      final value = _offRespectingEffort(
        caps,
        off: off,
        effort: effort,
      );
      if (value != null) body['reasoning'] = <String, dynamic>{'effort': value};
    case ReasoningWire.chatReasoningBudgetObj:
      if (effectiveOff) {
        body['reasoning'] = <String, dynamic>{'enabled': false};
      } else {
        body['reasoning'] = <String, dynamic>{
          'enabled': true,
          if (budget != null) 'max_tokens': budget,
        };
      }
    case ReasoningWire.chatThinkingBudget:
      if (effectiveOff) {
        body['thinking'] = <String, dynamic>{'type': 'disabled'};
      } else {
        body['thinking'] = <String, dynamic>{
          'type': 'enabled',
          if (budget != null) 'budget_tokens': budget,
        };
      }
    case ReasoningWire.chatEnableThinking:
      body['enable_thinking'] = !effectiveOff;
      if (!effectiveOff && budget != null) {
        body['thinking_budget'] = budget;
      }
    case ReasoningWire.chatThinkingMode:
      body['thinking_mode'] = !effectiveOff;
    case ReasoningWire.chatTemplateKwargs:
      body['chat_template_kwargs'] = <String, dynamic>{
        'thinking': !effectiveOff,
      };
    case ReasoningWire.chatNone:
      break;
    default:
      break;
  }
}

/// Off handling shared by effort-object dialects: prefer the model's declared
/// fallback, then `none`, then the first supported tier.
String? _offRespectingEffort(
  ReasoningCapabilities caps, {
  required bool off,
  required String effort,
}) {
  if (!off) return effort == 'auto' ? null : effort;
  final declared = caps.openAiOffFallback;
  if (declared != null && declared.trim().isNotEmpty) return declared;
  if (caps.openAiEfforts.isEmpty || caps.openAiEfforts.contains('none')) {
    return 'none';
  }
  return caps.openAiEfforts.first;
}

// ============================================================================
// Responses
// ============================================================================

void applyResponsesReasoningWire(
  Map<String, dynamic> body, {
  required String? wire,
  required bool isReasoning,
  required int? thinkingBudget,
  required ReasoningCapabilities caps,
  String effort = 'auto',
}) {
  final selected = ReasoningWire.normalize(wire);
  final isResponsesDialect =
      selected == ReasoningWire.responsesEffort ||
      selected == ReasoningWire.responsesNone;
  body.remove('reasoning');
  if (!isReasoning) return;

  if (selected == ReasoningWire.auto || !isResponsesDialect) {
    // Mirror the pre-dialect condition exactly: `effort` is already
    // normalized through `openAiOffFallback`, so an always-thinking model
    // keeps a reasoning object at its fallback tier even when Off is selected.
    if (effort == 'off') return;
    body['reasoning'] = <String, dynamic>{
      'summary': 'auto',
      if (effort != 'auto') 'effort': effort,
    };
    return;
  }
  if (selected == ReasoningWire.responsesNone) return;

  final off = _isOff(thinkingBudget);
  if (off && !caps.thinkingAlwaysOn) return;
  final fallback = caps.openAiOffFallback;
  body['reasoning'] = <String, dynamic>{
    'summary': 'auto',
    if (effort != 'auto')
      'effort': effort
    else if (off && fallback != null && fallback.isNotEmpty)
      'effort': fallback,
  };
}

// ============================================================================
// Claude Messages
// ============================================================================

class ClaudeWireConfig {
  const ClaudeWireConfig({
    this.active = false,
    this.thinking,
    this.outputConfig,
    this.usesAdaptive = false,
  });

  /// False means "caller keeps the existing auto logic".
  final bool active;
  final Map<String, dynamic>? thinking;
  final Map<String, dynamic>? outputConfig;
  final bool usesAdaptive;
}

ClaudeWireConfig resolveClaudeReasoningWire({
  required String? wire,
  required bool isReasoning,
  required int? thinkingBudget,
  required ReasoningCapabilities caps,
  String effort = 'auto',
}) {
  final selected = ReasoningWire.normalize(wire);
  if (selected == ReasoningWire.auto) return const ClaudeWireConfig();
  if (!isReasoning) {
    return const ClaudeWireConfig(active: true);
  }

  final off = _isOff(thinkingBudget);
  final effectiveOff = off && !caps.thinkingAlwaysOn;
  final budget =
      thinkingBudget != null && thinkingBudget > 0 ? thinkingBudget : null;

  switch (selected) {
    case ReasoningWire.claudeBudget:
      // Anthropic rejects `enabled` without `budget_tokens`, and an auto
      // budget arrives as null — fall back to the documented minimum.
      final enabledBudget = budget ?? ReasoningBudget.light;
      return ClaudeWireConfig(
        active: true,
        thinking: effectiveOff
            ? const <String, dynamic>{'type': 'disabled'}
            : <String, dynamic>{
                'type': 'enabled',
                'budget_tokens': enabledBudget,
              },
      );
    case ReasoningWire.claudeAdaptive:
      final useAdaptive = !effectiveOff;
      // `off` is an internal tier id, not an Anthropic effort value; an
      // always-thinking model falls back to its declared tier (or lets the
      // provider pick by omitting output_config).
      final adaptiveEffort = effort == 'off' ? caps.openAiOffFallback : effort;
      final hasEffort = adaptiveEffort != null &&
          adaptiveEffort != 'auto' &&
          adaptiveEffort != 'off';
      return ClaudeWireConfig(
        active: true,
        thinking: useAdaptive
            ? const <String, dynamic>{
                'type': 'adaptive',
                'display': 'summarized',
              }
            : const <String, dynamic>{'type': 'disabled'},
        outputConfig: useAdaptive && hasEffort
            ? <String, dynamic>{'effort': adaptiveEffort}
            : null,
        usesAdaptive: useAdaptive,
      );
    case ReasoningWire.claudeNone:
      return const ClaudeWireConfig(active: true);
    default:
      return const ClaudeWireConfig();
  }
}

// ============================================================================
// Gemini generateContent
// ============================================================================

/// Returns the `thinkingConfig` map, or `null` to omit it.
Map<String, dynamic>? resolveGeminiThinkingConfig({
  required String? wire,
  required String modelId,
  required bool isReasoning,
  required int? thinkingBudget,
}) {
  final selected = ReasoningWire.normalize(wire);
  if (!isReasoning) return null;

  final isGeminiDialect =
      selected == ReasoningWire.geminiBudget ||
      selected == ReasoningWire.geminiLevel ||
      selected == ReasoningWire.geminiNone;
  if (selected == ReasoningWire.auto || !isGeminiDialect) {
    return autoGeminiThinkingConfig(
      modelId: modelId,
      thinkingBudget: thinkingBudget,
    );
  }
  if (selected == ReasoningWire.geminiNone) return null;

  final off = _isOff(thinkingBudget);
  if (selected == ReasoningWire.geminiBudget) {
    if (off) return const <String, dynamic>{'includeThoughts': false};
    return <String, dynamic>{
      'includeThoughts': true,
      if (thinkingBudget != null && thinkingBudget >= 0)
        'thinkingBudget': thinkingBudget,
    };
  }

  // gemini.level
  final isPro = modelId.contains(
    RegExp(r'gemini-3.*-pro(-preview)?', caseSensitive: false),
  );
  if (isPro) {
    return <String, dynamic>{
      'includeThoughts': true,
      'thinkingLevel': off ? 'low' : 'high',
    };
  }
  String level = 'high';
  if (off) {
    level = 'minimal';
  } else if (thinkingBudget != null && thinkingBudget > 0) {
    if (thinkingBudget < 8000) {
      level = 'low';
    } else if (thinkingBudget < 24000) {
      level = 'medium';
    }
  }
  return <String, dynamic>{'includeThoughts': true, 'thinkingLevel': level};
}

/// The auto Gemini thinking configuration, extracted from the inline block.
Map<String, dynamic> autoGeminiThinkingConfig({
  required String modelId,
  required int? thinkingBudget,
}) {
  final off = _isOff(thinkingBudget);
  // Match gemini-3-pro, gemini-3-flash, gemini-3-lite and 3.x variants
  final isGemini3ProImage = modelId.contains(
    RegExp(r'gemini-3.*-pro-image(-preview)?', caseSensitive: false),
  );
  final isGemini3Pro = modelId.contains(
    RegExp(r'gemini-3.*-pro(-preview)?', caseSensitive: false),
  );
  final isGemini3FlashOrLite = modelId.contains(
    RegExp(r'gemini-3.*-(flash|lite)(-preview)?', caseSensitive: false),
  );
  if (isGemini3ProImage) {
    return <String, dynamic>{
      'includeThoughts': true,
      if (thinkingBudget != null && thinkingBudget >= 0)
        'thinkingBudget': thinkingBudget,
    };
  }
  // Gemini 3 Pro: supports 'low' and 'high' only (no off)
  if (isGemini3Pro) {
    String level = 'high';
    if (off || (thinkingBudget != null && thinkingBudget > 0 && thinkingBudget < 8000)) {
      level = 'low';
    }
    return <String, dynamic>{'includeThoughts': true, 'thinkingLevel': level};
  }
  // Gemini 3 Flash / Lite: supports 'minimal', 'low', 'medium', 'high'
  if (isGemini3FlashOrLite) {
    String level = 'high';
    if (off) {
      level = 'minimal';
    } else if (thinkingBudget != null && thinkingBudget > 0) {
      if (thinkingBudget < 8000) {
        level = 'low';
      } else if (thinkingBudget < 24000) {
        level = 'medium';
      }
    }
    return <String, dynamic>{'includeThoughts': true, 'thinkingLevel': level};
  }
  // Gemini 2.x and below: use thinkingBudget
  if (off) return const <String, dynamic>{'includeThoughts': false};
  return <String, dynamic>{
    'includeThoughts': true,
    if (thinkingBudget != null && thinkingBudget >= 0)
      'thinkingBudget': thinkingBudget,
  };
}
