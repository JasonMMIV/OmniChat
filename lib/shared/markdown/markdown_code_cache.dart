import 'dart:collection';

import 'package:highlight/highlight.dart' show Node;

/// LRU cache for `highlight.parse` syntax trees.
///
/// The entry keeps the original source next to the tree: a hash key alone can
/// collide and return another block's tree, which would render wrong syntax
/// highlighting (a correctness bug, not a perf trade-off). Hits compare the
/// stored source with `==` before returning — string comparison is far cheaper
/// than re-parsing.
class CodeHighlightCache {
  CodeHighlightCache({this.maxBytes = 8 * 1024 * 1024});

  final int maxBytes;

  final LinkedHashMap<String, _CacheEntry> _entries =
      LinkedHashMap<String, _CacheEntry>();
  int _bytes = 0;
  int _hits = 0;
  int _misses = 0;

  static final CodeHighlightCache instance = CodeHighlightCache();

  List<Node>? get(String source, String? language) {
    final key = _key(source, language);
    final entry = _entries.remove(key);
    if (entry == null || entry.source != source) {
      _misses++;
      return null;
    }
    // Re-insert to mark most-recently-used.
    _entries[key] = entry;
    _hits++;
    return entry.nodes;
  }

  void put(String source, String? language, List<Node> nodes) {
    final key = _key(source, language);
    final existing = _entries.remove(key);
    if (existing != null) _bytes -= existing.estimatedBytes;

    final entry = _CacheEntry(
      source: source,
      nodes: nodes,
      estimatedBytes: _estimate(source, nodes),
    );
    _entries[key] = entry;
    _bytes += entry.estimatedBytes;

    while (_bytes > maxBytes && _entries.isNotEmpty) {
      final oldestKey = _entries.keys.first;
      final removed = _entries.remove(oldestKey);
      if (removed != null) _bytes -= removed.estimatedBytes;
    }
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
    _hits = 0;
    _misses = 0;
  }

  int get debugBytes => _bytes;
  int get debugLength => _entries.length;
  int get debugHits => _hits;
  int get debugMisses => _misses;

  static String _key(String source, String? language) {
    return '${language ?? ''}|${source.length}|${source.hashCode}';
  }

  static int _estimate(String source, List<Node> nodes) {
    // Source is stored as UTF-16; count the whole tree (children dominate),
    // otherwise the 8 MB budget is effectively unbounded for deep trees.
    return source.length * 2 + _nodeCount(nodes) * 48 + 128;
  }

  static int _nodeCount(List<Node> nodes) {
    var count = 0;
    for (final node in nodes) {
      count++;
      final children = node.children;
      if (children != null) count += _nodeCount(children);
    }
    return count;
  }
}

class _CacheEntry {
  const _CacheEntry({
    required this.source,
    required this.nodes,
    required this.estimatedBytes,
  });

  final String source;
  final List<Node> nodes;
  final int estimatedBytes;
}
