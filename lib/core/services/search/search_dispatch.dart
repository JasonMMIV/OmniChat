import 'dart:convert';

/// Multi-provider search dispatch engine (fallback backup + round-robin).
///
/// Pure Dart on purpose — no Flutter imports — so the whole engine is unit
/// testable without bindings (mirrors the `WorkspaceConfig` pattern of
/// keeping small models/codecs outside the Flutter tree).
///
/// State (round-robin cursor + 429 cooldown table) lives in memory for the
/// app lifecycle and resets on restart, matching the existing "ephemeral
/// connection test results" pattern.

/// How multiple selected search providers are dispatched.
enum SearchDispatchMode { fallback, roundRobin }

extension SearchDispatchModeCodec on SearchDispatchMode {
  String get value => switch (this) {
    SearchDispatchMode.fallback => 'fallback',
    SearchDispatchMode.roundRobin => 'round_robin',
  };

  static SearchDispatchMode fromValue(
    String? value, {
    SearchDispatchMode fallback = SearchDispatchMode.fallback,
  }) {
    return switch (value) {
      'fallback' => SearchDispatchMode.fallback,
      'round_robin' => SearchDispatchMode.roundRobin,
      _ => fallback,
    };
  }
}

/// One selectable provider candidate for a dispatch run. [name] is the
/// display name used in user/LLM facing messages.
class SearchDispatchCandidate {
  const SearchDispatchCandidate({required this.id, required this.name});

  final String id;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is SearchDispatchCandidate && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// Lightweight failure taxonomy. All three kinds trigger switching to the
/// next provider; only [rateLimit] additionally starts a cooldown.
enum SearchFailureKind { rateLimit, timeout, generic }

final RegExp _rateLimitPattern = RegExp(
  r'429|rate.?limit|too many requests',
  caseSensitive: false,
);
final RegExp _timeoutPattern = RegExp(
  r'timeout|timed out',
  caseSensitive: false,
);

/// Classify a provider failure from its exception/string message. Intended
/// to work against the existing 24 providers' raw exception strings without
/// changing any of them.
SearchFailureKind classifySearchFailure(Object error) {
  final text = error.toString().toLowerCase();
  if (_rateLimitPattern.hasMatch(text)) return SearchFailureKind.rateLimit;
  if (_timeoutPattern.hasMatch(text)) return SearchFailureKind.timeout;
  return SearchFailureKind.generic;
}

/// One failed attempt, kept for the aggregate error payload.
class SearchAttemptFailure {
  const SearchAttemptFailure({
    required this.candidate,
    required this.kind,
    required this.message,
  });

  final SearchDispatchCandidate candidate;
  final SearchFailureKind kind;
  final String message;
}

/// Result of a dispatch run. [value] is the successful attempt's payload
/// (null when every candidate failed). [provider] is the candidate that
/// served it and [fallbackFrom] the provider the search originally started
/// with when the success came from a later attempt (null otherwise).
class SearchDispatchOutcome<T> {
  const SearchDispatchOutcome({
    this.value,
    this.provider,
    this.fallbackFrom,
    this.failures = const <SearchAttemptFailure>[],
  });

  final T? value;
  final SearchDispatchCandidate? provider;
  final SearchDispatchCandidate? fallbackFrom;
  final List<SearchAttemptFailure> failures;

  bool get succeeded => value != null;
}

/// In-memory dispatch state machine: orders candidates per mode, walks them
/// until one succeeds, records 429 cooldowns and advances the round-robin
/// cursor once per completed search.
class SearchDispatcher {
  SearchDispatcher({
    DateTime Function()? clock,
    this.cooldownDuration = const Duration(seconds: 60),
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// How long a rate-limited provider is skipped before being retried.
  final Duration cooldownDuration;

  final Map<String, DateTime> _cooldownUntil = <String, DateTime>{};
  int _roundRobinCursor = 0;

  /// True while [candidateId] is rate-limit cooling down.
  bool isInCooldown(String candidateId) {
    final until = _cooldownUntil[candidateId];
    if (until == null) return false;
    return _clock().isBefore(until);
  }

  /// Build the attempt order for one search.
  ///
  /// [candidates] arrive in priority order (service-list order; first =
  /// primary provider). Fallback keeps that order; round-robin rotates the
  /// start point by the in-memory cursor. Providers in 429 cooldown are
  /// skipped — unless every candidate is cooling down, in which case the
  /// full order is returned (never fail the search because of the table).
  List<SearchDispatchCandidate> orderCandidates(
    List<SearchDispatchCandidate> candidates,
    SearchDispatchMode mode,
  ) {
    if (candidates.isEmpty) return const <SearchDispatchCandidate>[];
    var ordered = List<SearchDispatchCandidate>.of(candidates);
    if (mode == SearchDispatchMode.roundRobin && ordered.length > 1) {
      final start = _roundRobinCursor % ordered.length;
      ordered = <SearchDispatchCandidate>[
        ...ordered.sublist(start),
        ...ordered.sublist(0, start),
      ];
    }
    final active = ordered
        .where((c) => !isInCooldown(c.id))
        .toList(growable: false);
    return active.isEmpty ? ordered : active;
  }

  /// Try [candidates] in order until one [attempt] succeeds. Every failure
  /// switches to the next candidate (rate-limit failures also start the
  /// cooldown); the round-robin cursor advances once per completed search
  /// (success or total failure).
  Future<SearchDispatchOutcome<T>> dispatch<T>({
    required List<SearchDispatchCandidate> candidates,
    required SearchDispatchMode mode,
    required Future<T> Function(SearchDispatchCandidate candidate) attempt,
  }) async {
    final ordered = orderCandidates(candidates, mode);
    final failures = <SearchAttemptFailure>[];
    if (ordered.isEmpty) {
      return SearchDispatchOutcome<T>(failures: failures);
    }
    for (var i = 0; i < ordered.length; i++) {
      final candidate = ordered[i];
      try {
        final value = await attempt(candidate);
        _roundRobinCursor++;
        return SearchDispatchOutcome<T>(
          value: value,
          provider: candidate,
          fallbackFrom: i > 0 ? ordered.first : null,
          failures: failures,
        );
      } catch (e) {
        final kind = classifySearchFailure(e);
        if (kind == SearchFailureKind.rateLimit) {
          _cooldownUntil[candidate.id] = _clock().add(cooldownDuration);
        }
        failures.add(
          SearchAttemptFailure(
            candidate: candidate,
            kind: kind,
            message: e.toString(),
          ),
        );
      }
    }
    _roundRobinCursor++;
    return SearchDispatchOutcome<T>(failures: failures);
  }

  /// Aggregate error payload for all-failed searches. Keeps the existing
  /// `{'error': ...}` shape and lists every attempted provider with its
  /// failure reason.
  static String buildAggregateErrorJson(List<SearchAttemptFailure> failures) {
    if (failures.isEmpty) {
      return jsonEncode({'error': 'No search services configured'});
    }
    final summary = failures
        .map((f) => '${f.candidate.name}: ${f.message}')
        .join('; ');
    return jsonEncode({
      'error': 'Search failed: all providers failed ($summary)',
      'attempts': [
        for (final f in failures)
          {
            'provider': f.candidate.name,
            ...switch (f.kind) {
              SearchFailureKind.rateLimit => const {'type': 'rate_limit'},
              SearchFailureKind.timeout => const {'type': 'timeout'},
              SearchFailureKind.generic => const <String, String>{},
            },
            'reason': f.message,
          },
      ],
    });
  }
}
