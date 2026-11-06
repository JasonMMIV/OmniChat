// Phase 0 regression (multimodal plan §7 F2): the extractor used to
// `utf8.decode(allowMalformed: true)` any MIME it did not special-case, so an
// .mp3 attachment became mojibake in the prompt and was replayed every turn.

import 'dart:io';

import 'package:OmniChat/core/services/chat/document_text_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('doc-extractor-audio');
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  test('audio returns empty instead of decoded bytes', () async {
    final file = File('${temp.path}/voice.mp3');
    await file.writeAsBytes(const [0xFF, 0xFB, 0x90, 0x00, 0x48, 0x00]);
    expect(
      await DocumentTextExtractor.extract(
        path: file.path,
        mime: 'audio/mpeg',
      ),
      '',
    );
  });

  test('video returns empty instead of decoded bytes', () async {
    final file = File('${temp.path}/clip.mp4');
    await file.writeAsBytes(const [0x00, 0x00, 0x00, 0x18, 0x66, 0x74]);
    expect(
      await DocumentTextExtractor.extract(path: file.path, mime: 'video/mp4'),
      '',
    );
  });
}
