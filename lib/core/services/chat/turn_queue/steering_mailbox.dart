/// Per-conversation mid-turn steering mailbox (owner-token guarded).
///
/// One mailbox exists per conversation; the *owner token* is the assistant
/// message id of the currently running segment (F5). This mirrors Anybuff's
/// `steering-mailbox.ts` claim/accept/owner-guard semantics:
///
/// - [activate] claims the mailbox for a run; a different token drops entries
///   from the previous run (they can never be injected into the wrong turn).
/// - [push] only accepts while an owner is active; consecutive pushes before a
///   drain merge into one entry (`\n\n`) so the echo bubble stays a single user
///   message (consecutive-user 400 guard, R2).
/// - [drain] empties the mailbox exactly once for the current owner; a stale
///   token drains nothing.
/// - [deactivate] from a late/older run is a no-op and never touches the new
///   owner's entries.
/// - [abandon] unconditionally clears the mailbox and returns the dropped
///   entries so the wiring layer can retract echoes and requeue the text.
///
/// Pure Dart (no Flutter imports). Echo persistence lives in the caller.
library;

/// One pending steering injection.
class SteeringEntry {
  SteeringEntry({
    required this.pushId,
    required this.text,
    this.echoMessageId,
  });

  /// Stable id of this push (diagnostics/tests only).
  final String pushId;

  /// The injected text. Merged in place while the entry is undrained.
  String text;

  /// The persisted user-echo message id, filled by the wiring layer right
  /// after the echo bubble is created. Null while the echo does not exist yet.
  String? echoMessageId;
}

class _Mailbox {
  String? ownerToken;
  final List<SteeringEntry> entries = <SteeringEntry>[];
}

/// Mailbox container keyed by conversation id.
class SteeringMailbox {
  final Map<String, _Mailbox> _byConversation = <String, _Mailbox>{};
  int _pushCounter = 0;

  /// Whether a run currently owns [conversationId]'s mailbox.
  bool isActive(String conversationId) =>
      _byConversation[conversationId]?.ownerToken != null;

  /// The current owner token, or null when the mailbox is inactive.
  String? ownerOf(String conversationId) =>
      _byConversation[conversationId]?.ownerToken;

  /// Conversation ids with an active owner or pending entries (prune/cleanup).
  Iterable<String> get trackedConversationIds => _byConversation.keys;

  /// Claims the mailbox for [ownerToken] (the run's assistant message id).
  ///
  /// Re-activating with a different token drops entries left by the previous
  /// run — a stale run must never inject into (or leak into) the new segment.
  void activate(String conversationId, String ownerToken) {
    final box = _byConversation.putIfAbsent(
      conversationId,
      () => _Mailbox(),
    );
    if (box.ownerToken != ownerToken) {
      box.entries.clear();
      box.ownerToken = ownerToken;
    }
  }

  /// Releases [ownerToken]'s claim. Late deactivations from an older run are a
  /// no-op (F5).
  void deactivate(String conversationId, String ownerToken) {
    final box = _byConversation[conversationId];
    if (box == null || box.ownerToken != ownerToken) return;
    box.ownerToken = null;
    box.entries.clear();
  }

  /// Pushes [text] for the active owner, or returns null when no run is
  /// active / the text is blank.
  ///
  /// Consecutive pushes before a drain merge into the same entry with `\n\n`.
  SteeringEntry? push(String conversationId, String text) {
    final box = _byConversation[conversationId];
    if (box == null || box.ownerToken == null) return null;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    if (box.entries.isNotEmpty) {
      final last = box.entries.last;
      last.text = '${last.text}\n\n$trimmed';
      return last;
    }
    final entry = SteeringEntry(
      pushId: 'steer_${++_pushCounter}',
      text: trimmed,
    );
    box.entries.add(entry);
    return entry;
  }

  /// Drains every pending entry for [ownerToken] (one-shot).
  ///
  /// A stale token drains nothing — the caller may then treat the mailbox as
  /// inactive without risking the new owner's entries.
  List<SteeringEntry> drain(String conversationId, String ownerToken) {
    final box = _byConversation[conversationId];
    if (box == null || box.ownerToken != ownerToken) {
      return const <SteeringEntry>[];
    }
    final out = List<SteeringEntry>.of(box.entries);
    box.entries.clear();
    return out;
  }

  /// Whether [conversationId] currently holds undrained entries.
  bool hasPending(String conversationId) =>
      _byConversation[conversationId]?.entries.isNotEmpty ?? false;

  /// Unconditionally clears the mailbox (owner and entries) and returns the
  /// dropped entries so the caller can retract echoes and requeue the text.
  List<SteeringEntry> abandon(String conversationId) {
    final box = _byConversation.remove(conversationId);
    return box == null
        ? const <SteeringEntry>[]
        : List<SteeringEntry>.of(box.entries);
  }
}
