import 'package:http/http.dart' as http;

/// Injects provider session headers into every request sent through this
/// client.
///
/// The wrapper is created once per generation (before the retry loop), so
/// retries and tool follow-up rounds reuse the same values. Headers already
/// present on the request win: users can override the automatic contract via
/// provider/model custom headers.
class ProviderSessionClient extends http.BaseClient {
  ProviderSessionClient({
    required http.Client inner,
    required Map<String, String> headers,
  })  : _inner = inner,
        _headers = Map<String, String>.unmodifiable(headers);

  final http.Client _inner;
  final Map<String, String> _headers;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    for (final entry in _headers.entries) {
      request.headers.putIfAbsent(entry.key, () => entry.value);
    }
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
  }
}
