import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/shared/widgets/mermaid_failure_cache.dart';

void main() {
  test('marks failures and expires them after the TTL', () {
    var now = DateTime(2026, 1, 1);
    final cache = MermaidFailureCache(
      ttl: const Duration(seconds: 30),
      clock: () => now,
    );

    expect(cache.isFailed('diagram'), isFalse);
    cache.markFailed('diagram');
    expect(cache.isFailed('diagram'), isTrue);
    expect(cache.debugLength, 1);

    now = now.add(const Duration(seconds: 29));
    expect(cache.isFailed('diagram'), isTrue);

    now = now.add(const Duration(seconds: 2));
    expect(cache.isFailed('diagram'), isFalse);
    expect(cache.debugLength, 0);
  });

  test('clear removes one key and clearAll empties the cache', () {
    final cache = MermaidFailureCache(clock: () => DateTime(2026, 1, 1));

    cache.markFailed('a');
    cache.markFailed('b');
    cache.clear('a');
    expect(cache.isFailed('a'), isFalse);
    expect(cache.isFailed('b'), isTrue);

    cache.clearAll();
    expect(cache.isFailed('b'), isFalse);
    expect(cache.debugLength, 0);
  });
}
