// Fold bench: what one streamed delta costs the store, before any widget work.
//
//   dart run tool/perf/fold_bench.dart
//
// Why: `stream_bench.dart` measured the WIDGET cost of a delta (markdown
// re-parse). This measures the STORE cost, which is paid first and on the same
// thread. Two O(n) steps run per delta today:
//
//   1. `reduceEvent` copies the session's whole event list
//      (`List<SessionEvent>.from`) to keep the state immutable.
//   2. `chatItemsProvider` re-runs `foldEvents` + `deriveTurns` +
//      `withTurnReceipts` over that whole list.
//
// Both are O(events), so a turn pays O(events^2). This bench reports the cost
// of one delta at a given transcript size, so the quadratic is visible.
//
// The bench is pure Dart (no Flutter): `chat_items.dart` and `turns.dart` only
// import `transport/protocol.dart`.
import 'dart:io';

import 'package:makit/store/chat_items.dart';
import 'package:makit/store/turns.dart';
import 'package:makit/transport/protocol.dart';

/// Characters per streamed chunk — a plausible token.
const _chunkChars = 40;
const _chunk = 'lorem ipsum dolor sit amet consectetur a';

/// Transcript sizes to probe, in events already present before the turn starts.
const _priorSizes = <int>[0, 1000, 5000, 20000];

/// Deltas streamed per probe.
const _deltas = 300;

SessionEvent _delta(int seq, String msgId) => SessionEvent(
  seq: seq,
  sessionId: 's',
  ts: 1700000000000 + seq,
  kind: EventKind.agentMessageDelta,
  payload: {'msgId': msgId, 'chunk': _chunk},
);

/// A prior transcript of `n` events: alternating finished turns, so the fold and
/// the turn pass both have real work to do.
List<SessionEvent> _prior(int n) {
  final out = <SessionEvent>[];
  for (var i = 0; i < n; i++) {
    final seq = i + 1;
    out.add(switch (i % 10) {
      0 => SessionEvent(
        seq: seq,
        sessionId: 's',
        ts: 1600000000000 + seq,
        kind: EventKind.userMessage,
        payload: const {'text': 'do the thing'},
      ),
      1 => SessionEvent(
        seq: seq,
        sessionId: 's',
        ts: 1600000000000 + seq,
        kind: EventKind.sessionStatus,
        payload: const {'status': 'running'},
      ),
      9 => SessionEvent(
        seq: seq,
        sessionId: 's',
        ts: 1600000000000 + seq,
        kind: EventKind.sessionStatus,
        payload: const {'status': 'idle'},
      ),
      _ => SessionEvent(
        seq: seq,
        sessionId: 's',
        ts: 1600000000000 + seq,
        kind: EventKind.agentMessage,
        payload: {'msgId': 'm$i', 'text': 'reply $i'},
      ),
    });
  }
  return out;
}

/// One probe: stream `_deltas` deltas on top of `prior`, doing exactly the work
/// the app does per delta today.
({double copyMs, double foldMs, int items}) _probe(List<SessionEvent> prior) {
  var list = List<SessionEvent>.from(prior);
  final msgId = 'stream';
  var copyMicros = 0;
  var foldMicros = 0;
  var items = 0;
  final sw = Stopwatch();
  for (var i = 0; i < _deltas; i++) {
    final ev = _delta(list.length + 1, msgId);

    // Step 1 — the immutable state copy in `reduceEvent`.
    sw
      ..reset()
      ..start();
    final next = List<SessionEvent>.from(list);
    next.add(ev);
    sw.stop();
    copyMicros += sw.elapsedMicroseconds;
    list = next;

    // Step 2 — the provider's fold, turn pass and receipt projection.
    sw
      ..reset()
      ..start();
    final folded = withTurnReceipts(foldEvents(list), deriveTurns(list));
    sw.stop();
    foldMicros += sw.elapsedMicroseconds;
    items = folded.length;
  }
  return (
    copyMs: copyMicros / 1000 / _deltas,
    foldMs: foldMicros / 1000 / _deltas,
    items: items,
  );
}

void main() {
  stdout.writeln(
    'per-delta store cost (${_deltas} deltas of $_chunkChars chars each)\n',
  );
  stdout.writeln('prior events | copy ms | fold ms | total ms | rows');
  for (final n in _priorSizes) {
    final prior = _prior(n);
    _probe(_prior(200)); // warm up the JIT before the measured probe
    final r = _probe(prior);
    stdout.writeln(
      '${n.toString().padLeft(12)} | '
      '${r.copyMs.toStringAsFixed(3).padLeft(7)} | '
      '${r.foldMs.toStringAsFixed(3).padLeft(7)} | '
      '${(r.copyMs + r.foldMs).toStringAsFixed(3).padLeft(8)} | '
      '${r.items}',
    );
  }
  final rssMb = ProcessInfo.currentRss / 1024 / 1024;
  stdout.writeln('\nbench RSS at exit: ${rssMb.toStringAsFixed(0)} MB');
}
