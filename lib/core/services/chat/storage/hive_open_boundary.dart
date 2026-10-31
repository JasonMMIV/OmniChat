import 'dart:async';

/// Actionable failure for a legacy Hive box that could not be opened.
class HiveOpenException implements Exception {
  const HiveOpenException(this.boxName, this.cause);

  final String boxName;
  final Object? cause;

  @override
  String toString() =>
      'HiveOpenException: cannot open $boxName.hive ($cause). The file may be '
      'corrupt or locked. Hive was not modified; export the legacy files '
      'before attempting recovery.';
}

/// Result of opening a Hive box through [HiveOpenBoundary].
class HiveOpenBoundaryResult<T> {
  const HiveOpenBoundaryResult({
    this.value,
    this.error,
    this.stackTrace,
    this.uncaughtErrors = const <Object>[],
  });

  final T? value;
  final Object? error;
  final StackTrace? stackTrace;

  /// Errors delivered to the surrounding zone rather than the returned
  /// future. Hive 2.2 stores an internal `Completer` for concurrent opens and
  /// completes it with the same error it throws, which can surface as an
  /// unhandled asynchronous error.
  final List<Object> uncaughtErrors;

  bool get succeeded =>
      error == null && uncaughtErrors.isEmpty && value != null;

  Object? get primaryError =>
      error ?? (uncaughtErrors.isEmpty ? null : uncaughtErrors.first);
}

/// Runs a Hive open call in an isolated error boundary.
///
/// A corrupt box can throw from the returned future *and* emit the same error
/// as an unhandled asynchronous error from Hive's internal open completer
/// (R5). The boundary captures both, waits one event-loop turn for Hive's
/// fire-and-forget future to settle, and never lets the secondary error escape
/// into the application zone. Callers must close [HiveOpenBoundaryResult.value]
/// when [succeeded] is false.
class HiveOpenBoundary {
  const HiveOpenBoundary._();

  // Hive's internal open completer can settle a few event-loop turns after the
  // public future. This grace period is deliberately short (it runs once per
  // box) but long enough for the duplicate error to be attributed.
  static const Duration settleDelay = Duration(milliseconds: 20);
  static const Duration timeout = Duration(seconds: 60);

  static Future<HiveOpenBoundaryResult<T>> run<T>(
    Future<T> Function() open,
  ) async {
    final uncaughtErrors = <Object>[];
    final completer = Completer<HiveOpenBoundaryResult<T>>();

    runZonedGuarded(
      () async {
        try {
          final value = await open();
          // Hive's internal completer may complete after the returned future.
          await Future<void>.delayed(settleDelay);
          if (!completer.isCompleted) {
            completer.complete(
              HiveOpenBoundaryResult<T>(
                value: value,
                uncaughtErrors: List<Object>.unmodifiable(uncaughtErrors),
              ),
            );
          }
        } catch (error, stackTrace) {
          await Future<void>.delayed(settleDelay);
          if (!completer.isCompleted) {
            completer.complete(
              HiveOpenBoundaryResult<T>(
                error: error,
                stackTrace: stackTrace,
                uncaughtErrors: List<Object>.unmodifiable(uncaughtErrors),
              ),
            );
          }
        }
      },
      (error, stackTrace) {
        // There is no safe way to attribute an async error to a future, but
        // this zone only runs one open call, so every error belongs to it.
        uncaughtErrors.add(error);
      },
    );

    return completer.future.timeout(
      timeout,
      onTimeout: () => HiveOpenBoundaryResult<T>(
        error: TimeoutException(
          'Timed out while opening the legacy Hive box.',
          timeout,
        ),
        uncaughtErrors: List<Object>.unmodifiable(uncaughtErrors),
      ),
    );
  }
}
