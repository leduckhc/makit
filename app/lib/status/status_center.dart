/// The user-facing sibling of [MakitLog]: a bounded, copyable record of every
/// outcome the app has reported, plus a change stream the toast and the badge
/// follow.
///
/// Same shape as `diagnostics/log.dart` on purpose (ring buffer + broadcast
/// stream + snapshot getter + provider injection) — one mechanism, learned once.
/// It is a *separate* instance rather than a filter over the log because the log
/// is level-gated developer noise (`minLevel` drops `debug` in release) while
/// activity is a curated user feed where nothing may be dropped by a verbosity
/// setting (SPEC-48 D1).
///
/// Pure Dart: no Flutter import, no `dart:io`. The provider layer wires the
/// process-wide `appLog` in; tests pass their own.
library;

import 'dart:async';
import 'dart:collection';

import '../diagnostics/log.dart';
import 'status_event.dart';

/// What just changed in a [StatusCenter]. A sealed family rather than a bare
/// `Stream<StatusEvent>` because `markAllRead`/`clear` also move the badge, and
/// the toast presenter must tell a fresh post from a coalesced repeat.
sealed class StatusChange {
  const StatusChange();
}

class StatusPosted extends StatusChange {
  const StatusPosted(
    this.event, {
    required this.coalesced,
    this.silent = false,
  });

  final StatusEvent event;

  /// True when this merged into the event already on screen (so a toast should
  /// update in place instead of stacking a second one).
  final bool coalesced;

  /// "For the record only": no toast, and it does not count as unread. Used for
  /// facts the UI is already showing (a session's own status dot) whose *history*
  /// is the valuable part (SPEC-48 D7).
  final bool silent;
}

class StatusReadAll extends StatusChange {
  const StatusReadAll();
}

class StatusCleared extends StatusChange {
  const StatusCleared();
}

class StatusCenter {
  StatusCenter({
    this.capacity = 200,
    this.coalesceWindow = const Duration(seconds: 8),
    MakitLog? log,
    DateTime Function()? now,
  }) : assert(capacity > 0, 'a record that holds nothing is not a record'),
       _log = log,
       _now = now ?? DateTime.now;

  /// Most-recent events kept in memory. Two orders of magnitude smaller than the
  /// log's buffer: this is a list a person scrolls, not a tail a machine greps.
  final int capacity;

  /// How close two identical events must be to become one row with a count.
  /// Material shows snackbars strictly serially, so three failed deletes used to
  /// mean twelve unskippable seconds of notices (SPEC-48 D4).
  final Duration coalesceWindow;

  final MakitLog? _log;
  final DateTime Function() _now;

  /// Newest first — the order every surface renders.
  final Queue<StatusEvent> _buffer = ListQueue<StatusEvent>();
  final StreamController<StatusChange> _controller =
      StreamController<StatusChange>.broadcast();
  int _seq = 0;

  /// Snapshot, newest first.
  List<StatusEvent> get events => List<StatusEvent>.unmodifiable(_buffer);

  Stream<StatusChange> get changes => _controller.stream;

  int get unreadCount => _buffer.where((e) => !e.read).length;

  /// The loudest severity among unread events, or null when nothing is unread —
  /// what tints the Activity badge.
  StatusSeverity? get worstUnread {
    StatusSeverity? worst;
    for (final e in _buffer) {
      if (e.read) continue;
      if (worst == null || e.severity.index > worst.index) worst = e.severity;
    }
    return worst;
  }

  /// Record an outcome. [detail] is the machine payload; when omitted, [error]
  /// (and [stackTrace], debug-side) supplies it, so call sites can hand over the
  /// exception object instead of interpolating it into [title].
  StatusEvent post(
    StatusSeverity severity,
    String title, {
    required String source,
    String? detail,
    Object? error,
    StackTrace? stackTrace,
    String? sessionId,
    bool silent = false,
  }) {
    final resolved = detail ?? _detailFrom(error, stackTrace);
    final candidate = StatusEvent(
      id: 's${_seq++}',
      ts: _now(),
      severity: severity,
      title: title,
      source: source,
      detail: resolved,
      sessionId: sessionId,
      // Born read: unread means "you might have missed this", and a silent event
      // is one the surface was already showing you.
      read: silent,
    );

    final newest = _buffer.isEmpty ? null : _buffer.first;
    final coalesced =
        newest != null &&
        newest.coalescesWith(candidate) &&
        candidate.ts.difference(newest.ts).abs() < coalesceWindow;

    final StatusEvent stored;
    if (coalesced) {
      // Slide forward in time, keep the newest detail, and go unread again: a
      // burst you already dismissed is news once it repeats.
      stored = newest.copyWith(
        ts: candidate.ts,
        detail: resolved ?? newest.detail,
        count: newest.count + 1,
        read: silent && newest.read,
      );
      _buffer.removeFirst();
      _buffer.addFirst(stored);
    } else {
      stored = candidate;
      _buffer.addFirst(stored);
      while (_buffer.length > capacity) {
        _buffer.removeLast();
      }
    }

    _mirrorToLog(stored);
    if (!_controller.isClosed) {
      _controller.add(
        StatusPosted(stored, coalesced: coalesced, silent: silent),
      );
    }
    return stored;
  }

  StatusEvent progress(
    String title, {
    required String source,
    String? detail,
    String? sessionId,
    bool silent = false,
  }) => post(
    StatusSeverity.progress,
    title,
    source: source,
    detail: detail,
    sessionId: sessionId,
    silent: silent,
  );

  StatusEvent info(
    String title, {
    required String source,
    String? detail,
    String? sessionId,
    bool silent = false,
  }) => post(
    StatusSeverity.info,
    title,
    source: source,
    detail: detail,
    sessionId: sessionId,
    silent: silent,
  );

  StatusEvent success(
    String title, {
    required String source,
    String? detail,
    String? sessionId,
    bool silent = false,
  }) => post(
    StatusSeverity.success,
    title,
    source: source,
    detail: detail,
    sessionId: sessionId,
    silent: silent,
  );

  StatusEvent warning(
    String title, {
    required String source,
    String? detail,
    Object? error,
    String? sessionId,
    bool silent = false,
  }) => post(
    StatusSeverity.warning,
    title,
    source: source,
    detail: detail,
    error: error,
    sessionId: sessionId,
    silent: silent,
  );

  StatusEvent failure(
    String title, {
    required String source,
    String? detail,
    Object? error,
    StackTrace? stackTrace,
    String? sessionId,
    bool silent = false,
  }) => post(
    StatusSeverity.failure,
    title,
    source: source,
    detail: detail,
    error: error,
    stackTrace: stackTrace,
    sessionId: sessionId,
    silent: silent,
  );

  void markAllRead() {
    var changed = false;
    final marked = _buffer.map((e) {
      if (e.read) return e;
      changed = true;
      return e.copyWith(read: true);
    }).toList();
    if (!changed) return;
    _buffer
      ..clear()
      ..addAll(marked);
    if (!_controller.isClosed) _controller.add(const StatusReadAll());
  }

  void clear() {
    _buffer.clear();
    if (!_controller.isClosed) _controller.add(const StatusCleared());
  }

  /// The whole feed as one chronological block — the "Copy all" payload, in
  /// reading order rather than display order.
  String copyAllText() => copyTextFor(_buffer);

  Future<void> dispose() => _controller.close();

  /// Every event is also one log line (SPEC-48 D2), so user-visible outcomes ride
  /// along in diagnostics uploads. The reverse never happens.
  void _mirrorToLog(StatusEvent e) {
    final log = _log;
    if (log == null) return;
    final level = switch (e.severity) {
      StatusSeverity.failure => LogLevel.error,
      StatusSeverity.warning => LogLevel.warn,
      _ => LogLevel.info,
    };
    // A log line is one line: fold a multi-line detail rather than break the
    // viewer's `HH:mm:ss LEVEL [tag]` alignment.
    final folded = e.hasDetail
        ? ' — ${e.detail!.trim().split('\n').map((l) => l.trim()).join(' ⏎ ')}'
        : '';
    log.record(level, 'status', '[${e.source}] ${e.displayTitle}$folded');
  }

  static String? _detailFrom(Object? error, StackTrace? stackTrace) {
    if (error == null) return null;
    final head = error.toString();
    if (stackTrace == null) return head;
    return '$head\n$stackTrace';
  }
}

/// One chronological block for an arbitrary selection of events — newest-first
/// in (the order both [StatusCenter.events] and the Activity list use), reading
/// order out. Shared by "Copy all" and by the filtered copy the Activity
/// toolbar performs, so the two can never disagree on shape.
String copyTextFor(Iterable<StatusEvent> events) =>
    events.toList().reversed.map((e) => e.toClipboardText()).join('\n');
