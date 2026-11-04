import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/shared/markdown/markdown_alert.dart';

void main() {
  test('parses all alert kinds case-insensitively', () {
    final cases = <String, MarkdownAlertKind>{
      '[!NOTE]': MarkdownAlertKind.note,
      '[!tip]': MarkdownAlertKind.tip,
      '[!Important]': MarkdownAlertKind.important,
      '[!WARNING]': MarkdownAlertKind.warning,
      '[!CAUTION]': MarkdownAlertKind.caution,
    };
    for (final entry in cases.entries) {
      final alert = parseMarkdownAlert('${entry.key}\nbody');
      expect(alert, isNotNull, reason: entry.key);
      expect(alert!.kind, entry.value);
      expect(alert.body, 'body');
      expect(alert.customTitle, isNull);
    }
  });

  test('keeps an optional custom title and the full body', () {
    final alert = parseMarkdownAlert('[!WARNING] Back up first\n\nLine one\n\n- item');
    expect(alert, isNotNull);
    expect(alert!.kind, MarkdownAlertKind.warning);
    expect(alert.customTitle, 'Back up first');
    expect(alert.body, 'Line one\n\n- item');
  });

  test('strips simple HTML from custom titles', () {
    final alert = parseMarkdownAlert('[!NOTE] <b>Backup</b> &amp; restore');
    expect(alert, isNotNull);
    expect(alert!.customTitle, 'Backup & restore');
  });

  test('allows an empty body and normalizes CRLF', () {
    final alert = parseMarkdownAlert('[!NOTE]\r\n\r\nline\r\nline2');
    expect(alert, isNotNull);
    expect(alert!.body, 'line\nline2');
  });

  test('returns null for ordinary blockquotes and malformed markers', () {
    expect(parseMarkdownAlert('just a quote'), isNull);
    expect(parseMarkdownAlert('ordinary line\n[!NOTE]\nbody'), isNull);
    expect(parseMarkdownAlert('> [!NOTE]\nbody'), isNull);
    expect(parseMarkdownAlert('[!UNKNOWN]\nbody'), isNull);
    expect(parseMarkdownAlert(''), isNull);
  });
}
