// Provider model-list effort metadata: Codex uses object presets, Claude uses
// a capability map, and only the standard effort vocabulary is persisted.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:OmniChat/core/models/provider_oauth.dart';
import 'package:OmniChat/core/services/auth/claude_oauth_adapter.dart';
import 'package:OmniChat/core/services/auth/provider_oauth_adapter.dart';

http.Response _json(Map<String, dynamic> data) => http.Response(
  jsonEncode(data),
  200,
  headers: const <String, String>{'content-type': 'application/json'},
);

ProviderOAuthCredentials _credentials() => ProviderOAuthCredentials(
  accessToken: 'a',
  refreshToken: 'r',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
  sessionId: 's',
);

void main() {
  test(
    'Codex model sync keeps standard efforts and drops Ultra/Persistent',
    () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/backend-api/codex/models');
        return _json(<String, dynamic>{
          'models': <Map<String, dynamic>>[
            <String, dynamic>{
              'slug': 'gpt-5.6-luna',
              'display_name': 'Luna',
              'supported_reasoning_levels': <Map<String, dynamic>>[
                <String, dynamic>{'effort': 'low', 'description': 'Fast'},
                <String, dynamic>{'effort': 'xhigh'},
                <String, dynamic>{'effort': 'max'},
                <String, dynamic>{'effort': 'ultra'},
                <String, dynamic>{'effort': 'persistent'},
              ],
            },
          ],
        });
      });

      final entries = await ChatGptOAuthAdapter().fetchModels(
        credentials: _credentials(),
        client: client,
      );
      expect(entries.single.efforts, <String>{'low', 'xhigh', 'max'});
    },
  );

  test('Claude model sync reads capabilities.effort', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/v1/models');
      return _json(<String, dynamic>{
        'data': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'claude-opus-4-8',
            'display_name': 'Opus 4.8',
            'capabilities': <String, dynamic>{
              'effort': <String, dynamic>{
                'supported': true,
                'low': <String, dynamic>{'supported': true},
                'medium': <String, dynamic>{'supported': true},
                'high': <String, dynamic>{'supported': true},
                'xhigh': <String, dynamic>{'supported': false},
                'max': <String, dynamic>{'supported': true},
              },
              'thinking': <String, dynamic>{
                'types': <String, dynamic>{
                  'disabled': <String, dynamic>{'supported': false},
                },
              },
            },
          },
        ],
        'has_more': false,
      });
    });

    final entries = await ClaudeOAuthAdapter().fetchModels(
      credentials: _credentials(),
      client: client,
    );
    final entry = entries.single;
    expect(entry.efforts, <String>{'low', 'medium', 'high', 'max'});
    expect(entry.thinkingAlwaysOn, isTrue);
  });
}
