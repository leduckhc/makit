/// Live-event batching for the store.
///
/// The server sends one `session.event` frame per streamed token, and fans it
/// out to every client. A peak of 2184 frames/s was measured on the metrics
/// dashboard. Applying each frame on its own made every watcher rebuild that
/// often: the transcript re-folded the whole session and the message re-parsed
/// its markdown per token, which is the UI-thread cost the performance snapshot
/// shows (p99 67% of a core during a turn).
///
/// [EventBatcher] collects the events and delivers them in one batch, at most
/// once per [window]. Text still grows smoothly at 20 Hz, and the store pays for
/// one update instead of one per token.
library;

import 'dart:async';

import '../transport/protocol.dart';

/// A pending flush, cancellable by the batcher. Injected so tests never arm a
/// real timer (and so no test has to wait out a window).
class ScheduledFlush {
  const ScheduledFlush({required this.cancel});

  /// Cancel the pending flush. Safe to call after it already ran.
  final void Function() cancel;
}

/// Arms a one-shot flush after [d]. Production wraps `Timer`.
typedef FlushScheduler =
    ScheduledFlush Function(Duration d, void Function() fn);

/// The default batching window: 20 Hz, the cadence the shared pulse clock
/// already uses for animated rows. Faster buys no visible smoothness; slower
/// starts to read as lag on a short reply.
const Duration kDefaultBatchWindow = Duration(milliseconds: 50);

class EventBatcher {
  EventBatcher({
    required void Function(List<SessionEvent> batch) onFlush,
    Duration window = kDefaultBatchWindow,
    FlushScheduler? schedule,
  }) : _onFlush = onFlush,
       _window = window,
       _schedule = schedule ?? _timerSchedule;

  static ScheduledFlush _timerSchedule(Duration d, void Function() fn) {
    final timer = Timer(d, fn);
    return ScheduledFlush(cancel: timer.cancel);
  }

  final void Function(List<SessionEvent> batch) _onFlush;
  final Duration _window;
  final FlushScheduler _schedule;

  final List<SessionEvent> _pending = <SessionEvent>[];
  ScheduledFlush? _armed;

  /// Queue [event] for the next flush, arming the window on the first event of
  /// a burst. Order is preserved: the store depends on it for its seq cursor.
  void add(SessionEvent event) {
    _pending.add(event);
    _armed ??= _schedule(_window, () {
      _armed = null;
      _deliver();
    });
  }

  /// Deliver the pending events now. A no-op when nothing is pending, because
  /// the store calls this before every non-event frame.
  void flush() {
    _disarm();
    _deliver();
  }

  /// Discard the pending events. Used when the app switches server: those
  /// events describe a session tree the new store knows nothing about.
  void drop() {
    _disarm();
    _pending.clear();
  }

  /// Cancel the pending window. The batcher stays usable.
  void dispose() => _disarm();

  /// True while events wait for a flush — for callers that must not read a
  /// stale cursor.
  bool get hasPending => _pending.isNotEmpty;

  void _disarm() {
    _armed?.cancel();
    _armed = null;
  }

  void _deliver() {
    if (_pending.isEmpty) return;
    // Hand over a copy and clear in place: the callback reduces the batch into
    // new state, and reusing the list would let the next burst mutate a batch
    // the store still holds.
    final batch = List<SessionEvent>.of(_pending);
    _pending.clear();
    _onFlush(batch);
  }
}
