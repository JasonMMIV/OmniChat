import 'package:flutter_test/flutter_test.dart';
import 'package:highlight/highlight.dart' show Node, highlight;

import 'package:OmniChat/shared/markdown/markdown_code_cache.dart';

void main() {
  test('stores and retrieves by source and language', () {
    final cache = CodeHighlightCache();
    final nodes = <Node>[];

    cache.put('void main() {}', 'dart', nodes);

    expect(identical(cache.get('void main() {}', 'dart'), nodes), isTrue);
    expect(cache.get('void main() {}', 'python'), isNull);
    expect(cache.get('other source', 'dart'), isNull);
  });

  test('LRU evicts the oldest entry when over budget', () {
    final cache = CodeHighlightCache(maxBytes: 500);
    cache.put('a' * 50, 'dart', <Node>[]);
    cache.put('b' * 50, 'dart', <Node>[]);
    cache.put('c' * 50, 'dart', <Node>[]);

    expect(cache.get('a' * 50, 'dart'), isNull);
    expect(cache.get('b' * 50, 'dart'), isNotNull);
    expect(cache.get('c' * 50, 'dart'), isNotNull);
  });

  test('recently used entries survive eviction', () {
    final cache = CodeHighlightCache(maxBytes: 500);
    cache.put('a' * 50, 'dart', <Node>[]);
    cache.put('b' * 50, 'dart', <Node>[]);

    // Touch `a` so it becomes most recently used.
    expect(cache.get('a' * 50, 'dart'), isNotNull);
    cache.put('c' * 50, 'dart', <Node>[]);

    expect(cache.get('b' * 50, 'dart'), isNull);
    expect(cache.get('a' * 50, 'dart'), isNotNull);
    expect(cache.get('c' * 50, 'dart'), isNotNull);
  });

  test('byte estimate counts nested nodes', () {
    final cache = CodeHighlightCache(maxBytes: 100000);
    const source = 'void main() { if (true) { print("x"); } }';
    final parsed = highlight.parse(source, language: 'dart').nodes ?? <Node>[];

    cache.put(source, 'dart', parsed);
    final nestedBytes = cache.debugBytes;
    cache.clear();
    cache.put(source, 'dart', const <Node>[]);

    expect(nestedBytes, greaterThan(cache.debugBytes));
  });

  test('overwriting the same key does not double-count bytes', () {
    final cache = CodeHighlightCache(maxBytes: 500);
    cache.put('a' * 50, 'dart', <Node>[]);
    final bytesAfterFirst = cache.debugBytes;
    cache.put('a' * 50, 'dart', <Node>[]);
    expect(cache.debugBytes, bytesAfterFirst);
    expect(cache.debugLength, 1);
  });

  test('clear resets entries and counters', () {
    final cache = CodeHighlightCache();
    cache.put('source', 'dart', <Node>[]);
    cache.get('source', 'dart');
    cache.get('missing', 'dart');

    cache.clear();

    expect(cache.debugLength, 0);
    expect(cache.debugBytes, 0);
    expect(cache.debugHits, 0);
    expect(cache.debugMisses, 0);
    expect(cache.get('source', 'dart'), isNull);
  });
}
