import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:OmniChat/core/services/api/provider_session_client.dart';

void main() {
  test('injects headers into every request', () async {
    Map<String, String>? seen;
    final client = ProviderSessionClient(
      inner: MockClient((request) async {
        seen = request.headers;
        return http.Response('{}', 200);
      }),
      headers: const {
        'x-opencode-session': 'conv-1',
        'x-opencode-client': 'omnichat',
      },
    );

    await client.send(
      http.Request(
        'POST',
        Uri.parse('https://opencode.ai/zen/v1/chat/completions'),
      ),
    );

    expect(seen?['x-opencode-session'], 'conv-1');
    expect(seen?['x-opencode-client'], 'omnichat');
    client.close();
  });

  test('does not overwrite a caller-supplied session header', () async {
    Map<String, String>? seen;
    final client = ProviderSessionClient(
      inner: MockClient((request) async {
        seen = request.headers;
        return http.Response('{}', 200);
      }),
      headers: const {'x-opencode-session': 'automatic'},
    );

    final request = http.Request(
      'POST',
      Uri.parse('https://opencode.ai/zen/v1/chat/completions'),
    )..headers['X-OpenCode-Session'] = 'manual';

    await client.send(request);

    expect(seen?['x-opencode-session'], 'manual');
    client.close();
  });
}
