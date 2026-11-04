import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/shared/markdown/markdown_alert.dart';
import 'package:OmniChat/shared/markdown/markdown_directive.dart';

void main() {
  test('parses known directive kinds and tolerates ::: spacing', () {
    final cases = <String, MarkdownAlertKind>{
      ':::note': MarkdownAlertKind.note,
      '::: tip': MarkdownAlertKind.tip,
      ':::important': MarkdownAlertKind.important,
      ':::warning': MarkdownAlertKind.warning,
      ':::caution': MarkdownAlertKind.caution,
      ':::danger': MarkdownAlertKind.caution,
    };
    for (final entry in cases.entries) {
      final directive = parseMarkdownDirective('${entry.key}\nbody\n:::');
      expect(directive, isNotNull, reason: entry.key);
      expect(directive!.kind, entry.value, reason: entry.key);
      expect(directive.body, 'body');
      expect(directive.closed, isTrue);
    }
  });

  test('parses custom titles and strips simple HTML', () {
    final directive = parseMarkdownDirective(
      ':::tip title="<b>Read</b> &amp; remember"\n'
      '**bold** body\n'
      ':::',
    );
    expect(directive, isNotNull);
    expect(directive!.title, 'Read & remember');
    expect(directive.body, '**bold** body');
  });

  test('unknown directives preserve children and expose a null kind', () {
    final directive = parseMarkdownDirective(':::unknown\nkeep this **markdown**\n:::');
    expect(directive, isNotNull);
    expect(directive!.kind, isNull);
    expect(directive.body, 'keep this **markdown**');
    expect(directive.closed, isTrue);
  });

  test('unclosed directive is marked not closed for streaming', () {
    final directive = parseMarkdownDirective(':::warning\npartial body');
    expect(directive, isNotNull);
    expect(directive!.kind, MarkdownAlertKind.warning);
    expect(directive.body, 'partial body');
    expect(directive.closed, isFalse);
  });

  test('accepts an empty body', () {
    final directive = parseMarkdownDirective(':::note\n:::');
    expect(directive, isNotNull);
    expect(directive!.kind, MarkdownAlertKind.note);
    expect(directive.body, '');
    expect(directive.closed, isTrue);
  });

  test('normalizes CRLF and rejects malformed openings', () {
    final directive = parseMarkdownDirective(':::note\r\nline1\r\nline2\r\n:::');
    expect(directive, isNotNull);
    expect(directive!.body, 'line1\nline2');

    expect(parseMarkdownDirective('plain text\n:::'), isNull);
    expect(parseMarkdownDirective('::::note\nbody\n:::'), isNull);
    expect(parseMarkdownDirective(''), isNull);
  });
}
