// Ported from kelivo `lib/core/services/api/providers/openai/reasoning_details_replay.dart`
// (AGPL-3.0, commit 05eef503b6e7cda14de897373b79bab7bebe35b9),
// modified for OmniChat: accumulator handles snapshot endpoints, and a
// transport-facing helper folds structured details into `reasoning_content`
// when the target only understands the scalar field.
//
// OpenRouter-style `reasoning_details` arrive either as one entry per stream
// delta or as a cumulative snapshot. Echoing raw fragments back makes strict
// Anthropic/Bedrock upstreams rebuild one thinking block per fragment, and a
// signature-only fragment becomes a block with a null text (HTTP 400).
library;

/// Appends one streamed `reasoning_details` payload to [current].
///
/// Fragment endpoints append. Snapshot endpoints resend the whole list every
/// time; a longer snapshot replaces the current list and a repeated one is a
/// no-op. OpenRouter is the fragment case (`allowSnapshots: false`).
dynamic appendReasoningDetails(
  dynamic current,
  dynamic incoming, {
  required bool allowSnapshots,
}) {
  if (incoming is! List || incoming.isEmpty) return current;
  if (current is! List || current.isEmpty) return List<dynamic>.of(incoming);
  if (allowSnapshots && _hasPrefix(current, incoming)) {
    return incoming.length >= current.length
        ? List<dynamic>.of(incoming)
        : current;
  }
  return <dynamic>[...current, ...incoming];
}

bool _hasPrefix(List<dynamic> current, List<dynamic> incoming) {
  if (incoming.length < current.length) return false;
  for (var i = 0; i < current.length; i++) {
    if (!_sameJson(current[i], incoming[i])) return false;
  }
  return true;
}

bool _sameJson(dynamic a, dynamic b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_sameJson(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Joins stream fragments into complete reasoning blocks.
///
/// Text fragments with the same type/id/index/format are concatenated exactly
/// (no separator). A signature closes its block: later prose starts a new one,
/// while a repeated signature-only entry folds into the closed block.
/// Opaque entries (`reasoning.encrypted`) travel verbatim.
List<Map<String, dynamic>>? mergeReasoningDetails(dynamic raw) {
  if (raw is! List || raw.isEmpty) return null;

  final merged = <_ReasoningBlock>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final entry = item.map((key, value) => MapEntry(key.toString(), value));
    final block = _ReasoningBlock(entry);
    if (block.textKey == null) {
      merged.add(block);
      continue;
    }
    final previous = merged.isEmpty ? null : merged.last;
    if (previous != null && previous.canAbsorb(block)) {
      previous.absorb(block);
    } else {
      merged.add(block);
    }
  }

  final out = <Map<String, dynamic>>[];
  for (final block in merged) {
    final textKey = block.textKey;
    if (textKey != null && block.text.isNotEmpty) {
      block.entry[textKey] = block.text;
    }
    out.add(block.entry);
  }
  return out.isEmpty ? null : out;
}

/// Returns blocks that can be sent back to a provider. A signature-only
/// leftover has no text to rebuild and would fail strict thinking-block
/// validation; persistence keeps it, replay drops it.
List<Map<String, dynamic>>? normalizeReasoningDetailsForReplay(dynamic raw) {
  final blocks = mergeReasoningDetails(raw);
  if (blocks == null) return null;
  final out = <Map<String, dynamic>>[];
  for (final entry in blocks) {
    final textKey = _textKeyFor(entry);
    if (textKey == null) {
      out.add(entry);
      continue;
    }
    final text = entry[textKey];
    if (text is String && text.isNotEmpty) out.add(entry);
  }
  return out.isEmpty ? null : out;
}

/// Concatenates every prose block, preserving order. Used when a structured
/// payload has to be replayed to a scalar-only endpoint.
String reasoningDetailsText(dynamic raw) {
  final blocks = mergeReasoningDetails(raw);
  if (blocks == null) return '';
  final buffer = StringBuffer();
  for (final entry in blocks) {
    final textKey = _textKeyFor(entry);
    if (textKey == null) continue;
    final text = entry[textKey];
    if (text is String) buffer.write(text);
  }
  return buffer.toString();
}

/// Normalizes assistant reasoning echo on a chat-completions `messages` list.
///
/// * [preserveDetails] targets get merged `reasoning_details` and no parallel
///   `reasoning_content` (sending both duplicates the thinking text).
/// * Scalar targets drop structured details and keep/fill
///   `reasoning_content`, which DeepSeek-family thinking mode requires back.
void normalizeReasoningEchoMessages(
  List<Map<String, dynamic>> messages, {
  required bool preserveDetails,
  required bool needsText,
}) {
  for (final message in messages) {
    if (message['reasoning_details'] == null) continue;
    final rawDetails = message['reasoning_details'];
    final details = normalizeReasoningDetailsForReplay(rawDetails);
    if (preserveDetails && details != null) {
      message['reasoning_details'] = details;
      message.remove('reasoning_content');
      continue;
    }

    message.remove('reasoning_details');
    if (!needsText) continue;
    final current = message['reasoning_content'];
    if (current is String && current.isNotEmpty) continue;
    final text = reasoningDetailsText(rawDetails);
    if (text.isNotEmpty) message['reasoning_content'] = text;
  }
}

class _ReasoningBlock {
  _ReasoningBlock(this.entry)
    : type = (entry['type'] ?? 'reasoning.text').toString(),
      textKey = _textKeyFor(entry) {
    final value = textKey == null ? null : entry[textKey];
    if (value is String) _text.write(value);
  }

  final Map<String, dynamic> entry;
  final String type;

  /// Which field carries this entry's prose, or null for opaque payloads.
  final String? textKey;
  final StringBuffer _text = StringBuffer();
  String get text => _text.toString();

  String? get signature {
    final value = entry['signature'];
    return value is String && value.isNotEmpty ? value : null;
  }

  bool canAbsorb(_ReasoningBlock next) {
    if (next.type != type || next.textKey != textKey) return false;
    if (!_sameOptional(entry['id'], next.entry['id'])) return false;
    if (!_sameOptional(entry['index'], next.entry['index'])) return false;
    if (!_sameOptional(entry['format'], next.entry['format'])) return false;

    final current = signature;
    if (current == null) return true;
    // New prose after a signature belongs to a new block. Changing the text
    // of a signed block would invalidate the signature.
    final incoming = next.signature;
    return next._text.isEmpty && (incoming == null || incoming == current);
  }

  void absorb(_ReasoningBlock next) {
    _text.write(next._text);
    final incoming = next.signature;
    if (incoming != null) entry['signature'] = incoming;
    for (final field in next.entry.entries) {
      if (field.key == textKey || field.key == 'signature') continue;
      if (entry[field.key] == null && field.value != null) {
        entry[field.key] = field.value;
      } else {
        entry.putIfAbsent(field.key, () => field.value);
      }
    }
  }
}

String? _textKeyFor(Map<String, dynamic> entry) {
  final type = (entry['type'] ?? 'reasoning.text').toString();
  if (type == 'reasoning.text') return 'text';
  if (type != 'reasoning.summary') return null;
  if (entry['summary'] is String) return 'summary';
  if (entry['text'] is String) return 'text';
  return 'summary';
}

bool _sameOptional(dynamic a, dynamic b) {
  if (a == null || b == null) return true;
  return a == b;
}
