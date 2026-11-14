// P2-5: Dart client for the Android PRoot sandbox (`omnichat/sandbox`).
//
// The native plugin owns installation (pinned APK asset → rootfs) and the
// one-shot PRoot process. This service owns the UI-facing state machine and
// the per-run output stream; it never exposes host paths to the model.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

class AndroidSandboxStatus {
  const AndroidSandboxStatus({
    required this.supported,
    required this.ready,
    required this.rootfsInstalled,
    this.reason,
    this.abi = '',
    this.rootfsDir = '',
    this.rootfsVersion,
    this.installedAt,
    this.rootfsBytes = 0,
    this.freeBytes = 0,
    this.busy = false,
  });

  const AndroidSandboxStatus.unsupported(this.reason)
    : supported = false,
      ready = false,
      rootfsInstalled = false,
      abi = '',
      rootfsDir = '',
      rootfsVersion = null,
      installedAt = null,
      rootfsBytes = 0,
      freeBytes = 0,
      busy = false;

  final bool supported;
  final bool ready;
  final bool rootfsInstalled;
  final String? reason;
  final String abi;
  final String rootfsDir;
  final String? rootfsVersion;
  final String? installedAt;
  final int rootfsBytes;
  final int freeBytes;
  final bool busy;

  static AndroidSandboxStatus fromMap(Object? raw) {
    final map = raw is Map ? raw : const <Object?, Object?>{};
    final supported = map['supported'] == true;
    final installed = map['rootfsInstalled'] == true;
    return AndroidSandboxStatus(
      supported: supported,
      // Trust the native readiness answer: `supported && installed` is not
      // enough (the native probe also checks that PRoot is executable).
      ready: map['ready'] == true,
      rootfsInstalled: installed,
      reason: _stringOrNull(map['reason']),
      abi: (map['abi'] ?? '').toString(),
      rootfsDir: (map['rootfsDir'] ?? '').toString(),
      rootfsVersion: _stringOrNull(map['rootfsVersion']),
      installedAt: _stringOrNull(map['installedAt']),
      rootfsBytes: _int(map['rootfsBytes']),
      freeBytes: _int(map['freeBytes']),
      busy: map['busy'] == true,
    );
  }

  static String? _stringOrNull(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static int _int(Object? value) => value is num ? value.toInt() : 0;
}

class AndroidSandboxProgress {
  const AndroidSandboxProgress({required this.stage, required this.percent});

  final String stage;
  final int percent;
}

class AndroidSandboxOutput {
  const AndroidSandboxOutput({required this.stdout, required this.stderr});

  final Uint8List stdout;
  final Uint8List stderr;
}

class AndroidSandboxRunResult {
  const AndroidSandboxRunResult({
    required this.exitCode,
    required this.durationMs,
    required this.timedOut,
    required this.cancelled,
    required this.interrupted,
    required this.stdout,
    required this.stderr,
    required this.stdoutTruncated,
    required this.stderrTruncated,
  });

  final int exitCode;
  final int durationMs;
  final bool timedOut;
  final bool cancelled;
  final bool interrupted;
  final String stdout;
  final String stderr;
  final bool stdoutTruncated;
  final bool stderrTruncated;

  bool get truncated => stdoutTruncated || stderrTruncated;

  static AndroidSandboxRunResult fromMap(Object? raw) {
    final map = raw is Map ? raw : const <Object?, Object?>{};
    return AndroidSandboxRunResult(
      exitCode: map['exitCode'] is num ? (map['exitCode'] as num).toInt() : -1,
      durationMs: map['durationMs'] is num
          ? (map['durationMs'] as num).toInt()
          : 0,
      timedOut: map['timedOut'] == true,
      cancelled: map['cancelled'] == true,
      interrupted: map['interrupted'] == true,
      stdout: (map['stdout'] ?? '').toString(),
      stderr: (map['stderr'] ?? '').toString(),
      stdoutTruncated: map['stdoutTruncated'] == true,
      stderrTruncated: map['stderrTruncated'] == true,
    );
  }
}

class AndroidSandboxException implements Exception {
  const AndroidSandboxException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Process-wide Android sandbox state. A single install/run can be in flight;
/// the native side enforces the same limits.
class AndroidSandboxService extends ChangeNotifier {
  AndroidSandboxService._() {
    _channel.setMethodCallHandler(_handlePlatformCall);
  }

  static final AndroidSandboxService instance = AndroidSandboxService._();

  static const String toolName = 'shell_exec';
  static const String channelName = 'omnichat/sandbox';
  static const int defaultTimeoutSeconds = 30;
  static const int maxTimeoutSeconds = 600;
  static const int noTimeoutSeconds = -1;

  static bool get isPlatformSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final MethodChannel _channel = const MethodChannel(channelName);
  final StreamController<AndroidSandboxProgress> _progressController =
      StreamController<AndroidSandboxProgress>.broadcast();
  final Map<String, void Function(AndroidSandboxOutput output)>
  _outputListeners = <String, void Function(AndroidSandboxOutput output)>{};
  final Uuid _uuid = const Uuid();

  AndroidSandboxStatus _status = isPlatformSupported
      ? const AndroidSandboxStatus(
          supported: false,
          ready: false,
          rootfsInstalled: false,
        )
      : const AndroidSandboxStatus.unsupported('unsupported_platform');
  bool _refreshing = false;
  bool _installing = false;
  String? _lastError;

  AndroidSandboxStatus get status => _status;
  bool get isReady => _status.supported && _status.ready;
  bool get isInstalling => _installing;
  String? get lastError => _lastError;
  Stream<AndroidSandboxProgress> get progress => _progressController.stream;

  /// Test seam: render install states without a native probe/channel.
  @visibleForTesting
  void debugSetStatus(AndroidSandboxStatus status) {
    _status = status;
    notifyListeners();
  }

  static int parseTimeoutSeconds(Object? raw) {
    final value = raw is num ? raw : int.tryParse(raw?.toString().trim() ?? '');
    if (value == null || !value.isFinite) return defaultTimeoutSeconds;
    if (value == noTimeoutSeconds) return noTimeoutSeconds;
    if (value <= 0) return defaultTimeoutSeconds;
    return value.clamp(1, maxTimeoutSeconds).toInt();
  }

  /// Refresh native support/rootfs state. Safe on every platform: non-Android
  /// returns an `unsupported_platform` status without touching the channel.
  Future<AndroidSandboxStatus> refresh() async {
    if (!isPlatformSupported) {
      _status = const AndroidSandboxStatus.unsupported('unsupported_platform');
      notifyListeners();
      return _status;
    }
    if (_refreshing) return _status;
    _refreshing = true;
    try {
      final result = await _channel.invokeMethod<Object?>('probe');
      _status = AndroidSandboxStatus.fromMap(result);
      _lastError = null;
    } on MissingPluginException {
      _status = const AndroidSandboxStatus.unsupported('plugin_missing');
    } on PlatformException catch (error) {
      _status = AndroidSandboxStatus(
        supported: false,
        ready: false,
        rootfsInstalled: false,
        reason: error.code,
      );
      _lastError = error.message;
    } catch (error) {
      _status = const AndroidSandboxStatus.unsupported('probe_failed');
      _lastError = error.toString();
    } finally {
      _refreshing = false;
      notifyListeners();
    }
    return _status;
  }

  /// Install the pinned rootfs. Progress is also published on [progress].
  Future<AndroidSandboxStatus> install() async {
    if (!isPlatformSupported) {
      throw const AndroidSandboxException(
        'unsupported_platform',
        'Android Shell is only available on Android.',
      );
    }
    if (_installing) return _status;
    _installing = true;
    _lastError = null;
    notifyListeners();
    try {
      final result = await _channel.invokeMethod<Object?>('install');
      _status = AndroidSandboxStatus.fromMap(result);
      return _status;
    } on PlatformException catch (error) {
      _lastError = error.message ?? error.code;
      throw AndroidSandboxException(error.code, _lastError!);
    } finally {
      _installing = false;
      notifyListeners();
    }
  }

  Future<void> cancelInstall() async {
    if (!isPlatformSupported || !_installing) return;
    try {
      await _channel.invokeMethod<Object?>('cancelInstall');
    } catch (_) {}
  }

  Future<void> remove() async {
    if (!isPlatformSupported) return;
    try {
      final result = await _channel.invokeMethod<Object?>('remove');
      _status = AndroidSandboxStatus.fromMap(result);
    } on PlatformException catch (error) {
      _lastError = error.message ?? error.code;
      throw AndroidSandboxException(error.code, _lastError!);
    } finally {
      notifyListeners();
    }
  }

  /// Run one foreground command. [cwd] is a **guest** path (`/workspace/...`).
  Future<AndroidSandboxRunResult> run({
    required String command,
    required String cwd,
    required List<Map<String, dynamic>> binds,
    int timeoutSeconds = defaultTimeoutSeconds,
    String? runId,
    void Function(AndroidSandboxOutput output)? onOutput,
  }) async {
    if (!isPlatformSupported) {
      throw const AndroidSandboxException(
        'unsupported_platform',
        'Android Shell is only available on Android.',
      );
    }
    final id = (runId == null || runId.trim().isEmpty)
        ? 'shell-${_uuid.v4()}'
        : runId;
    final timeout = parseTimeoutSeconds(timeoutSeconds);
    if (onOutput != null) _outputListeners[id] = onOutput;
    try {
      final result = await _channel.invokeMethod<Object?>(
        'run',
        <String, dynamic>{
          'runId': id,
          'command': command,
          'cwd': cwd,
          'timeoutMs': timeout == noTimeoutSeconds ? -1 : timeout * 1000,
          'binds': binds,
        },
      );
      return AndroidSandboxRunResult.fromMap(result);
    } on PlatformException catch (error) {
      throw AndroidSandboxException(error.code, error.message ?? error.code);
    } finally {
      _outputListeners.remove(id);
    }
  }

  Future<bool> cancel(String runId) async {
    if (!isPlatformSupported) return false;
    try {
      final result = await _channel.invokeMethod<bool>(
        'cancel',
        <String, dynamic>{'runId': runId},
      );
      return result == true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> diskUsage() async {
    if (!isPlatformSupported) return const <String, dynamic>{};
    try {
      final result = await _channel.invokeMethod<Object?>('diskUsage');
      return result is Map
          ? result.map((key, value) => MapEntry(key.toString(), value))
          : const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  Future<void> _handlePlatformCall(MethodCall call) async {
    try {
      switch (call.method) {
        case 'installProgress':
          final args = call.arguments is Map ? call.arguments as Map : const {};
          final stage = (args['stage'] ?? '').toString();
          final percent = args['percent'] is num
              ? (args['percent'] as num).toInt()
              : 0;
          _progressController.add(
            AndroidSandboxProgress(
              stage: stage,
              percent: percent.clamp(0, 100),
            ),
          );
          break;
        case 'runOutput':
          final args = call.arguments is Map ? call.arguments as Map : const {};
          final runId = (args['runId'] ?? '').toString();
          final listener = _outputListeners[runId];
          if (listener == null) break;
          final raw = args['data'];
          final bytes = raw is Uint8List
              ? raw
              : raw is List<int>
              ? Uint8List.fromList(raw)
              : Uint8List(0);
          listener(
            AndroidSandboxOutput(
              stdout: args['stream'] == 'stdout' ? bytes : Uint8List(0),
              stderr: args['stream'] == 'stderr' ? bytes : Uint8List(0),
            ),
          );
          break;
      }
    } catch (_) {}
  }
}
