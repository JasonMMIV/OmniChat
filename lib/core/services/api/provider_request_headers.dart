// Ported from Chevey339/kelivo@05eef503b6e7cda14de897373b79bab7bebe35b9
// (`lib/core/services/api/provider_request_headers.dart`, AGPL-3.0), modified
// for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.

import '../../models/provider_oauth.dart';
import '../../providers/settings_provider.dart';
import 'opencode.dart';

/// Session attribution headers shared by the chat wrapper and the non-chat
/// OAuth endpoints. Never random per request — a stable conversation id is what
/// keeps provider-side attribution and prompt-cache prefixes intact (C15).
Map<String, String> providerSessionHeaders(
  ProviderConfig config, {
  String? sessionId,
  String? conversationId,
  String? requestId,
}) {
  final provider = config.oauthProvider;
  final session = (sessionId ?? '').trim();
  if (provider == null) {
    if (!isOpenCodeBaseUrl(config.baseUrl)) return const <String, String>{};
    return openCodeSessionHeaders(
      providerId: config.id,
      baseUrl: config.baseUrl,
      conversationId: conversationId,
      sessionId: sessionId,
      requestId: requestId,
    );
  }
  switch (provider) {
    case OAuthProvider.chatgpt:
      return <String, String>{
        if (session.isNotEmpty) 'session_id': session,
        if ((conversationId ?? '').isNotEmpty)
          'conversation_id': conversationId!,
        if ((requestId ?? '').isNotEmpty) 'x-client-request-id': requestId!,
      };
    case OAuthProvider.claude:
      return <String, String>{
        if (session.isNotEmpty) 'X-Claude-Code-Session-Id': session,
      };
    case OAuthProvider.grok:
    case OAuthProvider.kimi:
      return const <String, String>{};
  }
}
