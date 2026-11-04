import 'package:flutter_test/flutter_test.dart';

import 'package:OmniChat/shared/markdown/markdown_html_policy.dart';

void main() {
  test('allows only http, https, mailto and tel', () {
    expect(isSafeHtmlLink('https://example.com'), isTrue);
    expect(isSafeHtmlLink('http://example.com/a?b=1'), isTrue);
    expect(isSafeHtmlLink('mailto:test@example.com'), isTrue);
    expect(isSafeHtmlLink('tel:+123456'), isTrue);
  });

  test('rejects active, local and app schemes', () {
    for (final url in <String>[
      'javascript:alert(1)',
      'data:text/html,<script>alert(1)</script>',
      'file:///etc/passwd',
      'com.psyche.omnichat://oauth-callback?code=x',
      'omnichat://anything',
      '/relative/path',
      '//example.com',
      '',
    ]) {
      expect(isSafeHtmlLink(url), isFalse, reason: url);
    }
  });
}
