/// Global negative cache for failed Mermaid bitmap renders.
///
/// A diagram that failed to render should not spawn a fresh WebView on every
/// rebuild (streaming, scrolling, theme changes). Entries expire after [ttl]
/// so a transient failure can recover later.
///
/// Note: expiry is not reactive. The widget shows the error until its next
/// build after the entry expires; no timer/notifier is attached.
class MermaidFailureCache {
  MermaidFailureCache({
    this.ttl = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _clock;
  final Map<String, DateTime> _failures = <String, DateTime>{};

  static final MermaidFailureCache instance = MermaidFailureCache();

  // Kept as a separate instance in tests; production uses `instance`.

  bool isFailed(String key) {
    _purge();
    return _failures.containsKey(key);
  }

  void markFailed(String key) {
    _purge();
    _failures[key] = _clock();
  }

  void clear(String key) {
    _failures.remove(key);
  }

  void clearAll() {
    _failures.clear();
  }

  int get debugLength {
    _purge();
    return _failures.length;
  }

  void _purge() {
    final cutoff = _clock().subtract(ttl);
    _failures.removeWhere((_, failedAt) => failedAt.isBefore(cutoff));
  }
}
