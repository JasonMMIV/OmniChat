import 'dart:convert';

/// A connection-test failure with enough structure for the UI to explain
/// *what* the provider rejected instead of dumping `Exception: ...`.
class ProviderTestFailure {
  const ProviderTestFailure({
    this.statusCode,
    this.reasonPhrase,
    required this.message,
    this.detail = '',
    this.requestUrl,
  });

  final int? statusCode;
  final String? reasonPhrase;

  /// Short human-readable cause (provider error message or transport error).
  final String message;

  /// Full response body / transport text, shown behind a details affordance.
  final String detail;
  final String? requestUrl;

  String? get httpLabel {
    if (statusCode == null) return null;
    final reason = reasonPhrase;
    return reason == null || reason.isEmpty
        ? 'HTTP $statusCode'
        : 'HTTP $statusCode $reason';
  }

  static ProviderTestFailure parse(Object error, {String? requestUrl}) {
    final raw = error.toString().trim();
    final match = RegExp(
      r'HTTP\s+(\d{3})\s*:?\s*(.*)',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(raw);
    if (match == null) {
      final cleaned = raw
          .replaceFirst(RegExp(r'^(Exception|HttpException|Error):\s*'), '')
          .trim();
      return ProviderTestFailure(
        message: cleaned.isEmpty ? raw : cleaned,
        detail: cleaned,
        requestUrl: requestUrl,
      );
    }

    final status = int.tryParse(match.group(1) ?? '');
    final body = (match.group(2) ?? '').trim();
    final providerMessage = _providerMessage(body);
    return ProviderTestFailure(
      statusCode: status,
      reasonPhrase: status == null ? null : _reasonPhrase(status),
      message: providerMessage.isEmpty
          ? (body.isEmpty ? 'HTTP error' : body)
          : providerMessage,
      detail: body.isEmpty ? raw : body,
      requestUrl: requestUrl,
    );
  }

  static String _providerMessage(String body) {
    if (body.isEmpty) return '';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          for (final key in const ['message', 'detail', 'type']) {
            final value = error[key];
            if (value is String && value.trim().isNotEmpty) {
              return value.trim();
            }
          }
        }
        for (final key in const ['message', 'detail', 'error_description']) {
          final value = decoded[key];
          if (value is String && value.trim().isNotEmpty) {
            return value.trim();
          }
        }
        if (error is String && error.trim().isNotEmpty) return error.trim();
      }
    } catch (_) {}
    final firstLine = body.split('\n').first.trim();
    if (firstLine.length <= 320) return firstLine;
    return '${firstLine.substring(0, 320)}…';
  }

  static String _reasonPhrase(int status) {
    return switch (status) {
      400 => 'Bad Request',
      401 => 'Unauthorized',
      402 => 'Payment Required',
      403 => 'Forbidden',
      404 => 'Not Found',
      405 => 'Method Not Allowed',
      408 => 'Request Timeout',
      409 => 'Conflict',
      413 => 'Payload Too Large',
      415 => 'Unsupported Media Type',
      422 => 'Unprocessable Entity',
      429 => 'Too Many Requests',
      500 => 'Internal Server Error',
      501 => 'Not Implemented',
      502 => 'Bad Gateway',
      503 => 'Service Unavailable',
      504 => 'Gateway Timeout',
      _ => '',
    };
  }
}
