import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/desktop/metrics/metrics_icon_state.dart';
import 'package:makit/store/metrics.dart';

MetricsSample _sample({
  int ts = 1000,
  double? appCpu = 0.3,
  double? serverCpu = 0.1,
  double? agentCpu = 0.0,
  int agentRss = 9 * 1024 * 1024,
  double loopP99 = 3.4,
  bool turnActive = false,
  bool withApp = true,
  bool withAgent = true,
  bool procTableOk = true,
}) => MetricsSample(
  ts: ts,
  app: withApp
      ? SurfaceMetrics(
          pid: 1,
          rssBytes: 118 * 1024 * 1024,
          cpuPercent: appCpu,
          cpuSeconds: 1,
        )
      : null,
  server: ServerMetrics(
    pid: 2,
    rssBytes: 51 * 1024 * 1024,
    cpuPercent: serverCpu,
    cpuSeconds: 1,
    eventLoopP50: 1.2,
    eventLoopP99: loopP99,
  ),
  agents: withAgent
      ? [
          AgentMetrics(
            pid: 3,
            rssBytes: agentRss,
            cpuPercent: agentCpu,
            cpuSeconds: 1,
            sessionId: 's1',
            label: 'codex · x',
            inTurn: turnActive,
            procs: 1,
            uptimeMs: 60000,
          ),
        ]
      : const [],
  wire: const WireMetrics(inBytesPerSec: 0, outBytesPerSec: 0, framesPerSec: 0),
  storage: null,
  sampler: const SamplerMetrics(cpuPercent: 0.2, rssBytes: 1),
  turnActive: turnActive,
  procTableOk: procTableOk,
);

void main() {
  const cs = ColorScheme.dark();

  group('metricsIconState', () {
    test('null sample is Off', () {
      expect(metricsIconState(null, nowMs: 0), MetricsIconState.off);
    });

    test('idle: no turn, low CPU, no sustained elevation', () {
      final s = _sample(turnActive: false);
      expect(
        metricsIconState(s, elevatedSinceMs: null, nowMs: s.ts),
        MetricsIconState.idle,
      );
    });

    test('working: a turn in flight, regardless of CPU', () {
      final s = _sample(turnActive: true, appCpu: 40, agentCpu: 55);
      expect(
        metricsIconState(s, elevatedSinceMs: null, nowMs: s.ts),
        MetricsIconState.working,
      );
    });

    test('elevated: over budget for >30s while idle', () {
      final s = _sample(ts: 40000, appCpu: 3.0);
      expect(
        metricsIconState(s, elevatedSinceMs: 0, nowMs: s.ts),
        MetricsIconState.elevated,
      );
    });

    test('not yet elevated before 30s have passed', () {
      final s = _sample(ts: 20000, appCpu: 3.0);
      expect(
        metricsIconState(s, elevatedSinceMs: 0, nowMs: s.ts),
        MetricsIconState.idle,
      );
    });

    test('pressure: an agent tree over 2 GB RSS', () {
      final s = _sample(agentRss: 3 * 1024 * 1024 * 1024);
      expect(metricsIconState(s, nowMs: s.ts), MetricsIconState.pressure);
    });

    test('pressure: event-loop p99 over 100 ms', () {
      final s = _sample(loopP99: 140);
      expect(metricsIconState(s, nowMs: s.ts), MetricsIconState.pressure);
    });

    test('pressure outranks working (a laggy machine shows mid-turn)', () {
      final s = _sample(turnActive: true, loopP99: 140);
      expect(metricsIconState(s, nowMs: s.ts), MetricsIconState.pressure);
    });
  });

  group('metricsIconColor', () {
    test('idle is the plain outline (no coloured status light)', () {
      expect(metricsIconColor(MetricsIconState.idle, cs), cs.outline);
    });
    test('working is ALSO the plain outline — no tint (decision 12)', () {
      expect(metricsIconColor(MetricsIconState.working, cs), cs.outline);
      // The point of the feature: working must not be warning/error coloured.
      expect(
        metricsIconColor(MetricsIconState.working, cs),
        isNot(kStatusWarning),
      );
    });
    test('elevated is the warning token', () {
      expect(metricsIconColor(MetricsIconState.elevated, cs), kStatusWarning);
    });
    test('pressure is the delete/error token', () {
      expect(metricsIconColor(MetricsIconState.pressure, cs), kDiffDel);
    });
    test('off is the dedicated grey', () {
      expect(metricsIconColor(MetricsIconState.off, cs), kMetricsOffGrey);
    });
  });

  group('metricsTotalCpuPercent', () {
    test('sums known surfaces', () {
      final s = _sample(appCpu: 0.3, serverCpu: 0.1, agentCpu: 0.6);
      expect(metricsTotalCpuPercent(s), closeTo(1.0, 1e-9));
    });
    test('null when nothing measurable yet (decision 2, never a fake 0)', () {
      final s = _sample(withApp: false, serverCpu: null, withAgent: false);
      expect(metricsTotalCpuPercent(s), isNull);
    });
  });

  group('metricsElevatedSinceMs', () {
    test('returns the start of the unbroken over-budget-idle run', () {
      final history = [
        _sample(ts: 1000, appCpu: 3.0),
        _sample(ts: 2000, appCpu: 3.0),
        _sample(ts: 3000, appCpu: 3.0),
      ];
      expect(metricsElevatedSinceMs(history), 1000);
    });

    test('a dip below budget resets the clock', () {
      final history = [
        _sample(ts: 1000, appCpu: 3.0),
        _sample(ts: 2000, appCpu: 0.1), // dip
        _sample(ts: 3000, appCpu: 3.0),
      ];
      expect(metricsElevatedSinceMs(history), 3000);
    });

    test('a turn in flight is never elevated', () {
      final history = [_sample(ts: 3000, appCpu: 50, turnActive: true)];
      expect(metricsElevatedSinceMs(history), isNull);
    });
  });
}
