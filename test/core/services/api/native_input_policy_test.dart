// Native-input policy matrix (multimodal plan §2.1/§2.2/§5-6/§7 F10).
//
// The resolver is exercised through its config-only entry point, so these are
// plain Dart tests with no provider/settings plumbing.

import 'package:OmniChat/core/providers/settings_provider.dart';
import 'package:OmniChat/core/services/api/native_input_parts.dart';
import 'package:OmniChat/core/services/api/native_input_policy.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderConfig _config({
  required String id,
  required String baseUrl,
  ProviderKind type = ProviderKind.openai,
  bool useResponses = false,
  bool vertex = false,
  Map<String, dynamic>? override,
}) => ProviderConfig(
  id: id,
  enabled: true,
  name: id,
  apiKey: 'test-key',
  baseUrl: baseUrl,
  providerType: type,
  useResponseApi: useResponses,
  vertexAI: vertex,
  models: const ['m'],
  modelOverrides: <String, dynamic>{
    'm': override ??
        const <String, dynamic>{
          'input': ['text', 'audio', 'pdf'],
          'output': ['text'],
          'inputV': 2,
        },
  },
);

void main() {
  test('Claude official enables PDF but never audio', () {
    final policy = resolveNativeInputPolicyForConfig(
      _config(
        id: 'claude',
        baseUrl: 'https://api.anthropic.com/v1',
        type: ProviderKind.claude,
      ),
      'm',
    );
    expect(policy.protocol, NativeInputProtocol.claude);
    expect(policy.nativePdf, isTrue);
    expect(policy.nativeAudio, isFalse);
  });

  test('Claude relay defaults to text extraction', () {
    final policy = resolveNativeInputPolicyForConfig(
      _config(
        id: 'claude-relay',
        baseUrl: 'https://relay.example/v1',
        type: ProviderKind.claude,
      ),
      'm',
    );
    expect(policy.nativePdf, isFalse);
  });

  test('OpenAI official enables PDF and audio', () {
    final policy = resolveNativeInputPolicyForConfig(
      _config(id: 'openai', baseUrl: 'https://api.openai.com/v1'),
      'm',
    );
    expect(policy.protocol, NativeInputProtocol.openAiChat);
    expect(policy.nativePdf, isTrue);
    expect(policy.nativeAudio, isTrue);
  });

  test('aggregator defaults off; per-model override can force on', () {
    final base = resolveNativeInputPolicyForConfig(
      _config(id: 'agg', baseUrl: 'https://aggregator.example/v1'),
      'm',
    );
    expect(base.nativePdf, isFalse);
    expect(base.nativeAudio, isFalse);

    final forced = resolveNativeInputPolicyForConfig(
      _config(
        id: 'agg',
        baseUrl: 'https://aggregator.example/v1',
        override: const <String, dynamic>{
          'input': ['text', 'audio', 'pdf'],
          'inputV': 2,
          'nativePdf': true,
          'nativeAudio': true,
        },
      ),
      'm',
    );
    expect(forced.nativePdf, isTrue);
    expect(forced.nativeAudio, isTrue);
  });

  test('explicit false overrides the official host default', () {
    final policy = resolveNativeInputPolicyForConfig(
      _config(
        id: 'openai',
        baseUrl: 'https://api.openai.com/v1',
        override: const <String, dynamic>{
          'input': ['text', 'audio', 'pdf'],
          'inputV': 2,
          'nativePdf': false,
          'nativeAudio': false,
        },
      ),
      'm',
    );
    expect(policy.nativePdf, isFalse);
    expect(policy.nativeAudio, isFalse);
  });

  test('Responses never advertises native audio', () {
    final policy = resolveNativeInputPolicyForConfig(
      _config(
        id: 'openai',
        baseUrl: 'https://api.openai.com/v1',
        useResponses: true,
      ),
      'm',
    );
    expect(policy.protocol, NativeInputProtocol.responses);
    expect(policy.nativePdf, isTrue);
    expect(policy.nativeAudio, isFalse);
  });

  test('Gemini official and Vertex enable PDF and audio', () {
    final official = resolveNativeInputPolicyForConfig(
      _config(
        id: 'google',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        type: ProviderKind.google,
      ),
      'm',
    );
    expect(official.protocol, NativeInputProtocol.gemini);
    expect(official.nativePdf, isTrue);
    expect(official.nativeAudio, isTrue);

    final vertex = resolveNativeInputPolicyForConfig(
      _config(
        id: 'vertex',
        baseUrl: 'https://aiplatform.googleapis.com/v1',
        type: ProviderKind.google,
        vertex: true,
      ),
      'm',
    );
    expect(vertex.nativePdf, isTrue);
    expect(vertex.nativeAudio, isTrue);
  });

  test('capability is required even on an official host', () {
    final policy = resolveNativeInputPolicyForConfig(
      _config(
        id: 'openai',
        baseUrl: 'https://api.openai.com/v1',
        override: const <String, dynamic>{
          'input': ['text'],
          'inputV': 2,
        },
      ),
      'm',
    );
    expect(policy.nativePdf, isFalse);
    expect(policy.nativeAudio, isFalse);
  });

  test('AI Team disables native inputs only when it actually fans out', () {
    expect(
      nativeInputsEnabledForAiTeam(aiTeamEnabled: true, hasProposers: true),
      isFalse,
    );
    expect(
      nativeInputsEnabledForAiTeam(aiTeamEnabled: true, hasProposers: false),
      isTrue,
    );
    expect(
      nativeInputsEnabledForAiTeam(aiTeamEnabled: false, hasProposers: true),
      isTrue,
    );
  });
}
