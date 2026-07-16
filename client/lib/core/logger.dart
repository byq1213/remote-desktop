/// Centralized logging for the app.
///
/// Wraps the `logging` package so every module logs through one entry point
/// with a level, instead of scattering `print()` calls. In debug builds the
/// root listener prints to the console; swap the listener for a structured
/// sink (file, crash reporter, remote) without touching any call site.
library;

import 'package:logging/logging.dart';

final Logger log = Logger('remote_desktop');

/// Convenience level shortcuts so call sites can read `log.d(...)` / `log.w(...)`
/// instead of the verbose `log.fine(...)` / `log.warning(...)`.
extension LoggerX on Logger {
  /// Debug — fine.
  void d(Object? message, [Object? error, StackTrace? stackTrace]) =>
      fine(message, error, stackTrace);

  /// Warning.
  void w(Object? message, [Object? error, StackTrace? stackTrace]) =>
      warning(message, error, stackTrace);

  /// Error — severe.
  void e(Object? message, [Object? error, StackTrace? stackTrace]) =>
      severe(message, error, stackTrace);
}

/// Wire the root logger to the console. Call once at startup (e.g. in main).
void setupLogging() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    final time = record.time.toIso8601String().substring(11, 23);
    // This is the logger's output backend, not ad-hoc debugging, so `print`
    // here is intentional and should not be flagged as avoid_print.
    // ignore: avoid_print
    print('$time [${record.level.name}] ${record.message}');
  });
}
