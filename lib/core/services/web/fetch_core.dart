// Web fetch transmission core (WEB_FETCH_PLAN.md §5.3, §5.5, §5.7–5.8).
//
// One HTTP implementation for every fetch path:
//   * SsrfGuard on every hop
//   * 2 MB download cap (16 MB for PDFs), 30 s total / 10 s connect timeout
//   * concurrency 2, queue 50
//   * 429 / 5xx retry with exponential backoff and Retry-After
//   * manual redirect handling (301/302/303/307/308)
//   * charset-aware decoding and content-type routing

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../chat/document_text_extractor.dart';
import 'charset_decoder.dart';
import 'content_extractor.dart';
import 'ssrf_guard.dart';

/// One fetch request as decided by the tool layer.
class FetchRequest {
  const FetchRequest({
    required this.url,
    this.method = 'GET',
    this.headers = const <String, String>{},
    this.body,
    this.raw = false,
    this.selector,
  });

  final Uri url;
  final String method;
  final Map<String, String> headers;
  final String? body;
  final bool raw;
  final String? selector;
}

/// Page metadata surfaced in the tool output header.
class FetchMetadata {
  const FetchMetadata({
    this.title,
    this.description,
    this.siteName,
    this.language,
    this.publishedTime,
  });

  final String? title;
  final String? description;
  final String? siteName;
  final String? language;
  final String? publishedTime;

  factory FetchMetadata.fromHtml(HtmlMetadata metadata) => FetchMetadata(
    title: metadata.title,
    description: metadata.description,
    siteName: metadata.siteName,
    language: metadata.language,
    publishedTime: metadata.publishedTime,
  );
}

class FetchResult {
  const FetchResult({
    required this.url,
    required this.finalUrl,
    required this.status,
    required this.contentType,
    required this.charset,
    required this.charsetFallback,
    required this.content,
    required this.metadata,
    required this.truncated,
    required this.bytes,
  });

  final Uri url;
  final Uri finalUrl;
  final int status;
  final String? contentType;
  final String charset;
  final bool charsetFallback;
  final String content;
  final FetchMetadata metadata;
  final bool truncated;
  final int bytes;
}

/// A fetch failure with the machine-readable code from the error contract.
class FetchException implements Exception {
  const FetchException(
    this.code,
    this.message, {
    this.status,
    this.bodySnippet,
    this.uri,
  });

  final String code;
  final String message;
  final int? status;
  final String? bodySnippet;
  final Uri? uri;

  @override
  String toString() => message;
}

class FetchCore {
  FetchCore({
    http.Client? client,
    SsrfGuard? guard,
    Future<void> Function(Duration duration)? sleep,
    DateTime Function()? clock,
  }) : _client = client,
       _guard = guard ?? SsrfGuard(),
       _sleep = sleep ?? ((duration) => Future<void>.delayed(duration)),
       _clock = clock ?? DateTime.now;

  static const String browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static const int maxDownloadBytes = 2 * 1024 * 1024;
  static const int maxPdfDownloadBytes = 16 * 1024 * 1024;
  static const Duration totalTimeout = Duration(seconds: 30);
  static const Duration connectTimeout = Duration(seconds: 10);
  static const int maxConcurrentFetches = 2;
  static const int maxQueuedFetches = 50;
  static const int maxRedirects = 5;

  /// Extracted content is capped at this many characters.
  static const int maxExtractedChars = 200000;

  /// HTML above this size is parsed in a background isolate so a heavy page
  /// cannot jank the UI (WEB_FETCH_PLAN.md §5.6).
  static const int computeIsolateThresholdChars = 64 * 1024;

  static const Duration extractionTimeout = Duration(seconds: 15);

  static const Set<String> _deniedHeaders = <String>{
    'host',
    'content-length',
    'connection',
    'transfer-encoding',
    'upgrade',
    'accept-encoding',
    'user-agent',
    'proxy-connection',
    'proxy-authorization',
  };

  /// Browser-like defaults. Some sites reject requests that only carry a
  /// User-Agent but omit Accept / Accept-Language / Fetch Metadata headers.
  static const Map<String, String> _browserHeaders = <String, String>{
    'User-Agent': browserUserAgent,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,'
        'image/avif,image/webp,*/*;q=0.8',
    'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
    'Cache-Control': 'no-cache',
    'Pragma': 'no-cache',
    'Sec-Fetch-Dest': 'document',
    'Sec-Fetch-Mode': 'navigate',
    'Sec-Fetch-Site': 'none',
    'Sec-Fetch-User': '?1',
    'Upgrade-Insecure-Requests': '1',
  };

  static const Set<int> _retryStatuses = <int>{429, 500, 502, 503, 504};
  static const List<Duration> _retryDelays = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
  ];

  static http.Client? _sharedClient;
  static int _activeFetches = 0;
  static final List<Completer<void>> _fetchWaiters = <Completer<void>>[];

  http.Client? _client;
  final SsrfGuard _guard;
  final Future<void> Function(Duration duration) _sleep;
  final DateTime Function() _clock;
  final math.Random _random = math.Random();

  http.Client get _httpClient => _client ??= _createSharedClient();

  static http.Client _createSharedClient() {
    _sharedClient ??= http.Client();
    return _sharedClient!;
  }

  /// Fetch [request], applying concurrency, timeout and all guardrails.
  Future<FetchResult> fetch(FetchRequest request) async {
    return _withQueue(() async {
      try {
        return await _fetch(request).timeout(totalTimeout);
      } on TimeoutException {
        throw FetchException(
          'timeout',
          'The request timed out after ${totalTimeout.inSeconds} seconds.',
          uri: request.url,
        );
      }
    });
  }

  Future<T> _withQueue<T>(Future<T> Function() task) async {
    while (_activeFetches >= maxConcurrentFetches) {
      if (_fetchWaiters.length >= maxQueuedFetches) {
        throw const FetchException(
          'network_error',
          'Too many pending fetch requests.',
        );
      }
      final completer = Completer<void>();
      _fetchWaiters.add(completer);
      await completer.future;
    }
    _activeFetches++;
    try {
      return await task();
    } finally {
      _activeFetches--;
      if (_fetchWaiters.isNotEmpty) {
        _fetchWaiters.removeAt(0).complete();
      }
    }
  }

  Future<FetchResult> _fetch(FetchRequest request) async {
    _validateUri(request.url);

    var currentUrl = request.url;
    var method = request.method.toUpperCase();
    var bodyBytes = request.body == null
        ? null
        : Uint8List.fromList(utf8.encode(request.body!));

    for (var redirects = 0; redirects <= maxRedirects; redirects++) {
      final block = await _guard.check(currentUrl);
      if (block != null) {
        throw FetchException('blocked_private_address', block.reason,
            uri: currentUrl);
      }

      final response = await _sendWithRetry(
        url: currentUrl,
        method: method,
        headers: request.headers,
        bodyBytes: bodyBytes,
      );

      final status = response.statusCode;
      final location = response.headers['location'];
      if (_isRedirect(status) && (location ?? '').isNotEmpty) {
        await _drain(response);
        if (redirects == maxRedirects) {
          throw FetchException(
            'too_many_redirects',
            'The request exceeded $maxRedirects redirects.',
            uri: currentUrl,
          );
        }
        final nextUrl = currentUrl.resolve(location!.trim());
        _validateUri(nextUrl);
        final sameOrigin = nextUrl.origin == currentUrl.origin;

        if (status == 303) {
          method = 'GET';
          bodyBytes = null;
        } else if (status == 301 || status == 302) {
          if (method == 'POST') {
            throw FetchException(
              'redirect_method_change',
              'The server redirected a POST request to a different URL. '
                  'POST requests are not followed across redirects; retry '
                  'against the redirect target with method=GET if that is '
                  'what the API expects.',
              status: status,
              uri: nextUrl,
            );
          }
          method = 'GET';
        }
        // 307 / 308 preserve method and body.

        var forwardedHeaders = request.headers;
        if (!sameOrigin) {
          // Do not leak custom credentials (X-API-Key, Referer, …) to a
          // different origin. Only content-negotiation headers survive.
          forwardedHeaders = <String, String>{
            for (final entry in request.headers.entries)
              if (const <String>{
                'accept',
                'accept-language',
              }.contains(entry.key.toLowerCase()))
                entry.key: entry.value,
          };
        }
        currentUrl = nextUrl;
        request = FetchRequest(
          url: request.url,
          method: method,
          headers: forwardedHeaders,
          body: bodyBytes == null ? null : utf8.decode(bodyBytes),
          raw: request.raw,
          selector: request.selector,
        );
        continue;
      }

      if (status < 200 || status >= 300) {
        final snippet = await _readSnippet(response);
        throw FetchException(
          'http_error',
          'The server returned HTTP $status.',
          status: status,
          bodySnippet: snippet,
          uri: currentUrl,
        );
      }

      final bytes = await _readBounded(response, contentType: response.headers['content-type']);
      return await _route(
        originalUrl: request.url,
        finalUrl: currentUrl,
        status: status,
        contentType: response.headers['content-type'],
        bytes: bytes,
        raw: request.raw,
        selector: request.selector,
      );
    }
    throw FetchException(
      'too_many_redirects',
      'The request exceeded $maxRedirects redirects.',
      uri: currentUrl,
    );
  }

  void _validateUri(Uri uri) {
    if (!uri.hasScheme || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw FetchException(
        'invalid_url',
        'Only http:// and https:// URLs are supported.',
        uri: uri,
      );
    }
    if (uri.host.trim().isEmpty) {
      throw FetchException('invalid_url', 'The URL has no host.', uri: uri);
    }
  }

  Future<http.StreamedResponse> _sendWithRetry({
    required Uri url,
    required String method,
    required Map<String, String> headers,
    required Uint8List? bodyBytes,
  }) async {
    var attempt = 0;
    while (true) {
      final streamed = await _sendOnce(
        url: url,
        method: method,
        headers: headers,
        bodyBytes: bodyBytes,
      );
      if (!_retryStatuses.contains(streamed.statusCode) ||
          attempt >= _retryDelays.length ||
          (method != 'GET' && method != 'HEAD')) {
        // Retrying a POST on 5xx/429 may repeat a side effect (order, charge…).
        return streamed;
      }

      final retryAfter = _parseRetryAfter(streamed.headers['retry-after']);
      await _drain(streamed);
      final base = _retryDelays[attempt];
      final jitter =
          0.8 + _random.nextDouble() * 0.4; // ±20%
      final delay = retryAfter ?? base * jitter;
      attempt++;
      await _sleep(delay);
    }
  }

  Future<http.StreamedResponse> _sendOnce({
    required Uri url,
    required String method,
    required Map<String, String> headers,
    required Uint8List? bodyBytes,
  }) async {
    final request = http.Request(method, url)
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers.addAll(_browserHeaders);

    headers.forEach((key, value) {
      if (_deniedHeaders.contains(key.toLowerCase())) return;
      request.headers[key] = value;
    });
    if (bodyBytes != null) {
      request.bodyBytes = bodyBytes;
      final hasContentType = request.headers.keys.any(
        (key) => key.toLowerCase() == 'content-type',
      );
      if (!hasContentType) {
        request.headers['Content-Type'] = _looksLikeJsonBody(bodyBytes)
            ? 'application/json'
            : 'text/plain; charset=utf-8';
      }
    }

    try {
      return await _httpClient.send(request).timeout(connectTimeout);
    } on TimeoutException {
      throw FetchException(
        'timeout',
        'The connection timed out after ${connectTimeout.inSeconds} seconds.',
        uri: url,
      );
    } on SocketException catch (e) {
      throw FetchException('network_error', e.message, uri: url);
    } on http.ClientException catch (e) {
      throw FetchException('network_error', e.message, uri: url);
    } on HandshakeException catch (e) {
      throw FetchException('network_error', e.message, uri: url);
    }
  }

  Future<Uint8List> _readBounded(
    http.StreamedResponse response, {
    String? contentType,
  }) async {
    final declaredPdf = _isPdfContentType(contentType);
    var cap = declaredPdf ? maxPdfDownloadBytes : maxDownloadBytes;
    final builder = BytesBuilder(copy: false);
    var received = false;
    var sniffedPdf = declaredPdf;
    await for (final chunk in response.stream.handleError((
      Object error,
      StackTrace stack,
    ) {
      // dart:io's HTTP/1.1 parser does not consume trailing headers. Fastly /
      // Hearst-style responses end with `Trailer: server-timing`, which throws
      // after the final body byte (e.g. "115 does not match 13"). The payload
      // is already complete, so keep it for text content instead of failing.
      if (received && !declaredPdf && _isIgnorableTrailerError(error)) {
        return;
      }
      Error.throwWithStackTrace(error, stack);
    })) {
      received = true;
      builder.add(chunk);
      if (!sniffedPdf && builder.length >= 5) {
        sniffedPdf = true;
        if (_hasPdfMagic(builder.toBytes())) {
          cap = maxPdfDownloadBytes;
        }
      }
      if (builder.length > cap) {
        throw FetchException(
          'response_too_large',
          'The response exceeded the ${cap ~/ (1024 * 1024)} MB download limit.',
          status: response.statusCode,
          uri: response.request?.url,
        );
      }
    }
    return builder.takeBytes();
  }

  Future<void> _drain(http.StreamedResponse response) async {
    try {
      await response.stream.drain<void>();
    } catch (_) {}
  }

  Future<String> _readSnippet(http.StreamedResponse response) async {
    final bytes = <int>[];
    try {
      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        if (bytes.length >= 1024) break;
      }
    } catch (_) {}
    final head = bytes.length > 1024 ? bytes.sublist(0, 1024) : bytes;
    return CharsetDecoder.decode(
      Uint8List.fromList(head),
      contentType: response.headers['content-type'],
    ).text.trim();
  }

  Future<FetchResult> _route({
    required Uri originalUrl,
    required Uri finalUrl,
    required int status,
    required String? contentType,
    required Uint8List bytes,
    required bool raw,
    required String? selector,
  }) async {
    final mediaType = _mediaType(contentType);
    if (bytes.isEmpty && (status == 204 || status == 205)) {
      return _textResult(
        originalUrl: originalUrl,
        finalUrl: finalUrl,
        status: status,
        contentType: contentType,
        decoded: CharsetDecoder.decode(bytes, contentType: contentType),
        bytes: bytes,
        content: '',
        truncated: false,
      );
    }
    final isPdf = mediaType == 'application/pdf' || _hasPdfMagic(bytes);

    // Decide binary handling BEFORE decoding: running the charset sniffers
    // over megabytes of PDF/image bytes is pure waste.
    if (isPdf) {
      if (raw) {
        throw FetchException(
          'unsupported_binary',
          'This URL returned a PDF; use raw=false to read its text.',
          status: status,
          uri: finalUrl,
        );
      }
      return _routePdf(
        originalUrl: originalUrl,
        finalUrl: finalUrl,
        status: status,
        contentType: contentType,
        bytes: bytes,
      );
    }
    if (_isBinaryMediaType(mediaType)) {
      throw FetchException(
        'unsupported_binary',
        'This URL returned unsupported binary content '
            '(${contentType ?? 'no content type'}, ${bytes.length} bytes).',
        status: status,
        uri: finalUrl,
      );
    }

    final decoded = CharsetDecoder.decode(bytes, contentType: contentType);
    final text = decoded.text;

    if (raw) {
      final capped = _capText(text);
      return FetchResult(
        url: originalUrl,
        finalUrl: finalUrl,
        status: status,
        contentType: contentType,
        charset: decoded.charset,
        charsetFallback: decoded.charsetFallback,
        content: capped.value,
        metadata: const FetchMetadata(),
        truncated: capped.truncated,
        bytes: bytes.length,
      );
    }

    final looksHtml =
        mediaType == 'text/html' ||
        mediaType == 'application/xhtml+xml' ||
        (mediaType.isEmpty && _looksLikeHtml(text));

    if (looksHtml) {
      final extracted = await _extractHtml(
        text,
        selector: selector,
        status: status,
        uri: finalUrl,
      );
      if (!extracted.ok) {
        throw FetchException(
          extracted.errorCode!,
          extracted.errorMessage ?? 'The page contained no readable text.',
          status: status,
          uri: finalUrl,
        );
      }
      final capped = _capText(extracted.markdown);
      return FetchResult(
        url: originalUrl,
        finalUrl: finalUrl,
        status: status,
        contentType: contentType,
        charset: decoded.charset,
        charsetFallback: decoded.charsetFallback,
        content: capped.value,
        metadata: FetchMetadata.fromHtml(extracted.metadata),
        truncated: capped.truncated,
        bytes: bytes.length,
      );
    }

    if (mediaType == 'application/json' || mediaType.endsWith('+json')) {
      final capped = _capText(HtmlExtractor.formatJson(text));
      return _textResult(
        originalUrl: originalUrl,
        finalUrl: finalUrl,
        status: status,
        contentType: contentType,
        decoded: decoded,
        bytes: bytes,
        content: capped.value,
        truncated: capped.truncated,
      );
    }

    if (mediaType == 'text/markdown' || mediaType == 'text/x-markdown') {
      final capped = _capText(HtmlExtractor.stripFrontmatter(text));
      return _textResult(
        originalUrl: originalUrl,
        finalUrl: finalUrl,
        status: status,
        contentType: contentType,
        decoded: decoded,
        bytes: bytes,
        content: capped.value,
        truncated: capped.truncated,
      );
    }

    if (_isTextMediaType(mediaType)) {
      final capped = _capText(HtmlExtractor.normalizePlainText(text));
      return _textResult(
        originalUrl: originalUrl,
        finalUrl: finalUrl,
        status: status,
        contentType: contentType,
        decoded: decoded,
        bytes: bytes,
        content: capped.value,
        truncated: capped.truncated,
      );
    }

    if (mediaType.isEmpty && text.trim().isNotEmpty) {
      final capped = _capText(HtmlExtractor.normalizePlainText(text));
      return _textResult(
        originalUrl: originalUrl,
        finalUrl: finalUrl,
        status: status,
        contentType: contentType,
        decoded: decoded,
        bytes: bytes,
        content: capped.value,
        truncated: capped.truncated,
      );
    }

    throw FetchException(
      'unsupported_binary',
      'This URL returned unsupported binary content '
          '(${contentType ?? 'no content type'}, ${bytes.length} bytes).',
      status: status,
      uri: finalUrl,
    );
  }

  /// Parses HTML off the UI isolate when the document is large enough to
  /// matter. Isolate startup failures fall back to a synchronous parse instead
  /// of failing the fetch; a timeout is surfaced as a fetch timeout.
  Future<HtmlExtractionResult> _extractHtml(
    String text, {
    required String? selector,
    required int status,
    required Uri uri,
  }) async {
    if (text.length < computeIsolateThresholdChars) {
      return HtmlExtractor.extract(text, selector: selector);
    }
    try {
      return await Isolate.run(
        () => HtmlExtractor.extract(text, selector: selector),
      ).timeout(extractionTimeout);
    } on TimeoutException {
      throw FetchException(
        'timeout',
        'Content extraction timed out after '
            '${extractionTimeout.inSeconds} seconds.',
        status: status,
        uri: uri,
      );
    } catch (_) {
      return HtmlExtractor.extract(text, selector: selector);
    }
  }

  FetchResult _routePdf({
    required Uri originalUrl,
    required Uri finalUrl,
    required int status,
    required String? contentType,
    required Uint8List bytes,
  }) {
    final DocumentExtractionResult extracted;
    try {
      extracted = DocumentTextExtractor.extractPdfBytes(
        bytes,
        maxOutputBytes: maxExtractedChars,
      );
    } on DocumentExtractionException catch (e) {
      throw FetchException(
        'unsupported_content_type',
        e.message,
        status: status,
        uri: finalUrl,
      );
    }
    final text = extracted.text.isEmpty
        ? (extracted.notice ?? 'The PDF contains no extractable text.')
        : extracted.text;
    final capped = _capText(text);
    return FetchResult(
      url: originalUrl,
      finalUrl: finalUrl,
      status: status,
      contentType: contentType,
      charset: 'binary',
      charsetFallback: false,
      content: capped.value,
      metadata: const FetchMetadata(),
      truncated: extracted.truncated || capped.truncated,
      bytes: bytes.length,
    );
  }

  FetchResult _textResult({
    required Uri originalUrl,
    required Uri finalUrl,
    required int status,
    required String? contentType,
    required DecodedBody decoded,
    required Uint8List bytes,
    required String content,
    required bool truncated,
  }) {
    return FetchResult(
      url: originalUrl,
      finalUrl: finalUrl,
      status: status,
      contentType: contentType,
      charset: decoded.charset,
      charsetFallback: decoded.charsetFallback,
      content: content,
      metadata: const FetchMetadata(),
      truncated: truncated,
      bytes: bytes.length,
    );
  }

  ({String value, bool truncated}) _capText(String text) {
    if (text.length <= maxExtractedChars) {
      return (value: text, truncated: false);
    }
    var end = maxExtractedChars;
    if (end > 0 &&
        end < text.length &&
        _isLowSurrogate(text.codeUnitAt(end))) {
      end--;
    }
    return (value: text.substring(0, end), truncated: true);
  }

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  static String _mediaType(String? contentType) {
    if (contentType == null) return '';
    final semi = contentType.indexOf(';');
    return (semi < 0 ? contentType : contentType.substring(0, semi))
        .trim()
        .toLowerCase();
  }

  static bool _isPdfContentType(String? contentType) =>
      _mediaType(contentType) == 'application/pdf';

  static bool _looksLikeJsonBody(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    final text = utf8.decode(bytes, allowMalformed: true).trimLeft();
    return text.startsWith('{') || text.startsWith('[');
  }

  static bool _isIgnorableTrailerError(Object error) {
    // Dart's HTTP/1.1 parser fails on a trailing-header block after the body
    // (e.g. "115 does not match 13"). Keep the match narrow: a different
    // parse failure mid-stream must not be silently accepted as a complete
    // body. This is only consulted after at least one chunk arrived.
    final text = error.toString().toLowerCase();
    return text.contains('failed to parse http') &&
        text.contains('does not match');
  }

  static bool _hasPdfMagic(Uint8List bytes) {
    if (bytes.length < 5) return false;
    return bytes[0] == 0x25 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x44 &&
        bytes[3] == 0x46 &&
        bytes[4] == 0x2D;
  }

  static bool _looksLikeHtml(String head) {
    final probe = head.length > 256 ? head.substring(0, 256) : head;
    final lower = probe.toLowerCase();
    return lower.contains('<html') || lower.contains('<!doctype html');
  }

  static bool _isTextMediaType(String mediaType) {
    if (mediaType.isEmpty) return false;
    if (mediaType.startsWith('text/')) return true;
    if (mediaType == 'application/xml' ||
        mediaType == 'application/xhtml+xml' ||
        mediaType == 'application/rss+xml' ||
        mediaType == 'application/atom+xml' ||
        mediaType == 'application/javascript' ||
        mediaType == 'application/ecmascript' ||
        mediaType == 'application/yaml' ||
        mediaType == 'application/x-yaml' ||
        mediaType == 'application/ld+json') {
      return true;
    }
    return mediaType.endsWith('+xml');
  }

  static bool _isBinaryMediaType(String mediaType) {
    if (mediaType.isEmpty) return false;
    if (mediaType.startsWith('image/') ||
        mediaType.startsWith('audio/') ||
        mediaType.startsWith('video/') ||
        mediaType.startsWith('font/')) {
      return true;
    }
    return mediaType == 'application/octet-stream' ||
        mediaType == 'application/zip' ||
        mediaType == 'application/gzip' ||
        mediaType == 'application/x-gzip' ||
        mediaType == 'application/x-tar' ||
        mediaType == 'application/msword' ||
        mediaType == 'application/vnd.ms-excel' ||
        mediaType == 'application/vnd.ms-powerpoint' ||
        mediaType.contains('officedocument') ||
        mediaType == 'application/wasm' ||
        mediaType == 'application/pdf';
  }

  Duration? _parseRetryAfter(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final seconds = int.tryParse(raw.trim());
    if (seconds != null && seconds >= 0) {
      return Duration(seconds: seconds);
    }
    try {
      final date = HttpDate.parse(raw.trim());
      final delta = date.difference(_clock());
      if (delta.isNegative) return Duration.zero;
      return delta;
    } catch (_) {
      return null;
    }
  }
}
