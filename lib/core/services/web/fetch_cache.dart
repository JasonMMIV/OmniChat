// In-memory web fetch cache (WEB_FETCH_PLAN.md §5.11).
//
// Only plain GET / no header / no body / no selector / raw=false results are
// stored (policy matrix §5.9). Nothing is ever written to disk.

import 'dart:async';

import 'fetch_core.dart';

class FetchCacheEntry {
  const FetchCacheEntry({
    required this.url,
    required this.result,
    required this.source,
    required this.fetchedAt,
  });

  final String url;

  /// Full result, not just the content: cache hits must keep the original
  /// charset, content type, final URL and truncated flag.
  final FetchResult result;

  /// `local` or the provider id that served the page.
  final String source;
  final DateTime fetchedAt;

  String get content => result.content;
  FetchMetadata get metadata => result.metadata;
}

class FetchCache {
  FetchCache({
    this.ttl = const Duration(minutes: 10),
    this.capacity = 8,
    this.maxChars = 2 * 1024 * 1024,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final int capacity;

  /// Approximate UTF-16 budget (2 MB characters).
  final int maxChars;
  final DateTime Function() _clock;

  final Map<String, FetchCacheEntry> _entries = <String, FetchCacheEntry>{};
  final Map<String, Future<FetchResult>> _inFlight =
      <String, Future<FetchResult>>{};

  int get length => _entries.length;

  FetchCacheEntry? lookup(String url) {
    final entry = _entries[url];
    if (entry == null) return null;
    if (_isExpired(entry)) return null;
    // Touch for LRU.
    _entries.remove(url);
    _entries[url] = entry;
    return entry;
  }

  /// Expired (but not evicted) entry, used to pin a continuation to the
  /// source that served the first page.
  FetchCacheEntry? staleLookup(String url) => _entries[url];

  void store({
    required String url,
    required FetchResult result,
    required String source,
    String? canonicalUrl,
  }) {
    final entry = FetchCacheEntry(
      url: url,
      result: result,
      source: source,
      fetchedAt: _clock(),
    );
    _entries.remove(url);
    _entries[url] = entry;
    if (canonicalUrl != null &&
        canonicalUrl.isNotEmpty &&
        canonicalUrl != url) {
      _entries.remove(canonicalUrl);
      _entries[canonicalUrl] = entry;
    }
    _evict();
  }

  /// Coalesces concurrent fetches of the same URL.
  Future<FetchResult> dedupe(
    String url,
    Future<FetchResult> Function() fetch,
  ) {
    final existing = _inFlight[url];
    if (existing != null) return existing;
    final future = fetch();
    _inFlight[url] = future;
    return future.whenComplete(() {
      // Block body: `whenComplete` must not return the removed future, or the
      // returned future waits on itself and never completes.
      _inFlight.remove(url);
    });
  }

  void clear() {
    _entries.clear();
    _inFlight.clear();
  }

  bool _isExpired(FetchCacheEntry entry) =>
      _clock().difference(entry.fetchedAt) > ttl;

  void _evict() {
    var totalChars = _entries.values
        .map((entry) => entry.content.length)
        .fold<int>(0, (sum, value) => sum + value);

    final keys = _entries.keys.toList();
    for (final key in keys) {
      final overCapacity = _entries.length > capacity;
      final overBudget = totalChars > maxChars;
      if (!overCapacity && !overBudget) break;
      final entry = _entries.remove(key);
      totalChars -= entry?.content.length ?? 0;
    }
  }
}
