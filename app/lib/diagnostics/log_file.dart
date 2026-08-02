/// On-disk persistence for [MakitLog] — a size-bounded, rotating file so a
/// crash's last lines survive an app restart (an iOS device has no console to
/// scroll back to).
///
/// **Write policy — level-aware, so logging can never make the app feel slow:**
/// routine `debug`/`info` lines are buffered in memory and flushed off the hot
/// path (on a short timer, or once the batch is big enough), so a log call costs
/// a string append and nothing else. `warn`/`error` lines flush **immediately
/// and synchronously**, because those are the lines that precede a crash and a
/// diagnostic log is worthless if the fatal line is still sitting in RAM when
/// the process dies.
///
/// A flush always writes the whole pending batch in order, so an error flush
/// also lands the `info` breadcrumbs that led up to it — the context is never
/// lost or reordered.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'log.dart';

/// Appends [LogRecord]s to [file], rotating to a single `<file>.1` backup when
/// the active file would exceed [maxBytes]. Two files bound disk use while
/// still spanning enough history to cover a session and its crash.
class RollingFileLogSink implements LogSink {
  RollingFileLogSink(
    this.file, {
    this.maxBytes = 512 * 1024,
    this.flushEvery = const Duration(seconds: 1),
    this.maxPendingLines = 64,
  });

  /// The active log file. Its parent is created on first write.
  final File file;

  /// Rotate once the active file would grow past this many bytes.
  final int maxBytes;

  /// How long a buffered `debug`/`info` line may wait before being written.
  final Duration flushEvery;

  /// Flush early once this many lines are pending, so a burst can't grow the
  /// buffer unboundedly between timer ticks.
  final int maxPendingLines;

  final List<String> _pending = <String>[];
  Timer? _timer;
  bool _dirReady = false;
  int _bytes = 0;
  bool _sizeKnown = false;

  File get _backup => File('${file.path}.1');

  /// Lines buffered in memory, not yet on disk. Exposed for tests/diagnostics.
  int get pendingCount => _pending.length;

  @override
  void add(LogRecord record) {
    _pending.add('${record.toLine()}\n');
    // warn/error: the crash-relevant lines. Pay the sync fsync here only.
    if (record.level.index >= LogLevel.warn.index ||
        _pending.length >= maxPendingLines) {
      flush();
      return;
    }
    _timer ??= Timer(flushEvery, flush);
  }

  /// Write every pending line to disk, rotating first if the batch would push
  /// the active file past [maxBytes]. Safe to call when nothing is pending.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return;
    final batch = _pending.join();
    _pending.clear();

    if (!_dirReady) {
      file.parent.createSync(recursive: true);
      _dirReady = true;
    }
    if (!_sizeKnown) {
      _bytes = file.existsSync() ? file.lengthSync() : 0;
      _sizeKnown = true;
    }
    final len = utf8.encode(batch).length;
    if (_bytes > 0 && _bytes + len > maxBytes) _rotate();
    file.writeAsStringSync(batch, mode: FileMode.append, flush: true);
    _bytes += len;
  }

  void _rotate() {
    if (_backup.existsSync()) _backup.deleteSync();
    if (file.existsSync()) file.renameSync(_backup.path);
    _bytes = 0;
  }

  /// The full retained log, oldest → newest: the rotated backup (if any)
  /// followed by the active file. Flushes first so an export/upload can never
  /// miss the most recent lines.
  String readAll() {
    flush();
    final buf = StringBuffer();
    if (_backup.existsSync()) buf.write(_backup.readAsStringSync());
    if (file.existsSync()) buf.write(file.readAsStringSync());
    return buf.toString();
  }

  /// Stop the timer and write anything still pending.
  void dispose() {
    flush();
    _timer?.cancel();
    _timer = null;
  }
}
