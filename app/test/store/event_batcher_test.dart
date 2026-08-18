// A live delta must not cost one whole store update.
//
// The server sends one WebSocket frame per streamed token (a peak of 2184
// frames/s was measured on the metrics dashboard). Applying each one on its own
// notified every watcher per token, so the transcript re-folded and the message
// re-parsed its markdown that often. [EventBatcher] collects the frames and
// hands them over in one batch, at most once per window.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/event_batcher.dart';
import 'package:makit/transport/protocol.dart';

SessionEvent _ev(int seq) => SessionEvent(
  seq: seq,
  sessionId: 's1',
  ts: 1700000000000 + seq,
  kind: EventKind.agentMessageDelta,
  payload: const {'msgId': 'm1', 'chunk': 'x'},
);

/// A hand-run scheduler: records the pending callback so a test fires the
/// window itself. No real timer, so the tests stay synchronous.
class _Clock {
  void Function()? pending;
  int armed = 0;
  Duration? lastWindow;

  ScheduledFlush schedule(Duration d, void Function() fn) {
    armed++;
    lastWindow = d;
    pending = fn;
    return ScheduledFlush(cancel: () => pending = null);
  }

  void fire() {
    final fn = pending;
    pending = null;
    fn?.call();
  }
}

void main() {
  test('collects events and delivers them once per window, in order', () {
    final clock = _Clock();
    final batches = <List<SessionEvent>>[];
    final batcher = EventBatcher(
      onFlush: batches.add,
      window: const Duration(milliseconds: 50),
      schedule: clock.schedule,
    );

    batcher.add(_ev(1));
    batcher.add(_ev(2));
    batcher.add(_ev(3));

    expect(batches, isEmpty, reason: 'nothing lands before the window closes');
    expect(clock.armed, 1, reason: 'one window per burst, not one per event');
    expect(clock.lastWindow, const Duration(milliseconds: 50));

    clock.fire();

    expect(batches.length, 1);
    expect(batches.single.map((e) => e.seq), [1, 2, 3]);
  });

  test('arms a fresh window for the next burst', () {
    final clock = _Clock();
    final batches = <List<SessionEvent>>[];
    final batcher = EventBatcher(
      onFlush: batches.add,
      schedule: clock.schedule,
    );

    batcher.add(_ev(1));
    clock.fire();
    batcher.add(_ev(2));
    clock.fire();

    expect(clock.armed, 2);
    expect(batches.map((b) => b.single.seq), [1, 2]);
  });

  test('flush delivers pending events at once and disarms the window', () {
    final clock = _Clock();
    final batches = <List<SessionEvent>>[];
    final batcher = EventBatcher(
      onFlush: batches.add,
      schedule: clock.schedule,
    );

    batcher.add(_ev(1));
    batcher.flush();

    expect(batches.single.map((e) => e.seq), [1]);
    expect(clock.pending, isNull, reason: 'the armed window is cancelled');

    // A second flush with nothing pending must stay silent: the store calls it
    // before every non-event frame, which is most frames.
    batcher.flush();
    expect(batches.length, 1);
  });

  test('drop clears pending events without delivering them', () {
    final clock = _Clock();
    final batches = <List<SessionEvent>>[];
    final batcher = EventBatcher(
      onFlush: batches.add,
      schedule: clock.schedule,
    );

    batcher.add(_ev(1));
    batcher.drop();
    batcher.flush();

    expect(
      batches,
      isEmpty,
      reason: 'events of a server we left must never reach the new store',
    );
    expect(clock.pending, isNull);
  });

  test('dispose cancels the armed window', () {
    final clock = _Clock();
    final batches = <List<SessionEvent>>[];
    final batcher = EventBatcher(
      onFlush: batches.add,
      schedule: clock.schedule,
    );

    batcher.add(_ev(1));
    batcher.dispose();

    expect(clock.pending, isNull);
    clock.fire();
    expect(batches, isEmpty);
  });
}
