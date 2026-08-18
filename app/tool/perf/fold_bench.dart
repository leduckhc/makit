// Fold bench: what one streamed delta costs the store, before any widget work.
//
//   dart run tool/perf/fold_bench.dart
//
// Why: `stream_bench.dart` measured the WIDGET cost of a delta (markdown
// re-parse). This measures the STORE cost, which is paid first and on the same
// thread. Two O(n) steps ran per delta before the kept fold landed:
//
//   1. `reduceEvent` copies the session's whole event list
//      (`List<SessionEvent>.from`) to keep the state immutable.
//   2. `chatItemsProvider` re-ran `foldEvents` + `deriveTurns` +
//      `withTurnReceipts` over that whole list.
//
// Both were O(events), so a turn paid O(events^2). The `kept-fold ms` column is
// `SessionTranscript.extend`, which folds only the new event.
//
// The bench is pure Dart (no Flutter): `chat_items.dart` and `turns.dart` only
// import `transport/protocol.dart`.
import 'dart:io';

import 'package:makit/store/chat_items.dart';
import 'package:makit/store/transcript.dart';
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

/// A prior transcript of `n` events shaped like a real session: 93% of the
/// database's rows are streaming deltas, which fold into few rows. Row count is
/// what the kept fold copies, so this shape reports the field cost.
List<SessionEvent> _priorStreaming(int n) {
  final out = <SessionEvent>[];
  for (var i = 0; i < n; i++) {
    final seq = i + 1;
    final turn = i ~/ 20;
    out.add(switch (i % 20) {
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
      18 => SessionEvent(
        seq: seq,
        sessionId: 's',
        ts: 1600000000000 + seq,
        kind: EventKind.agentMessage,
        payload: {'msgId': 'm$turn', 'text': _chunk * 16},
      ),
      19 => SessionEvent(
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
        kind: i.isEven
            ? EventKind.agentThinkingDelta
            : EventKind.agentMessageDelta,
        payload: i.isEven
            ? {'thinkId': 't$turn', 'chunk': _chunk}
            : {'msgId': 'm$turn', 'chunk': _chunk},
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

/// The same turn against the kept fold: extend the transcript with each delta
/// instead of folding the session again.
({double foldMs, int items}) _probeKept(List<SessionEvent> prior) {
  var transcript = SessionTranscript.of(prior);
  final msgId = 'stream';
  var seq = prior.length;
  var foldMicros = 0;
  var items = 0;
  final sw = Stopwatch();
  for (var i = 0; i < _deltas; i++) {
    final ev = _delta(++seq, msgId);
    sw
      ..reset()
      ..start();
    transcript = transcript.extend([ev]);
    items = transcript.rows.length;
    sw.stop();
    foldMicros += sw.elapsedMicroseconds;
  }
  return (foldMs: foldMicros / 1000 / _deltas, items: items);
}

void main() {
  stdout.writeln(
    'per-delta store cost ($_deltas deltas of $_chunkChars chars each)\n',
  );
  for (final shape in <(String, List<SessionEvent> Function(int))>[
    ('one row per event', _prior),
    ('streaming mix (a real session)', _priorStreaming),
  ]) {
    stdout.writeln('${shape.$1}:');
    stdout.writeln(
      'prior events | copy ms | refold ms | total ms | kept-fold ms | rows',
    );
    for (final n in _priorSizes) {
      final prior = shape.$2(n);
      _probe(shape.$2(200)); // warm up the JIT before the measured probe
      _probeKept(shape.$2(200));
      final r = _probe(prior);
      final k = _probeKept(prior);
      stdout.writeln(
        '${n.toString().padLeft(12)} | '
        '${r.copyMs.toStringAsFixed(3).padLeft(7)} | '
        '${r.foldMs.toStringAsFixed(3).padLeft(9)} | '
        '${(r.copyMs + r.foldMs).toStringAsFixed(3).padLeft(8)} | '
        '${k.foldMs.toStringAsFixed(3).padLeft(12)} | '
        '${r.items}',
      );
      if (k.items != r.items) {
        stdout.writeln('  MISMATCH: kept fold gives ${k.items} rows');
      }
    }
    stdout.writeln('');
  }
  final rssMb = ProcessInfo.currentRss / 1024 / 1024;
  stdout.writeln('bench RSS at exit: ${rssMb.toStringAsFixed(0)} MB');
}
