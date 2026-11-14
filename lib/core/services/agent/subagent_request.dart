// One helper transport request (docs/子代理P0-P1修正實作計畫.md Phase 0-2 / P1-6).
//
// A value object so the wire parameters a helper sends (sampling, session id,
// image policy, tool set) can be asserted in a unit test without a provider.
// The runner builds it; the tool handler turns it into a ChatApiService call.

/// Immutable description of one `sendMessageStream` call for a helper run.
class SubagentRoundRequest {
  const SubagentRoundRequest({
    this.providerKey = '',
    this.modelId = '',
    required this.messages,
    this.tools,
    this.extraHeaders,
    this.extraBody,
    this.maxTokens,
    this.temperature,
    this.topP,
    this.thinkingBudget,
    this.toolImagesEnabled = true,
    this.webFetchEnabled = true,
    this.requestId,
    this.sessionId,
    this.textOnly = false,
  });

  /// Effective provider/model of the helper. The runner leaves these empty;
  /// the transport binding fills them from the resolved launch config (a
  /// profile may pre-bind a different provider — A5).
  final String providerKey;
  final String modelId;
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>>? tools;
  final Map<String, String>? extraHeaders;
  final Map<String, dynamic>? extraBody;
  final int? maxTokens;
  final double? temperature;
  final double? topP;
  final int? thinkingBudget;

  /// Whether tool-result images may travel with this request (the caller
  /// attaches a per-run [ToolImagePolicy] instance; never a shared parent one).
  final bool toolImagesEnabled;
  final bool webFetchEnabled;

  /// Provider request key (the main run's plus a per-helper suffix).
  final String? requestId;

  /// Provider prompt-cache key; stable across every round of one helper.
  final String? sessionId;

  /// Text-only round: no tools, no web fetch, no image policy.
  final bool textOnly;

  SubagentRoundRequest copyWith({
    String? providerKey,
    String? modelId,
    List<Map<String, dynamic>>? messages,
    List<Map<String, dynamic>>? tools,
    bool clearTools = false,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
    int? maxTokens,
    double? temperature,
    double? topP,
    int? thinkingBudget,
    bool? toolImagesEnabled,
    bool? webFetchEnabled,
    String? requestId,
    String? sessionId,
    bool? textOnly,
  }) {
    return SubagentRoundRequest(
      providerKey: providerKey ?? this.providerKey,
      modelId: modelId ?? this.modelId,
      messages: messages ?? this.messages,
      tools: clearTools ? null : (tools ?? this.tools),
      extraHeaders: extraHeaders ?? this.extraHeaders,
      extraBody: extraBody ?? this.extraBody,
      maxTokens: maxTokens ?? this.maxTokens,
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      thinkingBudget: thinkingBudget ?? this.thinkingBudget,
      toolImagesEnabled: toolImagesEnabled ?? this.toolImagesEnabled,
      webFetchEnabled: webFetchEnabled ?? this.webFetchEnabled,
      requestId: requestId ?? this.requestId,
      sessionId: sessionId ?? this.sessionId,
      textOnly: textOnly ?? this.textOnly,
    );
  }
}
