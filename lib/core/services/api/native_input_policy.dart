// Per-request policy for native audio/PDF input.
//
// Resolves the three inputs the wire serializer needs — capability, transport
// protocol and host gate — from the same catalog + per-model override ladder
// the transport uses. Kept out of `native_input_parts.dart` so that library
// stays pure Dart.

import '../../providers/model_provider.dart';
import '../../providers/settings_provider.dart';
import 'native_input_parts.dart';

/// Which native inputs may travel on this request.
class NativeInputPolicy {
  const NativeInputPolicy({
    required this.protocol,
    required this.baseUrl,
    required this.nativePdf,
    required this.nativeAudio,
  });

  final NativeInputProtocol protocol;
  final String baseUrl;
  final bool nativePdf;
  final bool nativeAudio;

  bool get enabled => nativePdf || nativeAudio;

  static const NativeInputPolicy disabled = NativeInputPolicy(
    protocol: NativeInputProtocol.openAiChat,
    baseUrl: '',
    nativePdf: false,
    nativeAudio: false,
  );
}

/// Transport that will send this request. Mirrors `ChatApiService` dispatch.
NativeInputProtocol nativeInputProtocolFor(ProviderConfig cfg) {
  final kind = ProviderConfig.classify(cfg.id, explicitType: cfg.providerType);
  switch (kind) {
    case ProviderKind.google:
      return NativeInputProtocol.gemini;
    case ProviderKind.claude:
      return NativeInputProtocol.claude;
    case ProviderKind.openai:
    case ProviderKind.neuralwatt:
      return cfg.useResponseApi == true
          ? NativeInputProtocol.responses
          : NativeInputProtocol.openAiChat;
  }
}

bool _isOfficialClaude(ProviderConfig cfg) =>
    NativeInputParts.hostOf(cfg.baseUrl) == 'api.anthropic.com';

bool _isOfficialGoogle(ProviderConfig cfg) {
  if (cfg.vertexAI == true) return true;
  final host = NativeInputParts.hostOf(cfg.baseUrl);
  return host == 'generativelanguage.googleapis.com' ||
      host == 'aiplatform.googleapis.com';
}

bool _isOfficialOpenAi(ProviderConfig cfg) =>
    NativeInputParts.hostOf(cfg.baseUrl) == 'api.openai.com';

bool _isOpenRouter(ProviderConfig cfg) =>
    NativeInputParts.hostOf(cfg.baseUrl).contains('openrouter.ai');

bool _isDashScope(ProviderConfig cfg) =>
    NativeInputParts.hostOf(cfg.baseUrl).contains('dashscope');

/// Default (auto) host gate for native PDF. Per-model `nativePdf` overrides it.
///
/// Official endpoints are enabled because they are the ones whose PDF
/// pass-through is verified; relays default to text extraction (§5-6).
bool nativePdfDefaultFor(ProviderConfig cfg) {
  switch (nativeInputProtocolFor(cfg)) {
    case NativeInputProtocol.claude:
      return _isOfficialClaude(cfg);
    case NativeInputProtocol.gemini:
      return _isOfficialGoogle(cfg);
    case NativeInputProtocol.responses:
      return _isOfficialOpenAi(cfg);
    case NativeInputProtocol.openAiChat:
      // OpenRouter is verified to accept `file` with file_data (§1.2).
      return _isOfficialOpenAi(cfg) || _isOpenRouter(cfg);
  }
}

/// Default (auto) host gate for native audio. Responses/Claude have no audio
/// wire at all, so they always return false.
bool nativeAudioDefaultFor(ProviderConfig cfg) {
  switch (nativeInputProtocolFor(cfg)) {
    case NativeInputProtocol.responses:
    case NativeInputProtocol.claude:
      return false;
    case NativeInputProtocol.gemini:
      return _isOfficialGoogle(cfg);
    case NativeInputProtocol.openAiChat:
      return _isOfficialOpenAi(cfg) || _isDashScope(cfg);
  }
}

/// AI Team fan-out must not reuse the selected model's native capability for
/// every proposer/aggregator (multimodal plan §7 F10).
bool nativeInputsEnabledForAiTeam({
  required bool aiTeamEnabled,
  required bool hasProposers,
}) => !(aiTeamEnabled && hasProposers);

/// Resolve the policy for a conversation's selected provider/model.
NativeInputPolicy resolveNativeInputPolicy(
  SettingsProvider settings,
  String providerKey,
  String modelId,
) => resolveNativeInputPolicyForConfig(
  settings.getProviderConfig(providerKey),
  modelId,
);

/// Config-only variant used by tests and by callers that already hold the
/// [ProviderConfig] (keeps the resolver free of provider/settings plumbing).
///
/// Priority: explicit per-model `nativePdf`/`nativeAudio` → host default.
/// Capability is always required (catalog/modality override).
NativeInputPolicy resolveNativeInputPolicyForConfig(
  ProviderConfig providerConfig,
  String modelId,
) {
  final cfg = providerConfig.forModelProtocol(modelId);
  final protocol = nativeInputProtocolFor(cfg);
  final rawOverride = cfg.modelOverrides[modelId];
  final override = rawOverride is Map ? rawOverride : null;

  var upstream = modelId;
  final mapped =
      (override?['apiModelId'] ?? override?['api_model_id'])?.toString().trim();
  if (mapped != null && mapped.isNotEmpty) upstream = mapped;

  final info = ModelRegistry.applyOverride(
    ModelRegistry.inferForProvider(
      ModelInfo(id: upstream, displayName: upstream),
      cfg,
    ),
    override,
  );
  final supportsPdf = info.input.contains(Modality.pdf);
  final supportsAudio = info.input.contains(Modality.audio);

  final forcedPdf = override?['nativePdf'] is bool
      ? override!['nativePdf'] as bool
      : null;
  final forcedAudio = override?['nativeAudio'] is bool
      ? override!['nativeAudio'] as bool
      : null;

  final protocolHasAudio =
      protocol == NativeInputProtocol.openAiChat ||
      protocol == NativeInputProtocol.gemini;

  return NativeInputPolicy(
    protocol: protocol,
    baseUrl: cfg.baseUrl,
    nativePdf: supportsPdf && (forcedPdf ?? nativePdfDefaultFor(cfg)),
    nativeAudio:
        supportsAudio &&
        protocolHasAudio &&
        (forcedAudio ?? nativeAudioDefaultFor(cfg)),
  );
}
