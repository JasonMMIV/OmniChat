import 'package:flutter/foundation.dart';

/// 極簡應用程式 logger（Task 2.4）。
///
/// - Debug build：透過 [debugPrint] 輸出（自動加 `[OmniChat]` 前綴）。
/// - Release build：完全靜音，避免 console 雜訊。
abstract final class AppLog {
  AppLog._();

  /// Debug level log。
  static void d(String message) {
    if (kDebugMode) debugPrint('[OmniChat] $message');
  }

  /// Info level log。
  static void i(String message) {
    if (kDebugMode) debugPrint('[OmniChat] $message');
  }

  /// Error level log。
  static void e(String message) {
    if (kDebugMode) debugPrint('[OmniChat][ERROR] $message');
  }
}
