/// Pure timing-label rules shared by the transcript widgets (SPEC-47).
///
/// Kept out of the widgets so the thresholds (D2, D6) and the freeze/live
/// decision (D6a, D19) are unit-testable without pumping a widget or a clock.
library;

import '../../store/chat_items.dart';
import 'elapsed.dart';

/// A finished tool row shows its duration only at or above this floor (D2):
/// below it, most calls are `0.2s` — ink spent to say nothing happened.
const int kToolDurationFloor = 2000;

/// Past this a **running tool call**'s counter escalates to `kStatusWarning`
/// (D6). Escalation applies to running tool calls only — never a turn or a
/// thinking counter.
const int kLiveEscalationMs = 60000;

/// The widest common duration form, used to reserve a min-width so a tick
/// cannot re-ellipsize the row's summary (D6b).
const String kDurationWidthSample = '00m 00s';

/// Whether a finished tool row is worth labelling (D2).
bool showsFinishedDuration(int ms) => ms >= kToolDurationFloor;

/// Whether a running tool call has crossed the 60 s escalation (D6).
bool escalates(int ms) => ms >= kLiveEscalationMs;

/// The elapsed a tool row should display, and whether it is a **live** ticking
/// counter (SPEC-47 D6/D6a/D19).
///
/// * A finished call ([ToolCallItem.endedTs] set) uses its own end.
/// * A no-end call whose enclosing turn closed freezes at that `idle`
///   ([enclosingTurnCloseTs]) — never a climbing number (D6a).
/// * A no-end call in a still-running session ticks off [serverNowMs].
/// * Otherwise (an orphaned no-end call in an idle/archived transcript) there is
///   no honest number and no live counter (D19).
///
/// `ms` is null when the span is unrepresentable (D10b) or absent.
({int? ms, bool live}) toolDurationState({
  required ToolCallItem item,
  required int? enclosingTurnCloseTs,
  required int serverNowMs,
  required bool sessionRunning,
}) {
  if (item.endedTs != null) {
    return (ms: elapsedMs(start: item.ts, end: item.endedTs), live: false);
  }
  if (enclosingTurnCloseTs != null) {
    return (
      ms: elapsedMs(start: item.ts, end: enclosingTurnCloseTs),
      live: false,
    );
  }
  if (sessionRunning) {
    return (ms: elapsedMs(start: item.ts, end: serverNowMs), live: true);
  }
  return (ms: null, live: false);
}
