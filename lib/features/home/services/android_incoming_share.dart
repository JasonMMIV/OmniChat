import 'dart:async';

import 'package:flutter/services.dart';

/// Bridge for share payloads copied by Android while its URI grants are valid.
class AndroidIncomingShare {
  AndroidIncomingShare._();

  static const MethodChannel _channel = MethodChannel(
    'omnichat/incoming_share',
  );
  static final StreamController<void> _changes =
      StreamController<void>.broadcast();
  static bool _initialized = false;

  static void ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onIncomingSharesChanged') {
        _changes.add(null);
      }
    });
  }

  static Stream<void> get changes => _changes.stream;

  /// Appends shared text to the existing draft without overwriting what the
  /// user was already writing: an empty draft takes the text as is, otherwise
  /// it lands on a new line. Returns [current] unchanged for empty input.
  static String mergeShareText(String current, String incoming) {
    if (incoming.isEmpty) return current;
    if (current.isEmpty) return incoming;
    final separator = current.endsWith('\n') ? '' : '\n';
    return '$current$separator$incoming';
  }

  static Future<List<Map<String, dynamic>>> getPendingShares() async {
    ensureInitialized();
    try {
      final records = await _channel.invokeListMethod<Object?>(
        'getPendingShares',
      );
      return records
              ?.whereType<Map<Object?, Object?>>()
              .map(
                (record) =>
                    record.map((key, value) => MapEntry(key.toString(), value)),
              )
              .toList(growable: false) ??
          const [];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  static Future<bool> acknowledge(String id) async {
    try {
      return await _channel.invokeMethod<bool>('acknowledge', {'id': id}) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
