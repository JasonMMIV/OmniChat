/// A composer `@profile` mention.
///
/// The Add-ons subagent picker inserts `@<id> `; users may also type it. Only
/// a leading mention is meaningful — an `@` in the middle of a sentence stays
/// ordinary text.
class SubagentMention {
  const SubagentMention({required this.profileId, required this.task});

  final String profileId;

  /// Everything after the mention, trimmed. Empty when the user only typed
  /// `@profile` and has not described a task yet.
  final String task;
}

final RegExp _mentionPattern = RegExp(
  r'^\s*@([a-z0-9][a-z0-9_-]{0,39})(?:\s+([\s\S]*))?$',
  caseSensitive: false,
);

SubagentMention? parseSubagentMention(String text) {
  final match = _mentionPattern.firstMatch(text);
  if (match == null) return null;
  final id = (match.group(1) ?? '').toLowerCase();
  if (id.isEmpty) return null;
  return SubagentMention(profileId: id, task: (match.group(2) ?? '').trim());
}
