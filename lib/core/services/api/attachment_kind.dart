// Attachment classification shared by the message builder, the attachment
// modality gate and the native input serializer.
//
// Pure Dart (no Flutter imports) so it can be unit-tested without a widget
// binding. Classification is deliberately extension-aware: historical
// messages may carry `text/plain` for a `.mp3` because the picker used to
// guess text/plain for every unknown extension (multimodal plan §7 F2).

/// Coarse attachment category used by the multimodal input pipeline.
enum AttachmentKind { image, audio, video, pdf, document, unknown }

const Set<String> kImageExtensions = <String>{
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'heic',
  'heif',
  'bmp',
};

const Set<String> kAudioExtensions = <String>{
  'mp3',
  'm4a',
  'wav',
  'aac',
  'ogg',
  'oga',
  'opus',
  'flac',
  'aiff',
  'aif',
  'amr',
  'pcm',
};

const Set<String> kVideoExtensions = <String>{
  'mp4',
  'mpeg',
  'mpg',
  'mov',
  'avi',
  'mkv',
  'flv',
  'wmv',
  'webm',
  '3gp',
  '3gpp',
};

/// Lowercased extension without the dot, or `''` when there is none.
String attachmentExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// Classify an attachment by MIME first and extension second.
///
/// MIME wins when it is specific (`audio/*`, `video/*`, `image/*`,
/// `application/pdf`); otherwise the file name decides. `text/plain` never
/// wins over an audio/video extension, which is exactly the shape historical
/// bug reports produced.
AttachmentKind attachmentKindFor(String mime, [String name = '']) {
  final m = mime.trim().toLowerCase();
  final ext = attachmentExtension(name);

  if (m == 'application/pdf' || ext == 'pdf') return AttachmentKind.pdf;
  if (m.startsWith('audio/') || kAudioExtensions.contains(ext)) {
    return AttachmentKind.audio;
  }
  if (m.startsWith('video/') || kVideoExtensions.contains(ext)) {
    return AttachmentKind.video;
  }
  if (m.startsWith('image/') || kImageExtensions.contains(ext)) {
    return AttachmentKind.image;
  }
  if (m.isEmpty) return AttachmentKind.unknown;
  return AttachmentKind.document;
}

/// Whether the document extractor has a textual representation for this
/// attachment. Audio/video must be skipped rather than UTF-8 decoded into
/// mojibake and replayed every turn (multimodal plan §7 F2).
bool attachmentHasExtractableText(String mime, String name) {
  final kind = attachmentKindFor(mime, name);
  return kind != AttachmentKind.audio && kind != AttachmentKind.video;
}

/// Whether the assembly should run text extraction for this attachment.
///
/// A native PDF already travels as a document block, so extracting it too
/// would duplicate the payload (plan B5). Audio/video never have text.
bool shouldExtractAttachmentText({
  required String path,
  required String mime,
  required String name,
  required Set<String> nativePaths,
}) =>
    !nativePaths.contains(path) && attachmentHasExtractableText(mime, name);

/// Map an attachment MIME (or extension when the MIME is generic) to the
/// canonical MIME used on the wire.
String attachmentMimeFor(String mime, String name) {
  final raw = mime.trim().toLowerCase();
  final generic =
      raw.isEmpty || raw == 'application/octet-stream' || raw == 'text/plain';
  if (!generic) return raw;
  switch (attachmentExtension(name)) {
    case 'mp3':
      return 'audio/mpeg';
    case 'm4a':
      return 'audio/mp4';
    case 'wav':
      return 'audio/wav';
    case 'aac':
      return 'audio/aac';
    case 'ogg':
    case 'oga':
      return 'audio/ogg';
    case 'opus':
      return 'audio/opus';
    case 'flac':
      return 'audio/flac';
    case 'aiff':
    case 'aif':
      return 'audio/aiff';
    case 'amr':
      return 'audio/amr';
    case 'pcm':
      return 'audio/pcm';
    case 'pdf':
      return 'application/pdf';
    default:
      return raw.isEmpty ? 'application/octet-stream' : raw;
  }
}
