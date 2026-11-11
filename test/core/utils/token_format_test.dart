import 'package:OmniChat/core/utils/token_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatTokenCount', () {
    test('below 1k stays raw', () {
      expect(formatTokenCount(0), '0');
      expect(formatTokenCount(512), '512');
      expect(formatTokenCount(999), '999');
    });

    test('thousands drop the trailing .0', () {
      expect(formatTokenCount(1000), '1k');
      expect(formatTokenCount(128_000), '128k');
      expect(formatTokenCount(999_999), '999.9k');
    });

    test('one decimal is kept when meaningful', () {
      expect(formatTokenCount(1500), '1.5k');
      expect(formatTokenCount(272_000), '272k');
    });

    test('millions drop the trailing .0', () {
      expect(formatTokenCount(1_000_000), '1M');
      expect(formatTokenCount(1_500_000), '1.5M');
      expect(formatTokenCount(2_097_152), '2M');
    });
  });
}
