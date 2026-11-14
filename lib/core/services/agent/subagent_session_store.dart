// In-memory helper sessions (docs/子代理P0-P1修正實作計畫.md P1-3).
//
// A session is the helper's own neutral message list, kept so a follow-up
// `spawn_subagent(session_id: ...)` does not have to resend the whole brief.
//
// Deliberate limits (D7): memory only, LRU 8 entries, 30-minute TTL, ownership
// checked per conversation. Restarting the app loses every session; a later
// P2 will make them durable.

import 'dart:collection';

/// One helper session.
class SubagentSession {
  SubagentSession({
    required this.id,
    required this.conversationId,
    required this.profileId,
    required this.messages,
    this.totalTokens = 0,
    DateTime? createdAt,
    DateTime? lastUsedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       lastUsedAt = lastUsedAt ?? DateTime.now();

  final String id;
  final String conversationId;
  final String profileId;

  /// Neutral OpenAI-format transcript (system prompt included, so a resume
  /// keeps the exact stable prefix the provider cache already saw).
  final List<Map<String, dynamic>> messages;

  /// Cumulative tokens across every run of this session (display only).
  int totalTokens;

  final DateTime createdAt;
  DateTime lastUsedAt;
}

/// Process-wide LRU + TTL session store.
class SubagentSessionStore {
  SubagentSessionStore({
    this.maxEntries = 8,
    this.ttl = const Duration(minutes: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static final SubagentSessionStore shared = SubagentSessionStore();

  final int maxEntries;
  final Duration ttl;
  final DateTime Function() _clock;

  final LinkedHashMap<String, SubagentSession> _sessions =
      LinkedHashMap<String, SubagentSession>();

  int get length => _sessions.length;

  /// Returns the session only when it exists, belongs to [conversationId] and
  /// has not expired. Expired entries are evicted on access.
  SubagentSession? get(String id, String conversationId) {
    final key = id.trim();
    if (key.isEmpty) return null;
    final session = _sessions[key];
    if (session == null) return null;
    if (_isExpired(session)) {
      _sessions.remove(key);
      return null;
    }
    if (session.conversationId != conversationId) return null;
    // LRU touch.
    _sessions.remove(key);
    _sessions[key] = session;
    return session;
  }

  /// Store (or replace) a session and evict the oldest entries beyond the
  /// ceiling.
  void put(SubagentSession session) {
    _sessions.remove(session.id);
    session.lastUsedAt = _clock();
    _sessions[session.id] = session;
    while (_sessions.length > maxEntries) {
      _sessions.remove(_sessions.keys.first);
    }
  }

  /// Drop every session owned by a conversation (called when it is deleted).
  void clearConversation(String conversationId) {
    _sessions.removeWhere(
      (_, session) => session.conversationId == conversationId,
    );
  }

  void clear() => _sessions.clear();

  bool _isExpired(SubagentSession session) {
    if (ttl <= Duration.zero) return false;
    return _clock().difference(session.lastUsedAt) > ttl;
  }
}
