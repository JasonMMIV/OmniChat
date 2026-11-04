// OpenCode (Console/Zen/Go) wire helpers.
//
// OpenCode requires a stable per-conversation `x-opencode-session` header on
// inference requests. The value is opaque; the conversation id is the natural
// source. When no conversation id is available (title generation, OCR, ...),
// fall back to a deterministic id instead of a random one so provider-side
// routing and prompt-cache prefixes stay stable across equivalent requests.

import '../auth/oauth_pkce.dart';

/// Identifies OmniChat to OpenCode. Never impersonate the official client.
const String kOpenCodeClientId = 'omnichat';

const String kOpenCodeZenBaseUrl = 'https://opencode.ai/zen/v1';
const String kOpenCodeGoBaseUrl = 'https://opencode.ai/zen/go/v1';

/// Exact-host match only: `opencode.ai` is the OpenCode inference gateway.
/// Lookalike hosts (`opencode.ai.example.com`, `fakeopencode.ai`) must never
/// receive the conversation id.
bool isOpenCodeBaseUrl(String baseUrl) {
  final raw = baseUrl.trim();
  if (raw.isEmpty) return false;
  var uri = Uri.tryParse(raw);
  // The provider form accepts free text; tolerate a missing scheme so
  // `opencode.ai/zen/v1` is treated the same as its https form.
  if (uri == null || uri.host.isEmpty) {
    uri = Uri.tryParse('https://$raw');
  }
  return uri != null && uri.host.toLowerCase() == 'opencode.ai';
}

/// Stable session id for one conversation.
///
/// Priority: explicit conversation id -> caller session id -> request id ->
/// deterministic uuid derived from the provider identity. The last fallback is
/// intentionally not random (the project contract is "never random").
String resolveOpenCodeSessionId({
  required String providerId,
  required String baseUrl,
  String? conversationId,
  String? sessionId,
  String? requestId,
}) {
  for (final candidate in <String?>[conversationId, sessionId, requestId]) {
    final value = (candidate ?? '').trim();
    if (value.isNotEmpty) return value;
  }
  return oauthStableUuid('opencode:$providerId:$baseUrl');
}

Map<String, String> openCodeSessionHeaders({
  required String providerId,
  required String baseUrl,
  String? conversationId,
  String? sessionId,
  String? requestId,
}) {
  return <String, String>{
    'x-opencode-session': resolveOpenCodeSessionId(
      providerId: providerId,
      baseUrl: baseUrl,
      conversationId: conversationId,
      sessionId: sessionId,
      requestId: requestId,
    ),
    'x-opencode-client': kOpenCodeClientId,
  };
}

/// OpenCode's configuration format uses `opencode/<id>` and
/// `opencode-go/<id>`, while the inference API expects the bare model id.
String normalizeOpenCodeModelId(String modelId) {
  var id = modelId.trim();
  if (id.isEmpty) return id;
  for (final prefix in const <String>['opencode-go/', 'opencode/']) {
    if (id.toLowerCase().startsWith(prefix)) {
      id = id.substring(prefix.length);
      break;
    }
  }
  return id;
}
