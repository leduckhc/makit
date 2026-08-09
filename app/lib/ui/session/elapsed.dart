/// Elapsed-span formatting for the transcript (SPEC-47 D13/D13a/D14/D10b).
///
/// Deliberately separate from the two duration formatters this app already has
/// — `formatDuration` (`desktop/metrics/metrics_button.dart`) and
/// `portUptimeLabel` (`ui/ports/ports_vocabulary.dart`). Those format *uptime*:
/// a coarse, still-running "how long has this been up", where seconds are noise
/// and a day tier matters. This formats *a span that ended*, where sub-minute
/// precision is the entire point — `formatDuration` renders every sub-second
/// call as `0s` and collapses `2m 41s` to `2m`. Same units, different question;
/// see SPEC-47 D13 for why they are not consolidated.
library;

/// The elapsed milliseconds of a span, or null when it cannot be computed
/// honestly (D10b).
///
/// Null means "no honest number exists", covering both a span with no terminal
/// event ([end] null — see D1) and a backwards span. Server clocks move (an NTP
/// step, a laptop resuming from sleep mid-turn) and `ts` is `Date.now()` at
/// record time rather than a monotonic counter, so `end < start` is reachable in
/// a real log. Neither `0` nor `|delta|` is honest, so neither is returned.
int? elapsedMs({required int start, required int? end}) {
  if (end == null) return null;
  final ms = end - start;
  return ms < 0 ? null : ms;
}

/// A span as a label, or null when [ms] is unrepresentable (D10b).
///
/// The ladder (D13):
///   `2.4s` one decimal, 2–10 s only · `13s` · `2m 41s` · `18m 04s` zero-padded
///   · `4h 12m` · `3d 4h`
///
/// **Rounds exactly once, at the top, then uses integer arithmetic for every
/// tier below it.** Rounding inside a tier lets a carry escape it — `59.5s`
/// became `60s`, `119.7s` became `1m 60s`, and because the carry cascades a
/// whole tier, `3599.7s` became `59m 60s`. That bug shipped in this feature's
/// own design mockup and was caught by review, which is why D13a pins those
/// values as required tests: every *documented* rung of the ladder passes
/// without them.
String? formatElapsed(int ms) {
  if (ms < 0) return null;

  // The decimal branch stops at 9.95 s, not 10 s: a value that would round to
  // `10.0` must leave this branch rather than print `10.0s`.
  if (ms < 9950) {
    final s = ms / 1000;
    final text = s.toStringAsFixed(1);
    return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text}s';
  }

  final total = (ms / 1000).round(); // the one and only rounding
  if (total < 60) return '${total}s';

  final minutes = total ~/ 60;
  if (minutes < 60) {
    return '${minutes}m ${(total % 60).toString().padLeft(2, '0')}s';
  }

  final hours = minutes ~/ 60;
  if (hours < 24) {
    return '${hours}h ${(minutes % 60).toString().padLeft(2, '0')}m';
  }
  return '${hours ~/ 24}d ${hours % 24}h';
}
