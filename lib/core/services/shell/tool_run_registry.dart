// P1-6: live tool-run output tails.
//
// While `shell_run` executes, its tool card shows the command's recent
// output. This registry is process-lifetime only (no disk, no backup):
// - 50 ms throttled notifications (a chatty npm/ffmpeg build never rebuilds
//   the card per chunk);
// - ANSI CSI stripped and `\r` progress lines replaced (progress bars do not
//   flood the tail);
// - chunk-safe UTF-8 decoding;
// - bounded tail (200 lines / 32 KB) and LRU eviction (200 runs / 8 MB).
//
// Reload / cross-page rendering only sees the persisted final tool event:
// after an app restart the registry is empty, which is the documented
// degradation (tool cards show the final output, no live tail).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

class ToolRun extends ChangeNotifier {
  ToolRun({required this.conversationId, required this.toolCallId}) {
    _decoder = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(_TextSink(_onText));
  }

  static const int maxLines = 200;
  static const int maxBytes = 32 * 1024;

  final String conversationId;
  final String toolCallId;

  final List<String> _lines = <String>[];
  final StringBuffer _partial = StringBuffer();
  late final ByteConversionSink _decoder;
  int _approxBytes = 0;
  bool _truncated = false;
  bool _finished = false;
  Timer? _notifyTimer;

  static final RegExp _csi = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');
  static final RegExp _osc = RegExp(r'\x1B\][^\x07\x1B]*(\x07|\x1B\\)');

  bool get isFinished => _finished;

  bool get truncated => _truncated;

  int get bufferedBytes => _approxBytes;

  void addStdout(List<int> bytes) => _add(bytes);

  void addStderr(List<int> bytes) => _add(bytes);

  /// Most recent output for the collapsed tool card.
  String tail({int lines = 8}) {
    final all = <String>[..._lines];
    final partial = _partial.toString();
    if (partial.isNotEmpty) all.add(partial);
    if (all.length <= lines) return all.join('\n');
    return all.sublist(all.length - lines).join('\n');
  }

  /// Mark the run finished and flush the trailing partial line. The entry is
  /// retained after `finish()` so the final tail remains readable until LRU
  /// pressure evicts it.
  void finish() {
    if (_finished) return;
    final partial = _partial.toString();
    if (partial.isNotEmpty) {
      _lines.add(partial);
      _partial.clear();
    }
    _trim();
    _finished = true;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    notifyListeners();
  }

  void _add(List<int> bytes) {
    if (bytes.isEmpty || _finished) return;
    _decoder.add(bytes);
  }

  void _onText(String text) {
    if (text.isEmpty || _finished) return;
    _approxBytes += text.length;
    final cleaned = text
        .replaceAll(_osc, '')
        .replaceAll(_csi, '')
        .replaceAll('\r\n', '\n');
    for (final rune in cleaned.runes) {
      final char = String.fromCharCode(rune);
      if (char == '\n') {
        _lines.add(_partial.toString());
        _partial.clear();
      } else if (char == '\r') {
        // Carriage return rewrites the current progress line.
        _partial.clear();
      } else {
        _partial.write(char);
      }
    }
    _trim();
    _scheduleNotify();
  }

  void _trim() {
    while (_lines.length > maxLines ||
        (_lines.isNotEmpty && _bufferedBytes > maxBytes)) {
      final removed = _lines.removeAt(0);
      _approxBytes -= removed.length + 1;
      _truncated = true;
    }
    if (_partial.length > maxBytes) {
      final text = _partial.toString();
      _partial.clear();
      _partial.write(text.substring(text.length - maxBytes ~/ 2));
      _truncated = true;
    }
    if (_approxBytes < 0) _approxBytes = 0;
  }

  int get _bufferedBytes =>
      _lines.fold<int>(0, (total, line) => total + line.length + 1) +
      _partial.length;

  void _scheduleNotify() {
    if (_finished || (_notifyTimer?.isActive ?? false)) return;
    _notifyTimer = Timer(const Duration(milliseconds: 50), () {
      _notifyTimer = null;
      if (!_finished) notifyListeners();
    });
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    try {
      _decoder.close();
    } catch (_) {}
    super.dispose();
  }
}

class ToolRunRegistry extends ChangeNotifier {
  ToolRunRegistry._();

  static final ToolRunRegistry instance = ToolRunRegistry._();

  static const int maxRuns = 200;
  static const int maxTotalBytes = 8 * 1024 * 1024;

  final Map<String, ToolRun> _runs = <String, ToolRun>{};

  ToolRun start({required String conversationId, required String toolCallId}) {
    final key = _key(conversationId, toolCallId);
    final existing = _runs.remove(key);
    existing?.dispose();
    final run = ToolRun(conversationId: conversationId, toolCallId: toolCallId);
    _runs[key] = run;
    _evict();
    notifyListeners();
    return run;
  }

  ToolRun? find(String conversationId, String toolCallId) =>
      _runs[_key(conversationId, toolCallId)];

  /// Used by the tool card, which knows the provider call id but not the
  /// conversation id in every layout.
  ToolRun? findByToolCallId(String toolCallId) {
    for (final run in _runs.values) {
      if (run.toolCallId == toolCallId) return run;
    }
    return null;
  }

  void _evict() {
    int totalBytes() =>
        _runs.values.fold<int>(0, (sum, run) => sum + run.bufferedBytes);
    while (_runs.length > maxRuns || totalBytes() > maxTotalBytes) {
      if (_runs.length <= 1) return;
      String? victim;
      for (final entry in _runs.entries) {
        if (entry.value.isFinished) {
          victim = entry.key;
          break;
        }
      }
      victim ??= _runs.keys.first;
      final removed = _runs.remove(victim);
      removed?.dispose();
    }
  }

  static String _key(String conversationId, String toolCallId) =>
      '$conversationId::$toolCallId';
}

class _TextSink implements Sink<String> {
  _TextSink(this._onText);

  final void Function(String text) _onText;

  @override
  void add(String data) => _onText(data);

  @override
  void close() {}
}
