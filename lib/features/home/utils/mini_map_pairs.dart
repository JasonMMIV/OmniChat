import '../../../core/models/chat_message.dart';

/// A single user/assistant pair rendered in the mini-map.
class MiniMapPair {
  const MiniMapPair({this.user, this.assistant});

  final ChatMessage? user;
  final ChatMessage? assistant;
}

/// Collapses a message body into a one-line preview.
///
/// Inline thinking blocks and image/file markers are removed before the text
/// is flattened so the mini-map stays scannable.
String miniMapToOneLine(String input) {
  return input
      .replaceAll(
        RegExp(
          r'<(?:think|thought)>[\s\S]*?<\/(?:think|thought)>',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'\[image:[^\]]+\]'), '')
      .replaceAll(RegExp(r'\[file:[^\]]+\]'), '')
      .replaceAll('\n', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Groups [messages] into user/assistant pairs for the mini-map.
///
/// A user message is paired with the first assistant message that follows it.
/// Orphan assistants and trailing user messages are preserved so no message
/// silently disappears from the map.
List<MiniMapPair> buildMiniMapPairs(List<ChatMessage> messages) {
  final pairs = <MiniMapPair>[];
  ChatMessage? pendingUser;

  for (final message in messages) {
    if (message.role == 'user') {
      if (pendingUser != null) {
        pairs.add(MiniMapPair(user: pendingUser));
      }
      pendingUser = message;
    } else if (message.role == 'assistant') {
      if (pendingUser != null) {
        pairs.add(MiniMapPair(user: pendingUser, assistant: message));
        pendingUser = null;
      } else {
        pairs.add(MiniMapPair(assistant: message));
      }
    }
  }

  if (pendingUser != null) {
    pairs.add(MiniMapPair(user: pendingUser));
  }

  return pairs;
}
