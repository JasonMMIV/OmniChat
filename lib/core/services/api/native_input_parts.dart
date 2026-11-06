// Native multimodal input parts (audio / PDF) for the four chat transports.
//
// Pure Dart (no Flutter imports) so it can be unit-tested with plain
// `dart:io` temp files. Path remapping is injected by the caller
// (`SandboxPathResolver.fix`) to keep this library free of Flutter deps.
//
// Design notes (docs/kelivo_multimodal_import_plan.md §2.2):
//   - Unsupported combinations return a structured [NativeInputError] instead
//     of throwing. A thrown error would be classified as terminal by the L1
//     stream-retry layer (§3.10) and kill the whole turn (§2.5).
//   - Budgets are encoded-length based: Gemini rejects a request whose total
//     inline payload exceeds 20 MB, and base64 inflates by ~33%. Single file
//     raw ≤ 10 MB, per-message encoded ≤ 18 MB (§7 F8).
//   - Formats follow the upstream-verified contract, corrected against the
//     official OpenAI schema: Chat Completions nests `file` / `input_audio`;
//     the Responses API `input_file` fields are flat.

import 'dart:convert';
import 'dart:io';

import 'attachment_kind.dart';

/// Wire protocol that will carry the parts.
enum NativeInputProtocol { openAiChat, responses, claude, gemini }

/// Neutral attachment descriptor produced by the message builder.
class NativeAttachment {
  const NativeAttachment({
    required this.path,
    required this.name,
    required this.mime,
    required this.kind,
  });

  final String path;
  final String name;

  /// Attachment-declared MIME (already normalized where possible).
  final String mime;
  final AttachmentKind kind;

  bool get isAudio => kind == AttachmentKind.audio;
  bool get isPdf => kind == AttachmentKind.pdf;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'path': path,
    'name': name,
    'mime': mime,
    'type': isAudio ? 'audio' : 'pdf',
  };

}

/// Structured, non-fatal attachment error. `toJson()` is the shape logged to
/// the wire log and surfaced by the UI; it is deliberately NOT `tool_error`
/// (that contract means "a tool failed", §5.6/§7 F13).
class NativeInputError {
  const NativeInputError(this.code, this.fileName, this.detail);

  static const String unavailable = 'attachment_unavailable';
  static const String tooLarge = 'attachment_too_large';
  static const String unsupportedFormat = 'attachment_unsupported_format';
  static const String unsupportedProvider = 'attachment_unsupported_provider';
  static const String unreadable = 'attachment_unreadable';

  final String code;
  final String fileName;
  final String detail;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': 'attachment_error',
    'code': code,
    'file': fileName,
    'detail': detail,
  };

  @override
  String toString() => '$code($fileName): $detail';
}

class NativeInputBuildResult {
  const NativeInputBuildResult({
    this.parts = const <Map<String, dynamic>>[],
    this.errors = const <NativeInputError>[],
    this.encodedBytes = 0,
  });

  final List<Map<String, dynamic>> parts;
  final List<NativeInputError> errors;
  final int encodedBytes;

  bool get hasErrors => errors.isNotEmpty;
}

/// Builds wire parts for one message's native audio/PDF attachments.
class NativeInputParts {
  NativeInputParts._();

  /// Raw ceiling per attachment (plan §7 F8). Chosen so a single base64 blob
  /// stays well under Gemini's 20 MB total inline budget.
  static const int defaultMaxFileBytes = 10 * 1024 * 1024;

  /// Encoded (base64) ceiling for one message's attachments.
  static const int defaultMaxEncodedBytesPerMessage = 18 * 1024 * 1024;

  /// `input_audio.format` values accepted by the upstream contract.
  static const Set<String> supportedAudioFormats = <String>{
    'wav',
    'mp3',
    'm4a',
    'aac',
    'flac',
    'ogg',
    'opus',
    'aiff',
    'pcm16',
  };

  /// OpenAI's own endpoint only accepts wav/mp3 (§1.2). Other hosts may accept
  /// the wider list.
  static const Set<String> openAiOfficialAudioFormats = <String>{'wav', 'mp3'};

  /// Gemini's documented audio-understanding formats. `m4a` / `opus` /
  /// `pcm16` are deliberately excluded — Gemini rejects them even though the
  /// OpenAI-compatible hosts may accept them.
  static const Set<String> geminiAudioFormats = <String>{
    'wav',
    'mp3',
    'aiff',
    'aac',
    'ogg',
    'flac',
  };

  static const Map<String, String> _audioFormatByMime = <String, String>{
    'audio/wav': 'wav',
    'audio/x-wav': 'wav',
    'audio/wave': 'wav',
    'audio/vnd.wave': 'wav',
    'audio/mpeg': 'mp3',
    'audio/mp3': 'mp3',
    'audio/mp4': 'm4a',
    'audio/x-m4a': 'm4a',
    'audio/m4a': 'm4a',
    'audio/aac': 'aac',
    'audio/aacp': 'aac',
    'audio/flac': 'flac',
    'audio/x-flac': 'flac',
    'audio/ogg': 'ogg',
    'audio/opus': 'opus',
    'audio/aiff': 'aiff',
    'audio/x-aiff': 'aiff',
    'audio/pcm': 'pcm16',
    'audio/l16': 'pcm16',
  };

  static String? audioFormatFor(String mime) {
    final m = mime.trim().toLowerCase();
    final direct = _audioFormatByMime[m];
    if (direct != null) return direct;
    // Some providers send parameters (`audio/wav; codecs=1`).
    final semi = m.indexOf(';');
    if (semi > 0) return _audioFormatByMime[m.substring(0, semi).trim()];
    return null;
  }

  /// Gemini's accepted MIME spellings for the formats in
  /// [geminiAudioFormats]. m4a/opus/pcm are rejected before this point.
  static String normalizeGeminiAudioMime(String mime) {
    final m = mime.trim().toLowerCase();
    switch (m) {
      case 'audio/x-wav':
      case 'audio/vnd.wave':
        return 'audio/wav';
      case 'audio/mp3':
        return 'audio/mpeg';
      case 'audio/x-flac':
        return 'audio/flac';
      case 'audio/x-aiff':
        return 'audio/aiff';
      case 'audio/x-ogg':
        return 'audio/ogg';
      default:
        return m;
    }
  }

  static String hostOf(String baseUrl) {
    final raw = baseUrl.trim();
    if (raw.isEmpty) return '';
    final withScheme = raw.contains('://') ? raw : 'https://$raw';
    final uri = Uri.tryParse(withScheme);
    return (uri?.host ?? '').toLowerCase();
  }

  static bool isOfficialOpenAiHost(String baseUrl) =>
      hostOf(baseUrl) == 'api.openai.com';

  static Future<NativeInputBuildResult> build({
    required NativeInputProtocol protocol,
    required List<NativeAttachment> attachments,
    required String baseUrl,
    String Function(String path)? fixPath,
    int maxFileBytes = defaultMaxFileBytes,
    int maxEncodedBytes = defaultMaxEncodedBytesPerMessage,
  }) async {
    final parts = <Map<String, dynamic>>[];
    final errors = <NativeInputError>[];
    var encodedTotal = 0;
    final host = hostOf(baseUrl);
    final isDashScope = host.contains('dashscope');

    for (final attachment in attachments) {
      final isAudio = attachment.isAudio;
      final isPdf = attachment.isPdf;
      if (!isAudio && !isPdf) continue;

      if (isAudio) {
        if (protocol == NativeInputProtocol.responses ||
            protocol == NativeInputProtocol.claude) {
          errors.add(
            NativeInputError(
              NativeInputError.unsupportedProvider,
              attachment.name,
              '${protocol.name} has no native audio input',
            ),
          );
          continue;
        }
        final format = audioFormatFor(attachment.mime);
        if (format == null || !supportedAudioFormats.contains(format)) {
          errors.add(
            NativeInputError(
              NativeInputError.unsupportedFormat,
              attachment.name,
              'unsupported audio format for ${attachment.mime}',
            ),
          );
          continue;
        }
        if (protocol == NativeInputProtocol.openAiChat &&
            isOfficialOpenAiHost(baseUrl) &&
            !openAiOfficialAudioFormats.contains(format)) {
          errors.add(
            NativeInputError(
              NativeInputError.unsupportedFormat,
              attachment.name,
              'api.openai.com accepts only wav/mp3 (got $format)',
            ),
          );
          continue;
        }
        if (protocol == NativeInputProtocol.gemini &&
            !geminiAudioFormats.contains(format)) {
          errors.add(
            NativeInputError(
              NativeInputError.unsupportedFormat,
              attachment.name,
              'Gemini accepts wav/mp3/aiff/aac/ogg/flac (got $format)',
            ),
          );
          continue;
        }
      }

      final bytes = await _readBytes(
        attachment.path,
        fixPath: fixPath,
        maxFileBytes: maxFileBytes,
        errors: errors,
        fileName: attachment.name,
      );
      if (bytes == null) continue;

      final encoded = base64Encode(bytes);
      if (encodedTotal + encoded.length > maxEncodedBytes) {
        errors.add(
          NativeInputError(
            NativeInputError.tooLarge,
            attachment.name,
            'encoded attachment budget exceeded '
                '(${encodedTotal + encoded.length} > $maxEncodedBytes)',
          ),
        );
        continue;
      }

      final part = _partFor(
        protocol: protocol,
        attachment: attachment,
        base64Data: encoded,
        isDashScope: isDashScope,
        errors: errors,
      );
      if (part == null) continue;
      parts.add(part);
      encodedTotal += encoded.length;
    }

    return NativeInputBuildResult(
      parts: parts,
      errors: errors,
      encodedBytes: encodedTotal,
    );
  }

  static Map<String, dynamic>? _partFor({
    required NativeInputProtocol protocol,
    required NativeAttachment attachment,
    required String base64Data,
    required bool isDashScope,
    required List<NativeInputError> errors,
  }) {
    final isPdf = attachment.isPdf;
    switch (protocol) {
      case NativeInputProtocol.openAiChat:
        if (isPdf) {
          return <String, dynamic>{
            'type': 'file',
            'file': <String, dynamic>{
              'filename': attachment.name,
              'file_data': 'data:application/pdf;base64,$base64Data',
            },
          };
        }
        final format = audioFormatFor(attachment.mime);
        if (format == null) return null;
        // OpenAI expects raw base64; DashScope's gateway wants a data URI.
        final data = isDashScope
            ? 'data:${attachmentMimeFor(attachment.mime, attachment.name)}'
                  ';base64,$base64Data'
            : base64Data;
        return <String, dynamic>{
          'type': 'input_audio',
          'input_audio': <String, dynamic>{'data': data, 'format': format},
        };

      case NativeInputProtocol.responses:
        if (!isPdf) {
          errors.add(
            NativeInputError(
              NativeInputError.unsupportedProvider,
              attachment.name,
              'Responses API has no native audio input',
            ),
          );
          return null;
        }
        // Official schema: filename/file_data are siblings of `type`
        // (not nested under `file`).
        return <String, dynamic>{
          'type': 'input_file',
          'filename': attachment.name,
          'file_data': 'data:application/pdf;base64,$base64Data',
        };

      case NativeInputProtocol.claude:
        if (!isPdf) {
          errors.add(
            NativeInputError(
              NativeInputError.unsupportedProvider,
              attachment.name,
              'Claude has no native audio input',
            ),
          );
          return null;
        }
        // Vertex can only use inline base64 here (no Files API integration).
        return <String, dynamic>{
          'type': 'document',
          'title': attachment.name,
          'source': <String, dynamic>{
            'type': 'base64',
            'media_type': 'application/pdf',
            'data': base64Data,
          },
        };

      case NativeInputProtocol.gemini:
        final mime = isPdf
            ? 'application/pdf'
            : normalizeGeminiAudioMime(attachment.mime);
        return <String, dynamic>{
          'inline_data': <String, dynamic>{
            'mime_type': mime,
            'data': base64Data,
          },
        };
    }
  }

  static Future<List<int>?> _readBytes(
    String path, {
    required String Function(String path)? fixPath,
    required int maxFileBytes,
    required List<NativeInputError> errors,
    required String fileName,
  }) async {
    try {
      final fixed = fixPath != null ? fixPath(path) : path;
      final file = File(fixed);
      final length = await file.length();
      if (length > maxFileBytes) {
        errors.add(
          NativeInputError(
            NativeInputError.tooLarge,
            fileName,
            '$length > $maxFileBytes',
          ),
        );
        return null;
      }
      if (length <= 0) {
        errors.add(
          NativeInputError(
            NativeInputError.unavailable,
            fileName,
            'empty file',
          ),
        );
        return null;
      }
      return await file.readAsBytes();
    } on FileSystemException catch (e) {
      errors.add(
        NativeInputError(
          NativeInputError.unavailable,
          fileName,
          e.osError?.message ?? e.message,
        ),
      );
      return null;
    } catch (e) {
      errors.add(
        NativeInputError(NativeInputError.unreadable, fileName, '$e'),
      );
      return null;
    }
  }
}
