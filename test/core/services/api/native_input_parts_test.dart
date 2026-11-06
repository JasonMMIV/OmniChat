// Native audio/PDF input serializer tests (multimodal plan §2.2/§4).
//
// Covers the four wire protocols, format whitelists, per-host exceptions and
// the encoded-size budget. Path remapping is injected, so these run as plain
// Dart tests over temp files (no widget binding needed).

import 'dart:convert';
import 'dart:io';

import 'package:OmniChat/core/services/api/attachment_kind.dart';
import 'package:OmniChat/core/services/api/native_input_parts.dart';
import 'package:flutter_test/flutter_test.dart';

NativeAttachment _attachment(String path, String name, String mime) =>
    NativeAttachment(
      path: path,
      name: name,
      mime: mime,
      kind: attachmentKindFor(mime, name),
    );

void main() {
  late Directory temp;
  late String pdfPath;
  late String wavPath;
  late String m4aPath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('native-input-parts');
    pdfPath = '${temp.path}/brief.pdf';
    wavPath = '${temp.path}/voice.wav';
    m4aPath = '${temp.path}/voice.m4a';
    await File(pdfPath).writeAsBytes(utf8.encode('%PDF-1.7 fake'));
    // 16 bytes of "audio"; content does not matter for the wire shape.
    await File(wavPath).writeAsBytes(List<int>.filled(16, 1));
    await File(m4aPath).writeAsBytes(List<int>.filled(16, 2));
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  test('classifies legacy text/plain audio by extension', () {
    expect(
      attachmentKindFor('text/plain', 'recording.mp3'),
      AttachmentKind.audio,
    );
    expect(attachmentKindFor('text/plain', 'brief.pdf'), AttachmentKind.pdf);
    expect(
      attachmentKindFor('application/octet-stream', 'clip.m4a'),
      AttachmentKind.audio,
    );
    expect(attachmentMimeFor('text/plain', 'recording.mp3'), 'audio/mpeg');
  });

  group('chat completions', () {
    test('PDF uses the nested file block with a data URI', () async {
      final result = await NativeInputParts.build(
        protocol: NativeInputProtocol.openAiChat,
        attachments: [_attachment(pdfPath, 'brief.pdf', 'application/pdf')],
        baseUrl: 'https://api.openai.com/v1',
      );
      expect(result.errors, isEmpty);
      final part = result.parts.single;
      expect(part['type'], 'file');
      final file = part['file'] as Map;
      expect(file['filename'], 'brief.pdf');
      expect(
        file['file_data'],
        'data:application/pdf;base64,${base64Encode(utf8.encode('%PDF-1.7 fake'))}',
      );
    });

    test('audio uses raw base64 and the format field', () async {
      final result = await NativeInputParts.build(
        protocol: NativeInputProtocol.openAiChat,
        attachments: [_attachment(wavPath, 'voice.wav', 'audio/wav')],
        baseUrl: 'https://api.openai.com/v1',
      );
      expect(result.errors, isEmpty);
      final audio = result.parts.single['input_audio'] as Map;
      expect(audio['format'], 'wav');
      expect(
        audio['data'],
        base64Encode(List<int>.filled(16, 1)),
      );
    });

    test('api.openai.com rejects non wav/mp3 audio', () async {
      final result = await NativeInputParts.build(
        protocol: NativeInputProtocol.openAiChat,
        attachments: [_attachment(m4aPath, 'voice.m4a', 'audio/mp4')],
        baseUrl: 'https://api.openai.com/v1',
      );
      expect(result.parts, isEmpty);
      expect(result.errors.single.code, NativeInputError.unsupportedFormat);
    });

    test('gemini rejects formats outside its documented audio set', () async {
      final result = await NativeInputParts.build(
        protocol: NativeInputProtocol.gemini,
        attachments: [_attachment(m4aPath, 'voice.m4a', 'audio/mp4')],
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      );
      expect(result.parts, isEmpty);
      expect(result.errors.single.code, NativeInputError.unsupportedFormat);
    });

    test('other hosts accept m4a', () async {
      final result = await NativeInputParts.build(
        protocol: NativeInputProtocol.openAiChat,
        attachments: [_attachment(m4aPath, 'voice.m4a', 'audio/mp4')],
        baseUrl: 'https://aggregator.example/v1',
      );
      expect(result.errors, isEmpty);
      expect((result.parts.single['input_audio'] as Map)['format'], 'm4a');
    });

    test('DashScope audio carries a data URI prefix', () async {
      final result = await NativeInputParts.build(
        protocol: NativeInputProtocol.openAiChat,
        attachments: [_attachment(wavPath, 'voice.wav', 'audio/wav')],
        baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      );
      final data = (result.parts.single['input_audio'] as Map)['data'] as String;
      expect(data, startsWith('data:audio/wav;base64,'));
    });
  });

  test('responses PDF uses flat input_file fields', () async {
    final result = await NativeInputParts.build(
      protocol: NativeInputProtocol.responses,
      attachments: [_attachment(pdfPath, 'brief.pdf', 'application/pdf')],
      baseUrl: 'https://api.openai.com/v1',
    );
    expect(result.errors, isEmpty);
    final part = result.parts.single;
    expect(part['type'], 'input_file');
    expect(part['filename'], 'brief.pdf');
    expect(part['file_data'], startsWith('data:application/pdf;base64,'));
    expect(part.containsKey('file'), isFalse);
  });

  test('responses and claude reject audio with a structured error', () async {
    for (final protocol in [
      NativeInputProtocol.responses,
      NativeInputProtocol.claude,
    ]) {
      final result = await NativeInputParts.build(
        protocol: protocol,
        attachments: [_attachment(wavPath, 'voice.wav', 'audio/wav')],
        baseUrl: 'https://api.openai.com/v1',
      );
      expect(result.parts, isEmpty);
      expect(
        result.errors.single.code,
        NativeInputError.unsupportedProvider,
      );
    }
  });

  test('claude PDF becomes a document block', () async {
    final result = await NativeInputParts.build(
      protocol: NativeInputProtocol.claude,
      attachments: [_attachment(pdfPath, 'brief.pdf', 'application/pdf')],
      baseUrl: 'https://api.anthropic.com/v1',
    );
    expect(result.errors, isEmpty);
    final part = result.parts.single;
    expect(part['type'], 'document');
    expect(part['title'], 'brief.pdf');
    final source = part['source'] as Map;
    expect(source['type'], 'base64');
    expect(source['media_type'], 'application/pdf');
    expect(source['data'], base64Encode(utf8.encode('%PDF-1.7 fake')));
  });

  test('gemini normalizes audio MIME and uses inline_data', () async {
    final result = await NativeInputParts.build(
      protocol: NativeInputProtocol.gemini,
      attachments: [_attachment(wavPath, 'voice.wav', 'audio/x-wav')],
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    );
    expect(result.errors, isEmpty);
    final inline = result.parts.single['inline_data'] as Map;
    expect(inline['mime_type'], 'audio/wav');
    expect(inline['data'], base64Encode(List<int>.filled(16, 1)));
  });

  test('missing file returns attachment_unavailable', () async {
    final result = await NativeInputParts.build(
      protocol: NativeInputProtocol.openAiChat,
      attachments: [
        _attachment('${temp.path}/nope.pdf', 'nope.pdf', 'application/pdf'),
      ],
      baseUrl: 'https://api.openai.com/v1',
    );
    expect(result.parts, isEmpty);
    expect(result.errors.single.code, NativeInputError.unavailable);
    expect(result.errors.single.toJson()['type'], 'attachment_error');
  });

  test('raw size guard rejects oversized files before reading', () async {
    final result = await NativeInputParts.build(
      protocol: NativeInputProtocol.gemini,
      attachments: [_attachment(pdfPath, 'brief.pdf', 'application/pdf')],
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      maxFileBytes: 4,
    );
    expect(result.parts, isEmpty);
    expect(result.errors.single.code, NativeInputError.tooLarge);
  });

  test('encoded budget is enforced across attachments', () async {
    final second = '${temp.path}/second.pdf';
    await File(second).writeAsBytes(utf8.encode('%PDF-1.7 fake'));
    final oneEncoded = base64Encode(utf8.encode('%PDF-1.7 fake')).length;
    final result = await NativeInputParts.build(
      protocol: NativeInputProtocol.gemini,
      attachments: [
        _attachment(pdfPath, 'brief.pdf', 'application/pdf'),
        _attachment(second, 'second.pdf', 'application/pdf'),
      ],
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      maxEncodedBytes: oneEncoded + 1,
    );
    expect(result.parts, hasLength(1));
    expect(result.errors.single.code, NativeInputError.tooLarge);
    expect(result.encodedBytes, oneEncoded);
  });
}
