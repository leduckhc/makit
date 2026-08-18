/// The folded view of one session, kept between events.
///
/// The app used to rebuild this view from the first event on every store update:
/// `foldEvents` + `deriveTurns` + `withTurnReceipts`, all O(events). A streaming
/// turn therefore cost O(events²), and `tool/perf/fold_bench.dart` measured
/// 2.54 ms of that per delta at 20000 prior events — on the UI thread, before
/// any widget rebuilt.
///
/// [SessionTranscript] holds the two accumulators instead and [extend]s them
/// with the new events only. Each extend copies the rows once, so the cost is
/// O(rows + new events) rather than O(events).
library;

import 'chat_items.dart';
import 'turns.dart';
import '../transport/protocol.dart';

class SessionTranscript {
  const SessionTranscript._({
    required this.rows,
    required this.turns,
    required this.openTurnStartMs,
    required ChatItemFold fold,
    required TurnAccumulator turnFold,
  }) : _fold = fold,
       _turnFold = turnFold;

  /// A session with nothing in it yet.
  static final SessionTranscript empty = SessionTranscript._(
    rows: const <ChatItem>[],
    turns: const <TurnSpan>[],
    openTurnStartMs: null,
    fold: ChatItemFold(),
    turnFold: TurnAccumulator(),
  );

  /// Fold [events] from nothing. Used for a full history replay, which replaces
  /// a session's transcript rather than extending it.
  factory SessionTranscript.of(Iterable<SessionEvent> events) =>
      empty.extend(events);

  /// The rows to render, receipts included (SPEC-session-timings D9).
  final List<ChatItem> rows;

  /// The session's completed turns.
  final List<TurnSpan> turns;

  /// The opener timestamp of the open turn, or null when none is open (D8).
  final int? openTurnStartMs;

  final ChatItemFold _fold;
  final TurnAccumulator _turnFold;

  /// Fold [events] in and return the extended transcript. Returns `this` when
  /// there is nothing to add, so the store can skip a state update.
  ///
  /// The accumulators are copied first: this instance may still be held as the
  /// previous state, and mutating it would rewrite history behind its holder.
  SessionTranscript extend(Iterable<SessionEvent> events) {
    if (events.isEmpty) return this;

    // SPEC-session-timings D18: turn spans come from a separate pass over the same events,
    // then the receipt rows are projected into the fold's output. The fold stays
    // a row builder; turn correctness never depends on row order.
    final fold = ChatItemFold.from(_fold)..addAll(events);
    final turnFold = TurnAccumulator.from(_turnFold)..addAll(events);
    final spans = turnFold.spans;

    return SessionTranscript._(
      rows: withTurnReceipts(fold.rows, spans),
      turns: spans,
      openTurnStartMs: turnFold.openTurnStartMs,
      fold: fold,
      turnFold: turnFold,
    );
  }
}
