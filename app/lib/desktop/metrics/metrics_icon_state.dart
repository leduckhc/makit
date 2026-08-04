/// The footer pulse icon's state machine (SPEC-37 Tier 1, decisions 12/14).
///
/// Kept a **pure** function of `(MetricsSample?, elevatedSince)` in its own file
/// so the state table is unit-testable without pumping a widget. The one reading
/// that matters here is the one that is *absent*: there is deliberately no tint
/// for [MetricsIconState.working] — an always-on "busy" colour would be lit all
/// day and carry no information. Colour is reserved for **cost without work**
/// ([MetricsIconState.elevated]) and for a machine that will feel laggy
/// ([MetricsIconState.pressure]).
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../store/metrics.dart';

/// The five footer icon states, exactly the spec's table.
enum MetricsIconState { off, idle, working, elevated, pressure }

/// Total CPU% budget above which, sustained while idle, the icon goes
/// [MetricsIconState.elevated]. Q2 in the plan flags this as the one threshold
/// that produces false positives if wrong; 2% is the mockup's conservative 5×
/// headroom over a ~0.4% idle makit until `makit bench` measures a real floor.
const double kElevatedCpuPercent = 2.0;

/// How long the over-budget-while-idle condition must persist before the icon
/// warns — a momentary spike is not a regression (spec table: "> 30 s").
const int kElevatedSustainMs = 30 * 1000;

/// An agent tree above this resident size is memory **pressure** — the app will
/// feel laggy (spec table).
const int kPressureRssBytes = 2 * 1024 * 1024 * 1024;

/// Event-loop p99 above this (ms) means the server is blocking its own loop and
/// every device on the socket feels it (spec table).
const double kPressureLoopP99Ms = 100;

/// The **Off** grey (`#5a5a5a`): dimmer than [ColorScheme.outline], for when the
/// collector is not sampling. A literal from the mockup's icon-state table — it
/// is not a theme token because "not measuring" is a non-state, not a status.
const Color kMetricsOffGrey = Color(0xFF5A5A5A);

/// Sum of every known surface CPU%, or null when *nothing* is measurable yet
/// (every surface's rate is still null). A null surface contributes nothing
/// rather than a fabricated 0 (decision 2).
double? metricsTotalCpuPercent(MetricsSample sample) {
  var sum = 0.0;
  var any = false;
  void add(double? cpu) {
    if (cpu != null) {
      sum += cpu;
      any = true;
    }
  }

  add(sample.app?.cpuPercent);
  add(sample.server.cpuPercent);
  for (final agent in sample.agents) {
    add(agent.cpuPercent);
  }
  return any ? sum : null;
}

/// Whether the machine is under resource pressure: any agent tree over
/// [kPressureRssBytes], or the server's event loop over [kPressureLoopP99Ms].
/// Independent of whether a turn runs — a laggy machine must show regardless.
bool metricsUnderPressure(MetricsSample sample) {
  if (sample.server.eventLoopP99 > kPressureLoopP99Ms) return true;
  for (final agent in sample.agents) {
    if (agent.rssBytes > kPressureRssBytes) return true;
  }
  return false;
}

/// The raw per-sample condition that, *sustained*, becomes
/// [MetricsIconState.elevated]: over the CPU budget while no turn runs. The
/// sustain window itself is tracked by the caller (see [metricsElevatedSinceMs])
/// because it needs the sample history a single sample cannot carry.
bool metricsOverBudgetIdle(MetricsSample sample) =>
    !sample.turnActive &&
    (metricsTotalCpuPercent(sample) ?? 0) >= kElevatedCpuPercent;

/// The epoch-ms at which the current unbroken run of over-budget-while-idle
/// samples began, or null if the latest sample is not over budget / a turn is
/// running. Walks [history] back from the end so a single dip resets the clock.
int? metricsElevatedSinceMs(List<MetricsSample> history) {
  int? since;
  for (var i = history.length - 1; i >= 0; i--) {
    if (!metricsOverBudgetIdle(history[i])) break;
    since = history[i].ts;
  }
  return since;
}

/// The icon state for [sample], given when the elevated run began
/// ([elevatedSinceMs]) and the current wall clock ([nowMs], the latest sample's
/// `ts` in practice — keeping this deterministic and free of `DateTime.now`).
///
/// Precedence is deliberate: **Pressure outranks Working** because it signals a
/// machine that will feel laggy *whether or not* a turn is running, and that is
/// worth a colour even mid-turn. **Elevated is gated on no turn** (decision 14):
/// a legitimately open turn must never read as "cost while idle".
MetricsIconState metricsIconState(
  MetricsSample? sample, {
  int? elevatedSinceMs,
  required int nowMs,
}) {
  if (sample == null) return MetricsIconState.off;
  if (metricsUnderPressure(sample)) return MetricsIconState.pressure;
  if (sample.turnActive) return MetricsIconState.working;
  if (elevatedSinceMs != null &&
      nowMs - elevatedSinceMs >= kElevatedSustainMs) {
    return MetricsIconState.elevated;
  }
  return MetricsIconState.idle;
}

/// The pulse mark's tint for [state], from theme tokens only (plus the Off grey).
///
/// [MetricsIconState.idle] and [MetricsIconState.working] are **both**
/// [ColorScheme.outline] — identical to the sibling footer icons — because
/// working animates the glyph instead of colouring it (decision 12).
Color metricsIconColor(MetricsIconState state, ColorScheme cs) =>
    switch (state) {
      MetricsIconState.off => kMetricsOffGrey,
      MetricsIconState.idle => cs.outline,
      MetricsIconState.working => cs.outline,
      MetricsIconState.elevated => kStatusWarning,
      MetricsIconState.pressure => kDiffDel,
    };
