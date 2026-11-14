import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/core/services/agent/subagent_mention.dart';

void main() {
  test('parses a leading profile mention and the task', () {
    final mention = parseSubagentMention('@explore find the TODOs');
    expect(mention, isNotNull);
    expect(mention!.profileId, 'explore');
    expect(mention.task, 'find the TODOs');
  });

  test('accepts whitespace, mixed case and multiline tasks', () {
    final mention = parseSubagentMention('\n  @Reviewer\ncheck\nthis');
    expect(mention!.profileId, 'reviewer');
    expect(mention.task, 'check\nthis');
  });

  test('an empty task is preserved so the UI can explain it', () {
    final mention = parseSubagentMention('@coder');
    expect(mention!.profileId, 'coder');
    expect(mention.task, isEmpty);
  });

  test('a non-leading mention is ordinary text', () {
    expect(parseSubagentMention('ask @explore about it'), isNull);
    expect(parseSubagentMention('@-bad task'), isNull);
    expect(parseSubagentMention('@'), isNull);
  });
}
