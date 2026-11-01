import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../utils/app_directories.dart';

class RequestLogger {
  RequestLogger._();

  static bool _enabled = false;
  static bool get enabled => _enabled;
  static bool _writeErrorReported = false;

  static int _nextRequestId = 0;
  static int nextRequestId() => ++_nextRequestId;

  static Future<void> setEnabled(bool v) async {
    if (_enabled == v) return;
    _enabled = v;
    if (!v) {
      try {
        await _sink?.flush();
      } catch (_) {}
      try {
        await _sink?.close();
      } catch (_) {}
      _sink = null;
      _sinkDate = null;
    } else {
      _writeErrorReported = false;
    }
  }

  static IOSink? _sink;
  static DateTime? _sinkDate;
  static Future<void> _writeQueue = Future<void>.value();

  static String _two(int v) => v.toString().padLeft(2, '0');
  static DateTime _dayOf(DateTime dt) => DateTime(dt.year, dt.month, dt.day);
  static String _formatDate(DateTime dt) => '${dt.year}-${_two(dt.month)}-${_two(dt.day)}';
  static String _formatTs(DateTime dt) {
    return '${_formatDate(dt)} ${_two(dt.hour)}:${_two(dt.minute)}:${_two(dt.second)}.${dt.millisecond.toString().padLeft(3, '0')}';
  }

  static Future<IOSink> _ensureSink() async {
    final now = DateTime.now();
    final today = _dayOf(now);
    if (_sink != null && _sinkDate == today) return _sink!;

    try {
      await _sink?.flush();
    } catch (_) {}
    try {
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    _sinkDate = today;

    final dir = await AppDirectories.getAppDataDirectory();
    final logsDir = Directory('${dir.path}/logs');
    if (!await logsDir.exists()) {
      await logsDir.create(recursive: true);
    }

    final active = File('${logsDir.path}/logs.txt');
    if (await active.exists()) {
      try {
        final stat = await active.stat();
        final fileDay = _dayOf(stat.modified.toLocal());
        if (fileDay != today) {
          final suffix = _formatDate(fileDay);
          var rotated = File('${logsDir.path}/logs_$suffix.txt');
          if (await rotated.exists()) {
            int i = 1;
            while (await File('${logsDir.path}/logs_${suffix}_$i.txt').exists()) {
              i++;
            }
            rotated = File('${logsDir.path}/logs_${suffix}_$i.txt');
          }
          await active.rename(rotated.path);
        }
      } catch (_) {}
    }

    _sink = active.openWrite(mode: FileMode.append);
    return _sink!;
  }

  static void logLine(String line) {
    if (!_enabled) return;
    final now = DateTime.now();
    final text = '[${_formatTs(now)}] $line\n';
    _writeQueue = _writeQueue.then((_) async {
      if (!_enabled) return;
      try {
        final sink = await _ensureSink();
        sink.write(text);
        await sink.flush();
      } catch (_) {
        try {
          await _sink?.flush();
        } catch (_) {}
        try {
          await _sink?.close();
        } catch (_) {}
        _sink = null;
        _sinkDate = null;
        if (!_writeErrorReported) {
          _writeErrorReported = true;
          try {
            stderr.writeln('[RequestLogger] write failed; further write errors will be suppressed.');
          } catch (_) {}
        }
      }
    });
  }

  static String encodeObject(Object? obj) {
    try {
      return const JsonEncoder.withIndent('  ').convert(obj);
    } catch (_) {
      return obj?.toString() ?? '';
    }
  }

  /// Headers that must never be written to the request log. `web_fetch`
  /// explicitly supports authorization/cookie headers, and provider requests
  /// carry API keys, so log the shape without the secret values.
  static Map<String, String> redactHeaders(Map<String, String> headers) {
    const sensitive = <String>{
      'authorization',
      'cookie',
      'set-cookie',
      'proxy-authorization',
      'x-api-key',
      'api-key',
      'x-auth-token',
      'x-goog-api-key',
      // OAuth identity headers (session/account/conversation ids). The OAuth
      // body is redacted separately; the headers carry the same identifiers.
      'session_id',
      'conversation_id',
      'x-client-request-id',
      'x-claude-code-session-id',
      'chatgpt-account-id',
      // Kimi CLI device identity. The id is stable per install/account and is
      // as sensitive as the other OAuth session identifiers (plan C5).
      'x-msh-device-id',
      'x-msh-access-token',
      'x-msh-sign',
    };
    return <String, String>{
      for (final entry in headers.entries)
        entry.key: sensitive.contains(entry.key.toLowerCase())
            ? '***'
            : entry.value,
    };
  }

  /// Keys that carry OAuth session / account identity. Only redacted for
  /// OAuth providers (`DioHttpClient.redactSensitiveBody`), so logs for every
  /// other provider stay byte-identical (plan C5).
  static const Set<String> oauthSensitiveKeys = <String>{
    'metadata',
    'user_id',
    'session_id',
    'conversation_id',
    'prompt_cache_key',
    'x_client_request_id',
    'x-client-request-id',
    'device_id',
    'account_uuid',
    'chatgpt-account-id',
    // Token exchange / refresh payloads (auth endpoints use the same logger).
    'access_token',
    'refresh_token',
    'id_token',
    'code',
    'code_verifier',
    'device_auth_id',
    'user_code',
  };

  /// Masks OAuth identity fields in a JSON body and hides form-encoded auth
  /// payloads entirely. Every other shape is replaced with a marker: an OAuth
  /// request body may only be JSON or an `x-www-form-urlencoded` token grant,
  /// and malformed text must not be assumed safe to log.
  static String redactOAuthBody(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return body;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map || decoded is List) {
        final redacted = _redactOAuthValue(decoded);
        return const JsonEncoder.withIndent('  ').convert(redacted);
      }
    } catch (_) {}
    // Token exchange/refresh use form encoding for ChatGPT; those values are
    // authorization codes, PKCE verifiers and refresh tokens. Keep the keys
    // for diagnosis, never the values.
    if (trimmed.contains('=') && !trimmed.contains('{')) {
      try {
        final params = Uri.splitQueryString(trimmed);
        if (params.isNotEmpty) {
          return params.keys.map((key) => '$key=***').join('&');
        }
      } catch (_) {}
    }
    return '[redacted oauth body]';
  }

  static Object? _redactOAuthValue(Object? value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString():
              oauthSensitiveKeys.contains(entry.key.toString().toLowerCase())
              ? '***'
              : _redactOAuthValue(entry.value),
      };
    }
    if (value is List) {
      return <Object?>[for (final item in value) _redactOAuthValue(item)];
    }
    return value;
  }

  static String safeDecodeUtf8(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  static String escape(String input) {
    return input
        .replaceAll('\\', r'\\')
        .replaceAll('\r', r'\r')
        .replaceAll('\n', r'\n')
        .replaceAll('\t', r'\t');
  }
}
