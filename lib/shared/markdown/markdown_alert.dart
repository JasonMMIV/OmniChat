/// GitHub-flavoured alert kinds supported by the legacy blockquote renderer.
enum MarkdownAlertKind { note, tip, important, warning, caution }

/// Parsed `> [!NOTE]` blockquote content.
class MarkdownAlert {
  const MarkdownAlert({required this.kind, required this.body, this.customTitle});

  final MarkdownAlertKind kind;

  /// Optional title written after the marker, e.g. `[!TIP] My title`.
  final String? customTitle;

  /// Alert body with the marker line removed (may be empty).
  final String body;
}

final RegExp _alertMarker = RegExp(r'^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*(.*)$', caseSensitive: false);

/// Parses the text inside a blockquote. The caller is responsible for
/// stripping the `>` prefixes first.
MarkdownAlert? parseMarkdownAlert(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (normalized.isEmpty) return null;

  final lines = normalized.split('\n');
  final match = _alertMarker.firstMatch(lines.first.trim());
  if (match == null) return null;

  final kind = markdownAlertKindFromName(match.group(1)!)!;
  final customTitle = stripSimpleHtml((match.group(2) ?? '').trim());

  return MarkdownAlert(
    kind: kind,
    customTitle: customTitle.isEmpty ? null : customTitle,
    body: lines.skip(1).join('\n').trim(),
  );
}

/// Maps GitHub alert / directive names to a card kind.
MarkdownAlertKind? markdownAlertKindFromName(String name) {
  return switch (name.trim().toLowerCase()) {
    'note' => MarkdownAlertKind.note,
    'tip' => MarkdownAlertKind.tip,
    'important' => MarkdownAlertKind.important,
    'warning' => MarkdownAlertKind.warning,
    'caution' || 'danger' => MarkdownAlertKind.caution,
    _ => null,
  };
}

/// Strips a small, non-authoritative HTML subset from synthetic card titles.
String stripSimpleHtml(String value) {
  return value
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .trim();
}
