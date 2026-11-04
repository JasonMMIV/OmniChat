import 'markdown_alert.dart';

/// Parsed `:::type [title="..."]` block.
class MarkdownDirective {
  const MarkdownDirective({required this.kind, required this.body, required this.closed, this.title});

  /// Null when the name is unknown; children are still preserved.
  final MarkdownAlertKind? kind;

  final String? title;
  final String body;

  /// False when the closing `:::` has not arrived yet (streaming).
  final bool closed;
}

final RegExp _opening = RegExp(r'^:::[ \t]*([A-Za-z][\w-]*)[ \t]*(?:title="([^"]*)")?[ \t]*$', caseSensitive: false);

MarkdownDirective? parseMarkdownDirective(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (normalized.isEmpty) return null;

  final lines = normalized.split('\n');
  final opening = _opening.firstMatch(lines.first.trim());
  if (opening == null) return null;

  final bodyLines = lines.skip(1).toList();
  var closed = false;
  if (bodyLines.isNotEmpty && bodyLines.last.trim() == ':::') {
    bodyLines.removeLast();
    closed = true;
  }

  final name = opening.group(1)!;
  final title = stripSimpleHtml((opening.group(2) ?? '').trim());
  return MarkdownDirective(
    kind: markdownAlertKindFromName(name),
    title: title.isEmpty ? null : title,
    body: bodyLines.join('\n').trim(),
    closed: closed,
  );
}
