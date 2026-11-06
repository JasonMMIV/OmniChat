// Phase 0 regression pins (multimodal plan §7 F2):
// audio must never be fed to the document text extractor and must never be
// labelled text/plain by the attachment picker.

import 'package:OmniChat/core/services/api/attachment_kind.dart';
import 'package:OmniChat/features/home/services/file_upload_service.dart';
import 'package:OmniChat/features/home/services/message_builder_service.dart';
import 'package:OmniChat/features/home/widgets/chat_input_bar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('audio/video are not text-extractable; documents are', () {
    expect(attachmentHasExtractableText('audio/mpeg', 'a.mp3'), isFalse);
    expect(attachmentHasExtractableText('text/plain', 'a.mp3'), isFalse);
    expect(attachmentHasExtractableText('audio/wav', 'a.wav'), isFalse);
    expect(attachmentHasExtractableText('audio/mp4', 'a.m4a'), isFalse);
    expect(attachmentHasExtractableText('video/mp4', 'a.mp4'), isFalse);
    expect(attachmentHasExtractableText('application/pdf', 'a.pdf'), isTrue);
    expect(
      attachmentHasExtractableText(
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'a.docx',
      ),
      isTrue,
    );
    expect(attachmentHasExtractableText('text/plain', 'a.txt'), isTrue);
  });

  test('native PDF skips extraction; other documents keep it', () {
    final native = <String>{'/tmp/brief.pdf'};
    expect(
      shouldExtractAttachmentText(
        path: '/tmp/brief.pdf',
        mime: 'application/pdf',
        name: 'brief.pdf',
        nativePaths: native,
      ),
      isFalse,
    );
    expect(
      shouldExtractAttachmentText(
        path: '/tmp/other.pdf',
        mime: 'application/pdf',
        name: 'other.pdf',
        nativePaths: native,
      ),
      isTrue,
    );
    expect(
      shouldExtractAttachmentText(
        path: '/tmp/voice.mp3',
        mime: 'audio/mpeg',
        name: 'voice.mp3',
        nativePaths: const <String>{},
      ),
      isFalse,
    );
  });

  test('empty user content never reaches the wire as an empty turn', () {
    expect(
      resolveUserMessageContent(
        content: 'hello',
        hasNativeParts: false,
        emptyPlaceholder: '(omitted)',
      ),
      'hello',
    );
    expect(
      resolveUserMessageContent(
        content: '',
        hasNativeParts: true,
        emptyPlaceholder: '(omitted)',
      ),
      '',
    );
    expect(
      resolveUserMessageContent(
        content: '',
        hasNativeParts: false,
        emptyPlaceholder: '(omitted)',
      ),
      '(omitted)',
    );
  });

  test('audio MIME inference never falls back to text/plain', () {
    final upload = FileUploadService(
      mediaController: ChatInputBarController(),
      onScrollToBottom: () {},
    );
    expect(upload.inferMimeByExtension('voice.mp3'), 'audio/mpeg');
    expect(upload.inferMimeByExtension('voice.wav'), 'audio/wav');
    expect(upload.inferMimeByExtension('voice.m4a'), 'audio/mp4');
    expect(upload.inferMimeByExtension('voice.flac'), 'audio/flac');
    expect(
      upload.inferMimeByExtension('blob.bin'),
      'application/octet-stream',
    );
  });
}
