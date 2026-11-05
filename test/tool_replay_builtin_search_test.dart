import 'package:OmniChat/core/services/chat/tool_replay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builtin_search display cards never become client tool calls', () {
    final pairs = buildToolReplayPairs(const [
      {
        'id': 'builtin_search',
        'name': 'search_web',
        'arguments': <String, dynamic>{},
        'content': '{"items":[]}',
      },
      {
        'id': 'search-1',
        'name': 'builtin_search',
        'arguments': <String, dynamic>{},
        'content': '{"items":[]}',
      },
      {
        'id': 'call_1',
        'name': 'search_web',
        'arguments': {'query': 'Flutter'},
        'content': 'result',
      },
    ], messageId: 'message-1');

    expect(pairs, hasLength(1));
    expect(pairs.single.toolName, 'search_web');
    expect(pairs.single.toolCallId, 'call_1');
  });
}
