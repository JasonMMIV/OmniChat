import 'package:OmniChat/core/services/api/chat_api_service.dart';
import 'package:OmniChat/core/services/api/gemini_signature_scope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('geminiProviderScope', () {
    test('same provider and origin share a scope', () {
      final a = geminiProviderScope(
        providerId: 'gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      );
      final b = geminiProviderScope(
        providerId: 'gemini',
        baseUrl: 'https://GENERATIVELANGUAGE.googleapis.com/v1/',
      );
      expect(a, b);
    });

    test('different providers or origins do not share a scope', () {
      final official = geminiProviderScope(
        providerId: 'gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      );
      final vertexLike = geminiProviderScope(
        providerId: 'gemini',
        baseUrl: 'https://us-central1-aiplatform.googleapis.com/v1',
      );
      final otherProvider = geminiProviderScope(
        providerId: 'gemini-work',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      );

      expect(official, isNot(vertexLike));
      expect(official, isNot(otherProvider));
    });

    test('different models do not share a scope', () {
      final flash = geminiProviderScope(
        providerId: 'gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        modelId: 'gemini-3.5-flash',
      );
      final argon = geminiProviderScope(
        providerId: 'gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        modelId: 'gemini-4-argon',
      );
      final namespacedFlash = geminiProviderScope(
        providerId: 'gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        modelId: 'models/gemini-3.5-flash',
      );

      expect(flash, isNot(argon));
      expect(namespacedFlash, flash);
    });

    test('Vertex scope includes project and location', () {
      final us = geminiProviderScope(
        providerId: 'gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        vertexAI: true,
        projectId: 'project-a',
        location: 'us-central1',
      );
      final eu = geminiProviderScope(
        providerId: 'gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        vertexAI: true,
        projectId: 'project-a',
        location: 'europe-west1',
      );
      final otherProject = geminiProviderScope(
        providerId: 'gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        vertexAI: true,
        projectId: 'project-b',
        location: 'us-central1',
      );

      expect(us, isNot(eu));
      expect(us, isNot(otherProject));
    });
  });

  group('signature comment provenance', () {
    test('built comments carry the scope and extract it back', () {
      const scope = 'gemini|https://example.com:443';
      final comment = ChatApiService.debugBuildGeminiThoughtSigComment(
        textKey: 'thoughtSignature',
        textValue: 'sig',
        providerScope: scope,
      );
      expect(comment, contains('gemini_thought_signatures'));
      expect(ChatApiService.debugGeminiThoughtSigScope(comment), scope);
      expect(ChatApiService.debugGeminiThoughtSigScope('plain'), isNull);
    });
  });

  group('signature payload normalization', () {
    test('strips the comment and returns the bare payload', () {
      final captured = stripGeminiThoughtSignatureComment(
        'hello\n<!-- gemini_thought_signatures:{"text":{"k":"thoughtSignature","v":"sig"}} -->',
      );
      expect(captured.cleaned, 'hello');
      expect(captured.payload, '{"text":{"k":"thoughtSignature","v":"sig"}}');
    });

    test('normalizes legacy comments and keeps bare payloads intact', () {
      const payload = '{"text":{"k":"thoughtSignature","v":"sig"}}';
      expect(
        normalizeGeminiThoughtSignaturePayload(
          'x\n<!-- gemini_thought_signatures:$payload -->',
        ),
        payload,
      );
      expect(normalizeGeminiThoughtSignaturePayload(payload), payload);
      expect(
        normalizeGeminiThoughtSignaturePayload('legacy-signature'),
        'legacy-signature',
      );
    });

    test('append rebuilds the legacy carrier for the wire', () {
      final content = appendGeminiThoughtSignatureComment(
        'answer',
        '{"text":{"k":"thoughtSignature","v":"sig"}}',
      );
      expect(content, startsWith('answer\n<!-- gemini_thought_signatures:'));
      expect(ChatApiService.debugGeminiThoughtSigScope(content), isNull);
    });
  });

  group('geminiSignatureMatchesProvider', () {
    test('scoped signatures require an exact scope match', () {
      const target = 'gemini|https://generativelanguage.googleapis.com:443';
      expect(
        geminiSignatureMatchesProvider(
          signatureScope: target,
          messageProviderId: 'gemini',
          targetScope: target,
          targetProviderId: 'gemini',
        ),
        isTrue,
      );
      expect(
        geminiSignatureMatchesProvider(
          signatureScope:
              'gemini|https://us-central1-aiplatform.googleapis.com:443',
          messageProviderId: 'gemini',
          targetScope: target,
          targetProviderId: 'gemini',
        ),
        isFalse,
      );
    });

    test('legacy unscoped signatures fall back to the message provider id', () {
      expect(
        geminiSignatureMatchesProvider(
          signatureScope: null,
          messageProviderId: 'gemini',
          targetScope: 'gemini|https://example.com:443',
          targetProviderId: 'gemini',
        ),
        isTrue,
      );
      expect(
        geminiSignatureMatchesProvider(
          signatureScope: null,
          messageProviderId: 'gemini-work',
          targetScope: 'gemini|https://example.com:443',
          targetProviderId: 'gemini',
        ),
        isFalse,
      );
      // Rows written before provider attribution existed stay replayable.
      expect(
        geminiSignatureMatchesProvider(
          signatureScope: null,
          messageProviderId: null,
          targetScope: 'gemini|https://example.com:443',
          targetProviderId: 'gemini',
        ),
        isTrue,
      );
    });
  });
}
