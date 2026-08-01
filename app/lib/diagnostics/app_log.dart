/// The process-wide diagnostics logger and its platform helpers.
///
/// Kept in its own lean file (only `dart:io`, `foundation`, and the pure
/// [MakitLog] core) so any layer — including transport — can log through
/// [appLog] without importing the Riverpod/connection wiring, which would
/// create an import cycle.
///
/// [appLog] is a deliberate global (mirroring the server's `export const log`):
/// logging must be reachable from `main()` before any provider container
/// exists, and from deep in the tree without threading an instance through.
library;

import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'log.dart';
import 'log_file.dart';

/// The one logger for the whole app. Debug builds default to verbose `debug`;
/// release builds start at `info` to keep the buffer signal-dense.
final MakitLog appLog = MakitLog(
  minLevel: kDebugMode ? LogLevel.debug : LogLevel.info,
);

/// Coarse origin label shipped with uploads and written to the server log.
String diagnosticPlatformLabel() {
  if (Platform.isIOS) return 'ios';
  if (Platform.isAndroid) return 'android';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  if (Platform.isWindows) return 'windows';
  return 'unknown';
}

/// Resolve the rolling log file under the app-support directory. Isolated here
/// (not in the pure [RollingFileLogSink]) because it needs `path_provider`.
Future<RollingFileLogSink> openDefaultLogSink() async {
  final dir = await getApplicationSupportDirectory();
  return RollingFileLogSink(File('${dir.path}/makit.log'));
}

/// Mirrors records to the IDE console via [debugPrint], so a developer running
/// a debug build still sees logs where they expect them. Registered only in
/// debug builds (release builds keep console noise off).
class ConsoleLogSink implements LogSink {
  const ConsoleLogSink();
  @override
  void add(LogRecord record) => debugPrint(record.toLine());
}
