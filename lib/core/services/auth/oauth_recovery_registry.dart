// Modified for OmniChat on 2026-11-01. See THIRD_PARTY_NOTICES.md.
//
// Per-message record of turns that failed because a subscription account lost
// its credentials (plan M4). The recovery card is keyed on this record instead
// of the localized notice text: a language switch (or a copy change) must not
// orphan the card, and a background 401 from usage / model sync must not put a
// Retry affordance under an already-successful answer.
//
// Deliberately memory-only: the authoritative state is
// `ProviderOAuthService.isLoginRequired`, which is rebuilt by the first request
// after a restart. The bubble keeps the localized notice in that case.

import 'package:flutter/foundation.dart';

class OAuthRecoveryRegistry extends ChangeNotifier {
  OAuthRecoveryRegistry();

  /// App-wide registry. Tests pass an isolated instance instead.
  static final OAuthRecoveryRegistry instance = OAuthRecoveryRegistry();

  /// Upper bound so a long-lived session cannot grow this unbounded. Entries
  /// are only message ids and only auth failures add them.
  static const int _maxEntries = 500;

  final Set<String> _failed = <String>{};

  void markFailed(String messageId) {
    if (messageId.isEmpty) return;
    if (_failed.length >= _maxEntries && !_failed.contains(messageId)) {
      _failed.remove(_failed.first);
    }
    if (_failed.add(messageId)) notifyListeners();
  }

  bool isFailed(String messageId) => _failed.contains(messageId);

  void clear(String messageId) {
    if (_failed.remove(messageId)) notifyListeners();
  }
}
