import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;

class JsMcpServerEngine {
  static const int _maxCodeLength = 20000;
  static const int _executionTimeoutMs = 2000;
  bool _closed = false;

  Future<dynamic> handleMessage(dynamic message) async {
    if (_closed) return null;

    if (message is List) {
      final out = <dynamic>[];
      for (final m in message) {
        out.add(await _handleSingle(m));
      }
      return out;
    }
    return await _handleSingle(message);
  }

  Future<Map<String, dynamic>> _handleSingle(dynamic raw) async {
    try {
      if (raw is! Map) {
        return _error(null, code: -32600, message: 'Invalid Request');
      }
      final req = raw.cast<String, dynamic>();
      final id = req['id'];
      final method = (req['method'] ?? '').toString();
      final params = (req['params'] is Map)
          ? (req['params'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};

      switch (method) {
        case mcp.McpProtocol.methodInitialize:
          return _ok(id, result: {
            'serverInfo': {
              'name': 'run-javascript',
              'version': '0.1.0',
            },
            'protocolVersion': mcp.McpProtocol.defaultVersion,
            'capabilities': {
              'tools': {'listChanged': false},
            },
          });

        case mcp.McpProtocol.methodListTools:
          return _ok(id, result: {
            'tools': [
              {
                'name': 'run_javascript',
                'description': 'Execute local JavaScript for math, data processing, and small scripts. No network APIs are available. Prefer a plain expression like `5 + 5` or an IIFE like `(() => Math.pow(2, 10))()`. Top-level `return ...;` is also accepted for convenience.',
                'inputSchema': {
                  'type': 'object',
                  'properties': {
                    'code': {
                      'type': 'string',
                      'description': 'JavaScript code to execute locally. Use a plain expression, an IIFE, or top-level return. Network APIs such as fetch and XMLHttpRequest are disabled.',
                    }
                  },
                  'required': ['code'],
                },
              }
            ],
          });

        case mcp.McpProtocol.methodCallTool:
          final name = (params['name'] ?? '').toString();
          final arguments = (params['arguments'] is Map)
              ? (params['arguments'] as Map).cast<String, dynamic>()
              : <String, dynamic>{};

          if (name == 'run_javascript') {
            final code = (arguments['code'] ?? '').toString();
            return _ok(id, result: await _executeJs(code));
          }
          return _error(id, code: -32101, message: 'Tool not found: $name');

        default:
          if (id == null) return _noop();
          return _error(id, code: -32601, message: 'Method not found: $method');
      }
    } catch (e) {
      return _error(null, code: -32603, message: 'Internal error: $e');
    }
  }

  Future<Map<String, dynamic>> _executeJs(String code) async {
    JavascriptRuntime? jsRuntime;
    try {
      final guardError = _validateCode(code);
      if (guardError != null) {
        return _toolResult('Rejected: $guardError', isError: true);
      }

      jsRuntime = _createRuntime();
      final jsResult = _evaluateWithReturnFallback(jsRuntime, code);

      if (jsResult.isError) {
        return _toolResult('Error: ${jsResult.stringResult}', isError: true);
      }

      return _toolResult(jsResult.stringResult, isError: false);
    } catch (e) {
      return _toolResult('Execution Error: $e', isError: true);
    } finally {
      try {
        jsRuntime?.dispose();
      } catch (_) {}
    }
  }

  JavascriptRuntime _createRuntime() {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      return QuickJsRuntime2(
        timeout: _executionTimeoutMs,
        stackSize: 1024 * 1024,
      );
    }
    return getJavascriptRuntime(xhr: false);
  }

  JsEvalResult _evaluateWithReturnFallback(JavascriptRuntime runtime, String code) {
    final trimmed = code.trim();
    final direct = runtime.evaluate(trimmed);
    if (!direct.isError) return direct;

    final errorText = direct.stringResult.toLowerCase();
    final mayBeTopLevelReturn = errorText.contains('return') || trimmed.contains(RegExp(r'\breturn\b'));
    if (!mayBeTopLevelReturn) return direct;

    final wrapped = '''
(() => {
$trimmed
})()
''';
    return runtime.evaluate(wrapped);
  }

  String? _validateCode(String code) {
    final trimmed = code.trim();
    if (trimmed.isEmpty) return 'code is empty';
    if (trimmed.length > _maxCodeLength) {
      return 'code is too long. Keep snippets under $_maxCodeLength characters.';
    }

    final lower = trimmed.toLowerCase();
    final blocked = <String>[
      'fetch(',
      'xmlhttprequest',
      'websocket',
      'import(',
      'while(true',
      'while (true',
      'for(;;',
      'for (;;',
    ];
    for (final pattern in blocked) {
      if (lower.contains(pattern)) {
        return 'disallowed JavaScript pattern: $pattern';
      }
    }
    return null;
  }

  Map<String, dynamic> _toolResult(String text, {required bool isError}) {
    return {
      'content': [
        {'type': 'text', 'text': text}
      ],
      'isStreaming': false,
      'isError': isError,
    };
  }

  void close() {
    if (_closed) return;
    _closed = true;
  }

  Map<String, dynamic> _ok(dynamic id, {required Map<String, dynamic> result}) {
    return {
      'jsonrpc': '2.0',
      if (id != null) 'id': id,
      'result': result,
    };
  }

  Map<String, dynamic> _error(dynamic id, {required int code, required String message}) {
    return {
      'jsonrpc': '2.0',
      if (id != null) 'id': id,
      'error': {'code': code, 'message': message},
    };
  }

  Map<String, dynamic> _noop() => {'jsonrpc': '2.0'};
}

class JsInMemoryClientTransport implements mcp.ClientTransport {
  final JsMcpServerEngine _server;
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  bool _closed = false;

  JsInMemoryClientTransport(this._server);

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    if (_closed) return;
    Future.microtask(() async {
      final resp = await _server.handleMessage(message);
      if (_closed) return;
      if (resp != null) {
        _messageController.add(resp);
      }
    });
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _server.close();
    } catch (_) {}
    if (!_messageController.isClosed) _messageController.close();
    if (!_closeCompleter.isCompleted) _closeCompleter.complete();
  }
}
