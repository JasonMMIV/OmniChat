import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:OmniChat/core/services/stt/network_stt.dart';
import 'package:OmniChat/core/services/stt/stt_request.dart';

QwenAudioSttOptions _qwen({
  String workspaceId = 'token-plan',
  String region = 'cn-beijing',
  String endpoint = '',
  String language = '',
}) => QwenAudioSttOptions(
  enabled: true,
  name: 'Qwen',
  apiKey: 'dq',
  workspaceId: workspaceId,
  region: region,
  endpoint: endpoint,
  model: kDefaultQwenSttModel,
  language: language,
);

http.Request _request(QwenAudioSttOptions service) {
  final request = buildSttTranscriptionRequest(
    service: service,
    wav: Uint8List.fromList([0, 0, 1, 0]),
    sampleRate: 16000,
  );
  expect(request, isA<http.Request>());
  return request as http.Request;
}

void main() {
  test('Qwen builds a JSON body with a base64 WAV data URL', () {
    final request = _request(_qwen());
    expect(
      request.url.toString(),
      'https://token-plan.cn-beijing.maas.aliyuncs.com'
      '/api/v1/services/aigc/multimodal-generation/generation',
    );
    expect(request.headers['Authorization'], 'Bearer dq');
    expect(request.headers['X-DashScope-WorkSpace'], 'token-plan');
    expect(request.headers['X-DashScope-SSE'], 'disable');

    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expect(body['model'], kDefaultQwenSttModel);
    final messages = (body['input'] as Map)['messages'] as List;
    final content = (messages.first as Map)['content'] as List;
    final data = ((content.first as Map)['input_audio'] as Map)['data'] as String;
    expect(data.startsWith('data:audio/wav;base64,'), isTrue);
    expect(data.substring('data:audio/wav;base64,'.length), base64Encode([0, 0, 1, 0]));
    final params = body['parameters'] as Map<String, dynamic>;
    expect(params['format'], 'wav');
    expect(params['sample_rate'], 16000);
    expect(params.containsKey('language_hints'), isFalse);
  });

  test('no workspace omits the header and uses dashscope', () {
    final request = _request(_qwen(workspaceId: ''));
    expect(request.headers.containsKey('X-DashScope-WorkSpace'), isFalse);
    expect(request.url.host, 'dashscope.aliyuncs.com');
  });

  test('ap-southeast-1 without workspace uses dashscope-intl', () {
    final request = _request(_qwen(workspaceId: '', region: 'ap-southeast-1'));
    expect(request.url.host, 'dashscope-intl.aliyuncs.com');
  });

  test('endpoint override wins over workspace host', () {
    final request = _request(
      _qwen(endpoint: 'https://proxy.example.com/qwen'),
    );
    expect(request.url.toString(), 'https://proxy.example.com/qwen');
    // 有 workspace 時仍會帶 header（Token Plan 需要）。
    expect(request.headers['X-DashScope-WorkSpace'], 'token-plan');
  });

  test('language hints are forwarded when set', () {
    final request = _request(_qwen(language: 'zh'));
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expect((body['parameters'] as Map)['language_hints'], ['zh']);
  });

  test('URL in workspace ID is rejected', () {
    expect(
      () => _request(_qwen(workspaceId: 'https://evil.example.com')),
      throwsFormatException,
    );
  });

  test('workspace ID validation matches the documented shape', () {
    expect(isValidSttWorkspaceId('token-plan'), isTrue);
    expect(isValidSttWorkspaceId('a'), isTrue);
    expect(isValidSttWorkspaceId('a-'), isFalse);
    expect(isValidSttWorkspaceId('-a'), isFalse);
    expect(isValidSttWorkspaceId('https://x.dev'), isFalse);
    expect(isValidSttWorkspaceId('a' * 64), isFalse);
  });
}
