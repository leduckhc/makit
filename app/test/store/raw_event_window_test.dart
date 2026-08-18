// The app must not hold every raw event of every session it opened.
//
// One live session has 31,554 events, and the store kept them all per session
// for the life of the process. Since the fold moved into the state
// (`SessionTranscript`), the rendered rows no longer come from that list — so the
// raw window can be bounded, and the app stops paying for a second copy of the
// history it already folded.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/protocol.dart';

SessionEvent _ev(int seq) => SessionEvent(
  seq: seq,
  sessionId: 's1',
  ts: 1700000000000 + seq,
  kind: EventKind.agentMessage,
  payload: {'msgId': 'm$seq', 'text': 'reply $seq'},
);

void main() {
  test('the raw event window is bounded, and the rows are not', () {
    var state = StoreState.empty();
    const total = kRawEventWindow * 3;
    for (var seq = 1; seq <= total; seq++) {
      state = reduceEvent(state, _ev(seq));
    }

    expect(state.events['s1']!.length, kRawEventWindow);
    expect(
      state.events['s1']!.last.seq,
      total,
      reason: 'the window keeps the newest events',
    );
    expect(
      state.transcripts['s1']!.rows.length,
      total,
      reason: 'every row stays: the fold is the history the UI renders',
    );
    expect(state.cursors['s1'], total);
  });

  test('a batch trims once, not per event', () {
    var state = StoreState.empty();
    const total = kRawEventWindow * 2;
    state = reduceEvents(state, [
      for (var seq = 1; seq <= total; seq++) _ev(seq),
    ]);

    expect(state.events['s1']!.length, kRawEventWindow);
    expect(state.transcripts['s1']!.rows.length, total);
  });

  test('a short session keeps every raw event', () {
    var state = StoreState.empty();
    state = reduceEvents(state, [_ev(1), _ev(2), _ev(3)]);
    expect(state.events['s1']!.length, 3);
  });
}
