/// Client-side diagnostic logging.
///
/// A tiny leveled logger that mirrors the server's `log.ts` semantics, plus an
/// in-memory ring buffer and a broadcast stream so the on-device Diagnostics
/// viewer can render logs live — the one thing an iOS device can't otherwise
/// surface, where `print`/`debugPrint` vanish into an unreachable console.
///
/// The core is pure Dart (no Flutter imports beyond none): records are handed
/// to registered [LogSink]s (a rolling file, a console mirror, an uploader) so
/// the buffer, the disk, and the wire stay decoupled and independently
/// testable.
library;

import 'dart:async';
import 'dart:collection';

/// Severity, low → high. Records below the active [MakitLog.minLevel] are
/// dropped before they reach the buffer, stream, or any sink.
enum LogLevel {
  debug,
  info,
  warn,
  error;

  /// Stable wire token shared with the server (`log.ts` uses the same set).
  String get wire => name;

  static LogLevel fromWire(String s) =>
      LogLevel.values.firstWhere((l) => l.wire == s, orElse: () => info);
}

/// One log line: when, how severe, from where, and what.
class LogRecord {
  const LogRecord({
    required this.ts,
    required this.level,
    required this.tag,
    required this.message,
  });

  /// Wall-clock time the record was created.
  final DateTime ts;
  final LogLevel level;

  /// Short origin label, e.g. `ws`, `flutter`, `zone`.
  final String tag;
  final String message;

  /// Compact human line for the viewer / clipboard:
  /// `12:34:56.789 WARN [ws] connect failed`.
  String toLine() {
    final t = ts.toIso8601String().split('T').last; // HH:mm:ss.mmm(+tz)
    return '$t ${level.wire.toUpperCase().padRight(5)} [$tag] $message';
  }

  /// Wire shape sent to the server (`ts` as epoch millis for language-neutral
  /// parsing).
  Map<String, dynamic> toJson() => {
    'ts': ts.millisecondsSinceEpoch,
    'level': level.wire,
    'tag': tag,
    'message': message,
  };
}

/// A destination for accepted records: the rolling file, a console mirror, the
/// server uploader. Sinks never gate — [MakitLog] has already applied the level
/// filter — they only persist/forward.
abstract interface class LogSink {
  void add(LogRecord record);
}

/// The in-app logger: a bounded ring buffer + a broadcast stream + fan-out to
/// registered sinks. One instance is shared process-wide via a provider; tests
/// construct their own.
class MakitLog {
  MakitLog({this.capacity = 2000, this.minLevel = LogLevel.info});

  /// Most-recent records kept in memory (older ones evicted). Bounds memory on
  /// a long-lived session while still giving the viewer a useful window.
  final int capacity;

  /// Records strictly below this are dropped. Defaults to `info`; callers flip
  /// it to `debug` for verbose tracing.
  LogLevel minLevel;

  final Queue<LogRecord> _buffer = ListQueue<LogRecord>();
  final StreamController<LogRecord> _controller =
      StreamController<LogRecord>.broadcast();
  final List<LogSink> _sinks = <LogSink>[];

  /// Live feed of accepted records, for the Diagnostics viewer.
  Stream<LogRecord> get stream => _controller.stream;

  /// Snapshot of the buffered records, oldest → newest.
  List<LogRecord> get records => List<LogRecord>.unmodifiable(_buffer);

  /// Register a [sink]; returns a disposer that removes it.
  void Function() addSink(LogSink sink) {
    _sinks.add(sink);
    return () => _sinks.remove(sink);
  }

  /// Record [message] at [level] from [tag]. Below [minLevel] is a no-op.
  void record(LogLevel level, String tag, String message) {
    if (level.index < minLevel.index) return;
    final rec = LogRecord(
      ts: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
    );
    _buffer.addLast(rec);
    while (_buffer.length > capacity) {
      _buffer.removeFirst();
    }
    if (!_controller.isClosed) _controller.add(rec);
    // A misbehaving sink must never break logging for the others (or crash the
    // very error path that is trying to record a failure).
    for (final sink in _sinks) {
      try {
        sink.add(rec);
      } catch (_) {}
    }
  }

  void debug(String tag, String message) =>
      record(LogLevel.debug, tag, message);
  void info(String tag, String message) => record(LogLevel.info, tag, message);
  void warn(String tag, String message) => record(LogLevel.warn, tag, message);
  void error(String tag, String message) =>
      record(LogLevel.error, tag, message);

  /// Drop the buffered records (does not touch sinks/files).
  void clear() => _buffer.clear();

  /// Release the broadcast stream. The process-wide instance lives for the
  /// app's lifetime; tests dispose their own.
  Future<void> dispose() => _controller.close();
}
