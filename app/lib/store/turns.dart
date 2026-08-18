/// Turn-span derivation for session timings (SPEC-session-timings D18/D10/D10a/D10b).
///
/// A **separate pure pass** over the session event stream, deliberately NOT
/// threaded through `foldEvents` (D18): a turn is an interval between two status
/// edges, and mixing that into the chat-item fold would couple turn correctness
/// to incidental row ordering. Both the turn-receipt row and the session rollup
/// read the [TurnSpan] list this produces.
library;

import 'chat_items.dart';
import '../transport/protocol.dart';

/// The session-effort rollup shown in the usage popover (SPEC-session-timings D11): totals
/// derived from the completed [TurnSpan]s of a session whose full history this
/// client holds (D16 gates the render, not this arithmetic).
class TurnRollup {
  const TurnRollup({
    required this.turnCount,
    required this.agentMs,
    required this.medianWallMs,
  });

  /// How many turns completed.
  final int turnCount;

  /// Σ(wall − gated) across every turn — the session's actual agent time.
  final int agentMs;

  /// Median turn **wall clock**, or null when there are no turns. Median, not
  /// mean, so one 40-minute watch command does not report a typical turn that
  /// never happened.
  final int? medianWallMs;
}

/// Roll [spans] up into the four session facts (SPEC-session-timings D11).
TurnRollup turnRollup(List<TurnSpan> spans) {
  if (spans.isEmpty) {
    return const TurnRollup(turnCount: 0, agentMs: 0, medianWallMs: null);
  }
  var agentMs = 0;
  final walls = <int>[];
  for (final s in spans) {
    agentMs += s.agentMs;
    walls.add(s.wallMs);
  }
  walls.sort();
  final mid = walls.length ~/ 2;
  final median = walls.length.isOdd
      ? walls[mid]
      : ((walls[mid - 1] + walls[mid]) / 2).round();
  return TurnRollup(
    turnCount: spans.length,
    agentMs: agentMs,
    medianWallMs: median,
  );
}

/// A completed turn: the interval from its opener to the `idle` that closed it,
/// with the gate time subtracted out and enough content facts to render a
/// receipt (SPEC-session-timings D9) and the session rollup (D11).
///
/// Only turns that close honestly are represented — an unclosed turn, a
/// backwards span (D10b) and a turn that produced neither a tool call nor an
/// agent message (D10a) never become a [TurnSpan].
class TurnSpan {
  const TurnSpan({
    required this.openTs,
    required this.closeTs,
    required this.openSeq,
    required this.closeSeq,
    required this.gatedMs,
    required this.toolCount,
    required this.hasAgentMessage,
  });

  /// Server-clock ms of the opener (the `user.message`, or the fallback
  /// `running`).
  final int openTs;

  /// Server-clock ms of the closing `idle`.
  final int closeTs;

  /// Seq of the opener and of the closing `idle` — the turn's seq range.
  final int openSeq;
  final int closeSeq;

  /// Time spent blocked on a gate (`awaiting-approval`/`awaiting-input`) inside
  /// this turn — the sum of every gate-entry→next-`running` interval, plus an
  /// open gate closed directly by `idle`.
  final int gatedMs;

  /// How many tool calls started inside the turn.
  final int toolCount;

  /// Whether the agent produced at least one message in the turn.
  final bool hasAgentMessage;

  /// Wall clock of the whole turn.
  int get wallMs => closeTs - openTs;

  /// Wall clock minus the time the turn was blocked on the user — the actual
  /// agent effort (SPEC-session-timings D11 `Agent time`).
  int get agentMs => wallMs - gatedMs;
}

/// A turn being accumulated as [deriveTurns] walks the stream.
class _OpenTurn {
  _OpenTurn({required this.openTs, required this.openSeq});
  final int openTs;
  final int openSeq;
  int gatedMs = 0;
  int toolCount = 0;
  bool hasAgentMessage = false;

  /// When the turn entered its current gate, or null when it is not gated.
  int? gateEnteredTs;
}

/// Fold a seq-ordered [events] stream into completed [TurnSpan]s (SPEC-session-timings D10).
///
/// A turn opens at a `user.message` with `steered != true`, or — absent one — at
/// the first `session.status: running`. It closes at the first `idle` after it,
/// and at nothing else: `awaiting-*` gates accumulate into [TurnSpan.gatedMs]
/// and `exited` is not a turn transition at all (a failed reattach records it
/// days later — closing on it would print a multi-day span). An unclosed turn,
/// a backwards span (D10b) and a content-free turn (D10a) yield no span.
List<TurnSpan> deriveTurns(Iterable<SessionEvent> events) {
  final spans = <TurnSpan>[];
  _OpenTurn? open;

  for (final e in events) {
    switch (e.kind) {
      case EventKind.userMessage:
        // A non-steered user message opens a turn — but only when none is open,
        // so a steered mid-turn injection (SPEC-mid-turn-steering-and-queue) never splits the turn.
        if (open == null && e.payload['steered'] != true) {
          open = _OpenTurn(openTs: e.ts, openSeq: e.seq);
        }
      case EventKind.sessionStatus:
        final status = e.payload['status'] as String?;
        switch (status) {
          case 'running':
            if (open == null) {
              // Fallback opener for a partial replay window that starts
              // mid-turn (D16's non-`_historyLoaded` tail).
              open = _OpenTurn(openTs: e.ts, openSeq: e.seq);
            } else if (open.gateEnteredTs case final entered?) {
              open.gatedMs += e.ts - entered;
              open.gateEnteredTs = null;
            }
          case 'awaiting-approval':
          case 'awaiting-input':
            // Entering a gate: start accumulating until the next `running` or
            // the closing `idle`. A repeated gate status keeps the first entry
            // (do not reset).
            open?.gateEnteredTs ??= e.ts;
          case 'idle':
            if (open != null) {
              final span = _finish(open, e);
              if (span != null) spans.add(span);
              open = null;
            }
          // `exited` and any other status: not a closer, not a gate.
        }
      case EventKind.toolCallStart:
        if (open != null) open.toolCount++;
      case EventKind.agentMessage:
      case EventKind.agentMessageDelta:
        if (open != null) open.hasAgentMessage = true;
      case EventKind.agentMedia:
      case EventKind.agentThinking:
      case EventKind.agentThinkingDelta:
      case EventKind.toolCallDelta:
      case EventKind.toolCallEnd:
      case EventKind.sessionError:
      case EventKind.sessionCommands:
      case EventKind.sessionMeta:
      case EventKind.sessionActionError:
      case EventKind.sessionUsage:
        break;
    }
  }
  return spans;
}

/// The opener timestamp of the currently-**open** (unclosed) turn, or null when
/// no turn is open (SPEC-session-timings D8). Drives the working indicator's live counter;
/// the same opener rules as [deriveTurns] apply.
int? openTurnStartMs(Iterable<SessionEvent> events) {
  int? openTs;
  for (final e in events) {
    switch (e.kind) {
      case EventKind.userMessage:
        if (openTs == null && e.payload['steered'] != true) openTs = e.ts;
      case EventKind.sessionStatus:
        switch (e.payload['status'] as String?) {
          case 'running':
            openTs ??= e.ts;
          case 'idle':
            openTs = null;
        }
      default:
        break;
    }
  }
  return openTs;
}

/// Build a [TurnSpan] from an [open] turn closed by [idle], or null when the
/// turn is not honestly renderable (D10a content gate, D10b backwards span).
TurnSpan? _finish(_OpenTurn open, SessionEvent idle) {
  if (idle.ts < open.openTs) return null; // D10b
  var gatedMs = open.gatedMs;
  if (open.gateEnteredTs case final entered?) {
    if (idle.ts < entered) return null; // D10b
    gatedMs += idle.ts - entered;
  }
  if (open.toolCount == 0 && !open.hasAgentMessage) return null; // D10a
  return TurnSpan(
    openTs: open.openTs,
    closeTs: idle.ts,
    openSeq: open.openSeq,
    closeSeq: idle.seq,
    gatedMs: gatedMs,
    toolCount: open.toolCount,
    hasAgentMessage: open.hasAgentMessage,
  );
}

/// Project a receipt row (SPEC-session-timings D9) after the last item of each turn in
/// [spans].
///
/// Kept here rather than inside `foldEvents` for the reason D18 gives: the fold
/// builds rows, this decides turn boundaries, and mixing them couples turn
/// correctness to incidental row order. The fold's output is walked once and
/// left otherwise untouched — same instances, same order.
///
/// A span whose rows are not in [items] (a tail-only transcript can hold one)
/// contributes nothing: a receipt with no turn above it would attach itself to
/// whatever happened to be last.
List<ChatItem> withTurnReceipts(List<ChatItem> items, List<TurnSpan> spans) {
  if (spans.isEmpty) return items;

  // seq of the row a receipt must follow → the span it reports. A turn's last
  // row is the highest-seq item below its closing status event. The map keeps
  // the existing lastSeq collision behavior: a later span overwrites an earlier
  // one for the same key.
  final receiptAfter = <int, TurnSpan>{};
  var itemIndex = 0;
  for (final span in spans) {
    while (itemIndex < items.length && items[itemIndex].seq < span.openSeq) {
      itemIndex++;
    }

    int? lastSeq;
    while (itemIndex < items.length && items[itemIndex].seq < span.closeSeq) {
      lastSeq = items[itemIndex].seq;
      itemIndex++;
    }
    if (lastSeq != null) receiptAfter[lastSeq] = span;
  }
  if (receiptAfter.isEmpty) return items;

  final out = <ChatItem>[];
  for (final item in items) {
    out.add(item);
    final span = receiptAfter[item.seq];
    if (span != null) {
      out.add(
        TurnReceiptItem(
          // The closing status event's seq: stable, and unique per turn, so the
          // row keeps its identity in the lazy list across rebuilds.
          seq: span.closeSeq,
          ts: span.closeTs,
          wallMs: span.wallMs,
          gatedMs: span.gatedMs,
          toolCount: span.toolCount,
        ),
      );
    }
  }
  return out;
}
