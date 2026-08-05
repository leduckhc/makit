/// Flutter frame-timing collector for the metrics panel (SPEC-37 Tier 1).
///
/// Registers a [SchedulerBinding] timings callback into a fixed 600-frame ring
/// and derives p50/p95/dropped from it. The callback is registered **only while
/// the panel is watching** and removed on release/dispose: a leaked
/// `addTimingsCallback` runs for the process lifetime, so it is a permanent cost
/// in the one feature whose entire point is proving makit is cheap. The add/
/// remove hooks are injectable so a test can count registrations without a real
/// binding.
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Ring capacity — 600 frames ≈ 10 s at 60 fps, enough for a stable p95 without
/// holding minutes of history the panel never shows.
const int kFrameRingCapacity = 600;

/// A frame slower than this (ms) is "dropped" — one 60 fps budget (16.7 ms).
const double kFrameBudgetMs = 1000 / 60;

/// p50/p95 frame build+raster time and the dropped-frame count over the ring.
class FrameStats {
  const FrameStats({
    required this.p50Ms,
    required this.p95Ms,
    required this.dropped,
    required this.sampleCount,
    this.samplesMs = const [],
  });

  final double p50Ms;
  final double p95Ms;
  final int dropped;
  final int sampleCount;

  /// The raw frame durations behind the percentiles, ascending. The Tier 2
  /// histogram needs the distribution, which percentiles cannot reconstruct.
  final List<double> samplesMs;

  static const empty = FrameStats(
    p50Ms: 0,
    p95Ms: 0,
    dropped: 0,
    sampleCount: 0,
  );
}

/// Signatures matching [SchedulerBinding.addTimingsCallback] /
/// `removeTimingsCallback`, injected so tests count without a live binding.
typedef AddTimingsCallback = void Function(TimingsCallback callback);
typedef RemoveTimingsCallback = void Function(TimingsCallback callback);

/// Collects frame totals into a ring and exposes [stats].
///
/// Ownership is **ref-counted** ([acquire]/[release]), like
/// `MetricsWatchController`. Two surfaces own this collector — the Tier 1
/// popover and the Tier 2 dashboard — and the normal handoff has both open for a
/// moment, since "Open dashboard →" opens the panel and then dismisses the
/// popover. With a plain idempotent register plus an unconditional remove, that
/// dismissal unregistered the callback out from under the dashboard, which then
/// displayed frozen frame stats for as long as it stayed open. A single shared
/// registration is still correct (two would double-count every frame); what was
/// missing was counting the owners.
class FrameTimingsCollector {
  FrameTimingsCollector({
    AddTimingsCallback? add,
    RemoveTimingsCallback? remove,
  }) : _add = add ?? SchedulerBinding.instance.addTimingsCallback,
       _remove = remove ?? SchedulerBinding.instance.removeTimingsCallback;

  final AddTimingsCallback _add;
  final RemoveTimingsCallback _remove;

  // A plain growable list used as a ring: writes wrap at [kFrameRingCapacity],
  // so it never exceeds capacity and never shifts (O(1) per frame at 60 fps).
  final List<double> _totalsMs = <double>[];
  int _cursor = 0;

  TimingsCallback? _callback;
  int _owners = 0;

  /// Whether the callback is currently registered (for tests/diagnostics).
  bool get isRegistered => _callback != null;

  /// Live owners; exposed for tests/diagnostics.
  int get ownerCount => _owners;

  /// Claim collection. Registers the callback on the 0→1 transition only.
  void acquire() {
    _owners++;
    if (_owners > 1) return;
    void handler(List<FrameTiming> timings) => _onTimings(timings);
    _callback = handler;
    _add(handler);
  }

  /// Give up one claim. Removes the callback only when the last owner leaves; a
  /// release with no owners is a no-op (never a spurious remove). Safe to call
  /// from `State.dispose`.
  void release() {
    if (_owners == 0) return;
    _owners--;
    if (_owners > 0) return;
    final callback = _callback;
    if (callback == null) return;
    _remove(callback);
    _callback = null;
  }

  /// Unconditional teardown for the provider's own disposal: drops the callback
  /// whatever the count, so a container teardown cannot leak it.
  void disposeAll() {
    _owners = 0;
    final callback = _callback;
    if (callback == null) return;
    _remove(callback);
    _callback = null;
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final ms = timing.totalSpan.inMicroseconds / 1000.0;
      if (_totalsMs.length < kFrameRingCapacity) {
        _totalsMs.add(ms);
      } else {
        _totalsMs[_cursor] = ms;
        _cursor = (_cursor + 1) % kFrameRingCapacity;
      }
    }
  }

  /// Current p50/p95/dropped over the ring, or [FrameStats.empty] before any
  /// frame has been recorded.
  FrameStats get stats {
    if (_totalsMs.isEmpty) return FrameStats.empty;
    final sorted = List<double>.of(_totalsMs)..sort();
    var dropped = 0;
    for (final ms in sorted) {
      if (ms > kFrameBudgetMs) dropped++;
    }
    return FrameStats(
      p50Ms: _percentile(sorted, 0.50),
      p95Ms: _percentile(sorted, 0.95),
      dropped: dropped,
      sampleCount: sorted.length,
      samplesMs: sorted,
    );
  }

  /// Nearest-rank percentile of an already-sorted list.
  static double _percentile(List<double> sorted, double q) {
    if (sorted.isEmpty) return 0;
    final rank = (q * (sorted.length - 1)).round();
    return sorted[rank];
  }
}

/// The one frame-timings collector for the process.
///
/// A provider so the metrics surfaces share a single ring (two panels must not
/// double-count frames) and so tests can inject counting add/remove hooks
/// instead of a live [SchedulerBinding]. Whoever registers is responsible for
/// releasing: `MetricsButton` and `MetricsDashboard` each acquire while open and
/// release on dismiss, mirroring the 1 Hz metrics watch.
final frameTimingsProvider = Provider<FrameTimingsCollector>((ref) {
  final collector = FrameTimingsCollector();
  ref.onDispose(collector.disposeAll);
  return collector;
});
