import 'package:OmniChat/core/services/api/reasoning_wire.dart';
import 'package:OmniChat/core/utils/reasoning_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

const ReasoningCapabilities _caps = ReasoningCapabilities(
  supportsXhigh: true,
  openAiEfforts: {'low', 'medium', 'high', 'xhigh'},
);

const ReasoningCapabilities _alwaysOnCaps = ReasoningCapabilities(
  thinkingAlwaysOn: true,
  openAiEfforts: {'low', 'high'},
  openAiOffFallback: 'low',
);

Map<String, dynamic> _body() => <String, dynamic>{'model': 'm'};

void main() {
  group('chat dialects', () {
    test('chat.effort writes reasoning_effort and clears old keys', () {
      final body = _body()
        ..['reasoning'] = {'enabled': true}
        ..['thinking'] = {'type': 'enabled'};
      applyChatReasoningWire(
        body,
        wire: ReasoningWire.chatEffort,
        host: 'api.openai.com',
        upstreamModelId: 'gpt-5.6',
        isReasoning: true,
        thinkingBudget: 32000,
        caps: _caps,
        isZhipu: false,
        isMimo: false,
        effort: 'high',
      );
      expect(body['reasoning_effort'], 'high');
      expect(body.containsKey('reasoning'), isFalse);
      expect(body.containsKey('thinking'), isFalse);
    });

    test('chat.effort Off omits without a fallback, sends it with one', () {
      final plain = _body();
      applyChatReasoningWire(
        plain,
        wire: ReasoningWire.chatEffort,
        host: 'api.openai.com',
        upstreamModelId: 'gpt-5.6',
        isReasoning: true,
        thinkingBudget: 0,
        caps: _caps,
        isZhipu: false,
        isMimo: false,
      );
      expect(plain.containsKey('reasoning_effort'), isFalse);

      final withFallback = _body();
      applyChatReasoningWire(
        withFallback,
        wire: ReasoningWire.chatEffort,
        host: 'api.openai.com',
        upstreamModelId: 'gpt-5.6-luna',
        isReasoning: true,
        thinkingBudget: 0,
        caps: _alwaysOnCaps,
        isZhipu: false,
        isMimo: false,
      );
      // thinkingAlwaysOn keeps the model on at its fallback tier.
      expect(withFallback['reasoning_effort'], 'low');
    });

    test('chat.reasoning_effort_obj writes reasoning.effort', () {
      final body = _body()..['reasoning_effort'] = 'high';
      applyChatReasoningWire(
        body,
        wire: ReasoningWire.chatReasoningEffortObj,
        host: 'api.openai.com',
        upstreamModelId: 'gpt-5.6',
        isReasoning: true,
        thinkingBudget: 16000,
        caps: _caps,
        isZhipu: false,
        isMimo: false,
        effort: 'medium',
      );
      expect(body['reasoning'], {'effort': 'medium'});
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('chat.reasoning_effort_obj Off uses none or the declared fallback',
        () {
      final body = _body();
      applyChatReasoningWire(
        body,
        wire: ReasoningWire.chatReasoningEffortObj,
        host: 'api.openai.com',
        upstreamModelId: 'm',
        isReasoning: true,
        thinkingBudget: 0,
        caps: _caps,
        isZhipu: false,
        isMimo: false,
      );
      // `_caps` has no `none` tier, so Off falls back to the lowest
      // supported tier (the wire has no "omit" spelling for this shape).
      expect(body['reasoning'], {'effort': 'low'});

      final fallback = _body();
      applyChatReasoningWire(
        fallback,
        wire: ReasoningWire.chatReasoningEffortObj,
        host: 'api.openai.com',
        upstreamModelId: 'm',
        isReasoning: true,
        thinkingBudget: 0,
        caps: _alwaysOnCaps,
        isZhipu: false,
        isMimo: false,
      );
      expect(fallback['reasoning'], {'effort': 'low'});
    });

    test('chat.reasoning_budget_obj writes enabled and max_tokens', () {
      final on = _body();
      applyChatReasoningWire(
        on,
        wire: ReasoningWire.chatReasoningBudgetObj,
        host: 'api.openai.com',
        upstreamModelId: 'm',
        isReasoning: true,
        thinkingBudget: 16000,
        caps: _caps,
        isZhipu: false,
        isMimo: false,
      );
      expect(on['reasoning'], {'enabled': true, 'max_tokens': 16000});

      final off = _body();
      applyChatReasoningWire(
        off,
        wire: ReasoningWire.chatReasoningBudgetObj,
        host: 'api.openai.com',
        upstreamModelId: 'm',
        isReasoning: true,
        thinkingBudget: 0,
        caps: _caps,
        isZhipu: false,
        isMimo: false,
      );
      expect(off['reasoning'], {'enabled': false});
    });

    test('chat.thinking_budget writes thinking.type/budget_tokens', () {
      final body = _body();
      applyChatReasoningWire(
        body,
        wire: ReasoningWire.chatThinkingBudget,
        host: 'api.openai.com',
        upstreamModelId: 'm',
        isReasoning: true,
        thinkingBudget: 1024,
        caps: _caps,
        isZhipu: false,
        isMimo: false,
      );
      expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 1024});

      final off = _body();
      applyChatReasoningWire(
        off,
        wire: ReasoningWire.chatThinkingBudget,
        host: 'api.openai.com',
        upstreamModelId: 'm',
        isReasoning: true,
        thinkingBudget: 0,
        caps: _caps,
        isZhipu: false,
        isMimo: false,
      );
      expect(off['thinking'], {'type': 'disabled'});
    });

    test('chat.enable_thinking mirrors DashScope keys', () {
      final body = _body();
      applyChatReasoningWire(
        body,
        wire: ReasoningWire.chatEnableThinking,
        host: 'dashscope.aliyuncs.com',
        upstreamModelId: 'm',
        isReasoning: true,
        thinkingBudget: 4096,
        caps: _caps,
        isZhipu: false,
        isMimo: false,
      );
      expect(body['enable_thinking'], isTrue);
      expect(body['thinking_budget'], 4096);

      final off = _body();
      applyChatReasoningWire(
        off,
        wire: ReasoningWire.chatEnableThinking,
        host: 'dashscope.aliyuncs.com',
        upstreamModelId: 'm',
        isReasoning: true,
        thinkingBudget: 0,
        caps: _caps,
        isZhipu: false,
        isMimo: false,
      );
      expect(off['enable_thinking'], isFalse);
      expect(off.containsKey('thinking_budget'), isFalse);
    });

    test('chat.thinking_mode is a boolean', () {
      final body = _body();
      applyChatReasoningWire(
        body,
        wire: ReasoningWire.chatThinkingMode,
        host: 'chat.intern-ai.org.cn',
        upstreamModelId: 'm',
        isReasoning: true,
        thinkingBudget: null,
        caps: _caps,
        isZhipu: false,
        isMimo: false,
      );
      expect(body['thinking_mode'], isTrue);
    });

    test('chat.template_kwargs nests thinking', () {
      final body = _body();
      applyChatReasoningWire(
        body,
        wire: ReasoningWire.chatTemplateKwargs,
        host: 'api.openai.com',
        upstreamModelId: 'm',
        isReasoning: true,
        thinkingBudget: 0,
        caps: _caps,
        isZhipu: false,
        isMimo: false,
      );
      expect(body['chat_template_kwargs'], {'thinking': false});
    });

    test('chat.none leaves no reasoning keys behind', () {
      final body = _body()
        ..['reasoning_effort'] = 'high'
        ..['reasoning'] = {'enabled': true}
        ..['thinking'] = {'type': 'enabled'}
        ..['enable_thinking'] = true
        ..['thinking_mode'] = true
        ..['thinking_budget'] = 1024
        ..['chat_template_kwargs'] = {'thinking': true}
        ..['reasoning_content'] = true
        ..['reasoning_budget'] = 1024;
      applyChatReasoningWire(
        body,
        wire: ReasoningWire.chatNone,
        host: 'api.openai.com',
        upstreamModelId: 'm',
        isReasoning: true,
        thinkingBudget: 32000,
        caps: _caps,
        isZhipu: false,
        isMimo: false,
      );
      for (final key in const [
        'reasoning_effort',
        'reasoning',
        'thinking',
        'enable_thinking',
        'thinking_mode',
        'thinking_budget',
        'chat_template_kwargs',
        'reasoning_content',
        'reasoning_budget',
      ]) {
        expect(body.containsKey(key), isFalse, reason: key);
      }
      expect(body['model'], 'm');
    });

    test('a dialect from another transport falls back to auto', () {
      final body = <String, dynamic>{'model': 'glm-5'};
      applyChatReasoningWire(
        body,
        wire: ReasoningWire.responsesEffort,
        host: 'open.bigmodel.cn',
        upstreamModelId: 'glm-5',
        isReasoning: true,
        thinkingBudget: 16000,
        caps: _caps,
        isZhipu: true,
        isMimo: false,
      );
      expect(body['thinking'], {'type': 'enabled'});
    });
  });

  group('auto chat regression snapshots', () {
    Map<String, dynamic> auto(String host, String model, {bool off = false}) {
      final body = <String, dynamic>{'model': model, 'temperature': 0.7};
      applyChatReasoningWire(
        body,
        wire: ReasoningWire.auto,
        host: host,
        upstreamModelId: model,
        isReasoning: true,
        thinkingBudget: off ? 0 : 16000,
        caps: _caps,
        isZhipu: host.contains('bigmodel') || model.startsWith('glm-'),
        isMimo: host.contains('xiaomimimo') || model.startsWith('mimo-'),
        effort: 'medium',
      );
      return body;
    }

    test('openrouter', () {
      final body = auto('openrouter.ai', 'openai/gpt-5');
      expect(body['reasoning'], {'enabled': true, 'max_tokens': 16000});
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('dashscope', () {
      final body = auto('dashscope.aliyuncs.com', 'qwen3-max');
      expect(body['enable_thinking'], isTrue);
      expect(body['thinking_budget'], 16000);
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('zhipu', () {
      final body = auto('open.bigmodel.cn', 'glm-5');
      expect(body['thinking'], {'type': 'enabled'});
      expect(body.containsKey('reasoning_effort'), isFalse);
      final off = auto('open.bigmodel.cn', 'glm-5', off: true);
      expect(off['thinking'], {'type': 'disabled'});
    });

    test('moonshot has no vendor knob of its own', () {
      final body = auto('api.moonshot.cn', 'kimi-k2.6');
      expect(body.containsKey('thinking'), isFalse);
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('deepseek', () {
      final body = auto('api.deepseek.com', 'deepseek-v4');
      expect(body['reasoning_content'], isTrue);
      expect(body['reasoning_budget'], 16000);
      final off = auto('api.deepseek.com', 'deepseek-v4', off: true);
      expect(off['reasoning_content'], isFalse);
    });

    test('intern', () {
      final body = auto('chat.intern-ai.org.cn', 'intern-s1');
      expect(body['thinking_mode'], isTrue);
    });

    test('siliconflow', () {
      final on = auto('api.siliconflow.cn', 'deepseek-ai/DeepSeek-V3');
      // siliconflow wins over the deepseek model-id branch (host order).
      expect(on.containsKey('enable_thinking'), isFalse);
      final off = auto('api.siliconflow.cn', 'Qwen/Qwen3-8B', off: true);
      expect(off['enable_thinking'], isFalse);
    });

    test('auto Off keeps the vendor disabled shape', () {
      final dashscope = auto('dashscope.aliyuncs.com', 'qwen3', off: true);
      expect(dashscope['enable_thinking'], isFalse);
      expect(dashscope.containsKey('thinking_budget'), isFalse);
    });
  });

  group('non-reasoning models', () {
    test('explicit dialect clears its keys without writing', () {
      final body = _body()..['thinking'] = {'type': 'enabled'};
      applyChatReasoningWire(
        body,
        wire: ReasoningWire.chatThinkingBudget,
        host: 'api.openai.com',
        upstreamModelId: 'm',
        isReasoning: false,
        thinkingBudget: 16000,
        caps: _caps,
        isZhipu: false,
        isMimo: false,
      );
      expect(body.containsKey('thinking'), isFalse);
    });
  });

  group('responses dialects', () {
    test('auto writes summary and effort', () {
      final body = _body();
      applyResponsesReasoningWire(
        body,
        wire: null,
        isReasoning: true,
        thinkingBudget: 16000,
        caps: _caps,
        effort: 'medium',
      );
      expect(body['reasoning'], {'summary': 'auto', 'effort': 'medium'});
    });

    test('auto Off keeps an always-thinking model at its fallback tier', () {
      // Pre-dialect behaviour: `effort` is normalized to the declared
      // fallback, so the request must still carry a reasoning object.
      final body = _body();
      applyResponsesReasoningWire(
        body,
        wire: null,
        isReasoning: true,
        thinkingBudget: 0,
        caps: _alwaysOnCaps,
        effort: 'low',
      );
      expect(body['reasoning'], {'summary': 'auto', 'effort': 'low'});

      final plain = _body();
      applyResponsesReasoningWire(
        plain,
        wire: null,
        isReasoning: true,
        thinkingBudget: 0,
        caps: _caps,
        effort: 'off',
      );
      expect(plain.containsKey('reasoning'), isFalse);
    });

    test('responses.effort writes reasoning.effort', () {
      final body = _body();
      applyResponsesReasoningWire(
        body,
        wire: ReasoningWire.responsesEffort,
        isReasoning: true,
        thinkingBudget: 16000,
        caps: _caps,
        effort: 'high',
      );
      expect(body['reasoning'], {'summary': 'auto', 'effort': 'high'});
    });

    test('a chat dialect in the Responses writer falls back to auto', () {
      final body = _body();
      applyResponsesReasoningWire(
        body,
        wire: ReasoningWire.chatEffort,
        isReasoning: true,
        thinkingBudget: 16000,
        caps: _caps,
        effort: 'medium',
      );
      expect(body['reasoning'], {'summary': 'auto', 'effort': 'medium'});
    });

    test('responses.none removes reasoning', () {
      final body = _body()..['reasoning'] = {'effort': 'high'};
      applyResponsesReasoningWire(
        body,
        wire: ReasoningWire.responsesNone,
        isReasoning: true,
        thinkingBudget: 16000,
        caps: _caps,
      );
      expect(body.containsKey('reasoning'), isFalse);
    });
  });

  group('claude dialects', () {
    test('auto is inactive (caller keeps existing logic)', () {
      final config = resolveClaudeReasoningWire(
        wire: null,
        isReasoning: true,
        thinkingBudget: 16000,
        caps: _caps,
      );
      expect(config.active, isFalse);
      expect(config.thinking, isNull);
    });

    test('claude.budget writes enabled + budget_tokens', () {
      final config = resolveClaudeReasoningWire(
        wire: ReasoningWire.claudeBudget,
        isReasoning: true,
        thinkingBudget: 16000,
        caps: _caps,
      );
      expect(config.active, isTrue);
      expect(config.thinking, {'type': 'enabled', 'budget_tokens': 16000});
      expect(config.outputConfig, isNull);
      expect(config.usesAdaptive, isFalse);
    });

    test('claude.budget with an auto budget keeps a valid token count', () {
      final config = resolveClaudeReasoningWire(
        wire: ReasoningWire.claudeBudget,
        isReasoning: true,
        thinkingBudget: null,
        caps: _caps,
      );
      expect(config.thinking, {
        'type': 'enabled',
        'budget_tokens': ReasoningBudget.light,
      });
    });

    test('claude.adaptive Off on an always-thinking model never sends off', () {
      final config = resolveClaudeReasoningWire(
        wire: ReasoningWire.claudeAdaptive,
        isReasoning: true,
        thinkingBudget: 0,
        caps: const ReasoningCapabilities(
          supportsAdaptiveThinking: true,
          thinkingAlwaysOn: true,
        ),
        effort: 'off',
      );
      expect(config.thinking, {
        'type': 'adaptive',
        'display': 'summarized',
      });
      expect(config.outputConfig, isNull);
    });

    test('claude.budget Off disables', () {
      final config = resolveClaudeReasoningWire(
        wire: ReasoningWire.claudeBudget,
        isReasoning: true,
        thinkingBudget: 0,
        caps: _caps,
      );
      expect(config.thinking, {'type': 'disabled'});
    });

    test('claude.adaptive writes adaptive + output_config.effort', () {
      final config = resolveClaudeReasoningWire(
        wire: ReasoningWire.claudeAdaptive,
        isReasoning: true,
        thinkingBudget: 32000,
        caps: _caps,
        effort: 'high',
      );
      expect(config.thinking, {'type': 'adaptive', 'display': 'summarized'});
      expect(config.outputConfig, {'effort': 'high'});
      expect(config.usesAdaptive, isTrue);
    });

    test('a wire from another transport resolves to inactive', () {
      final config = resolveClaudeReasoningWire(
        wire: ReasoningWire.chatEffort,
        isReasoning: true,
        thinkingBudget: 16000,
        caps: _caps,
      );
      expect(config.active, isFalse);
      expect(config.thinking, isNull);
    });

    test('claude.none writes nothing', () {
      final config = resolveClaudeReasoningWire(
        wire: ReasoningWire.claudeNone,
        isReasoning: true,
        thinkingBudget: 32000,
        caps: _caps,
      );
      expect(config.active, isTrue);
      expect(config.thinking, isNull);
      expect(config.outputConfig, isNull);
    });
  });

  group('gemini dialects', () {
    test('auto preserves the 3.x level ladder', () {
      final pro = resolveGeminiThinkingConfig(
        wire: null,
        modelId: 'gemini-3.1-pro',
        isReasoning: true,
        thinkingBudget: 16000,
      );
      expect(pro, {'includeThoughts': true, 'thinkingLevel': 'high'});

      final flashOff = resolveGeminiThinkingConfig(
        wire: null,
        modelId: 'gemini-3.5-flash',
        isReasoning: true,
        thinkingBudget: 0,
      );
      expect(flashOff, {'includeThoughts': true, 'thinkingLevel': 'minimal'});
    });

    test('gemini.budget writes mask + thinkingBudget', () {
      final body = resolveGeminiThinkingConfig(
        wire: ReasoningWire.geminiBudget,
        modelId: 'gemini-3.5-flash',
        isReasoning: true,
        thinkingBudget: 2048,
      );
      expect(body, {'includeThoughts': true, 'thinkingBudget': 2048});
    });

    test('gemini.level maps the budget to a level', () {
      final body = resolveGeminiThinkingConfig(
        wire: ReasoningWire.geminiLevel,
        modelId: 'gemini-3.5-flash',
        isReasoning: true,
        thinkingBudget: 16000,
      );
      expect(body, {'includeThoughts': true, 'thinkingLevel': 'medium'});
    });

    test('gemini.none omits thinkingConfig', () {
      expect(
        resolveGeminiThinkingConfig(
          wire: ReasoningWire.geminiNone,
          modelId: 'gemini-3.5-flash',
          isReasoning: true,
          thinkingBudget: 16000,
        ),
        isNull,
      );
    });
  });

  group('storage lookup', () {
    test('reads the logical key and reverse apiModelId', () {
      final config = _FakeConfig({
        'logical-key': {
          'apiModelId': 'upstream-model',
          'reasoningWire': ReasoningWire.chatThinkingBudget,
        },
      });
      expect(
        reasoningWireForCall(config, 'logical-key'),
        ReasoningWire.chatThinkingBudget,
      );
      expect(
        reasoningWireForCall(config, 'upstream-model'),
        ReasoningWire.chatThinkingBudget,
      );
    });

    test('absent or unknown values resolve to auto', () {
      final config = _FakeConfig({
        'k': {'reasoningWire': 'future.format'},
      });
      expect(reasoningWireForCall(config, 'k'), isNull);
      expect(reasoningWireForCall(_FakeConfig(const {}), 'k'), isNull);
      expect(reasoningWireForCall(null, 'k'), isNull);
    });
  });

  group('option lists', () {
    test('each transport exposes auto plus its dialects', () {
      expect(
        ReasoningWire.optionsFor(ReasoningWireTransport.chat).first,
        ReasoningWire.auto,
      );
      expect(
        ReasoningWire.optionsFor(ReasoningWireTransport.responses),
        contains(ReasoningWire.responsesEffort),
      );
      expect(
        ReasoningWire.optionsFor(ReasoningWireTransport.claude),
        containsAll([
          ReasoningWire.claudeBudget,
          ReasoningWire.claudeAdaptive,
          ReasoningWire.claudeNone,
        ]),
      );
      expect(
        ReasoningWire.optionsFor(ReasoningWireTransport.gemini),
        containsAll([
          ReasoningWire.geminiBudget,
          ReasoningWire.geminiLevel,
          ReasoningWire.geminiNone,
        ]),
      );
    });

    test('transport resolution follows provider kind and Responses flag', () {
      expect(
        reasoningWireTransportFor(providerType: 'openai'),
        ReasoningWireTransport.chat,
      );
      expect(
        reasoningWireTransportFor(
          providerType: 'neuralwatt',
          useResponseApi: true,
        ),
        ReasoningWireTransport.responses,
      );
      expect(
        reasoningWireTransportFor(providerType: 'claude'),
        ReasoningWireTransport.claude,
      );
      expect(
        reasoningWireTransportFor(providerType: 'google'),
        ReasoningWireTransport.gemini,
      );
    });
  });
}

class _FakeConfig {
  const _FakeConfig(this.modelOverrides);

  final Map<String, dynamic> modelOverrides;
}
