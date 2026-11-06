// Attachment modality gate matrix (multimodal plan C1 / §4).
//
// Only audio can be definitively unsendable. PDF always has the text
// extraction fallback, images follow the existing path, and video keeps the
// userImagePaths path (§7 F5) — none of them may be reported as stripped.

import 'package:OmniChat/core/models/chat_input_data.dart';
import 'package:OmniChat/core/providers/model_provider.dart';
import 'package:OmniChat/features/home/services/attachment_modality_gate.dart';
import 'package:flutter_test/flutter_test.dart';

DocumentAttachment _doc(String name, String mime) =>
    DocumentAttachment(path: '/tmp/$name', fileName: name, mime: mime);

void main() {
  final audio = _doc('voice.mp3', 'audio/mpeg');
  final legacyAudio = _doc('voice.mp3', 'text/plain');
  final pdf = _doc('brief.pdf', 'application/pdf');
  final video = _doc('clip.mp4', 'video/mp4');

  test('model without audio input strips audio (including legacy MIME)', () {
    final info = ModelInfo(
      id: 'text-only',
      displayName: 'text-only',
      input: const [Modality.text, Modality.pdf],
    );
    final stripped = AttachmentModalityGate.unsupported(
      [audio, legacyAudio, pdf, video],
      info,
    );
    expect(stripped, containsAll(<DocumentAttachment>[audio, legacyAudio]));
    expect(stripped, isNot(contains(pdf)));
    expect(stripped, isNot(contains(video)));
  });

  test('policy gate strips audio even when the model advertises it', () {
    final info = ModelInfo(
      id: 'omni',
      displayName: 'omni',
      input: const [Modality.text, Modality.audio],
    );
    expect(
      AttachmentModalityGate.unsupported(
        [audio],
        info,
        nativeAudioEnabled: false,
      ),
      <DocumentAttachment>[audio],
    );
    expect(
      AttachmentModalityGate.unsupported([audio], info),
      isEmpty,
    );
  });

  test('PDF/video/images are never reported as unsupported', () {
    final info = ModelInfo(id: 'text-only', displayName: 'text-only');
    final stripped = AttachmentModalityGate.unsupported(
      [pdf, video, _doc('photo.png', 'image/png')],
      info,
    );
    expect(stripped, isEmpty);
  });
}
