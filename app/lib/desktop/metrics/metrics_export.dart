/// SPEC-37 Tier 2 — snapshot export.
///
/// **Export is the only way a sample reaches disk**, and only when the user asks
/// (decision 5: nothing is ever written to the event log or persisted otherwise).
/// Everything here is a pure function of the ring; the file write is a thin
/// caller's job, so the shape of the artifact is testable without touching a
/// filesystem.
library;

import 'dart:convert';

import '../../store/metrics.dart';
import 'metrics_button.dart' show formatBytes, metricsTotalRssBytes;
import 'metrics_icon_state.dart' show metricsTotalCpuPercent;

/// Schema version of the exported artifact. Bumped when the shape changes, so a
/// pasted snapshot from an old build is identifiable rather than
/// misinterpreted.
const int kMetricsExportVersion = 1;

/// The whole ring plus a header identifying what produced it.
///
/// A snapshot without provenance is close to useless in a bug report: the same
/// numbers mean different things on a different machine or build, which is
/// exactly the confusion the header prevents.
Map<String, dynamic> metricsExportJson({
  required List<MetricsSample> history,
  required String appVersion,
  required String platform,
  MetricsSample? baseline,
}) => {
  'schemaVersion': kMetricsExportVersion,
  'exportedAt': DateTime.now().toUtc().toIso8601String(),
  'appVersion': appVersion,
  'platform': platform,
  // The stored baseline travels WITH the ring: a snapshot whose "before" is
  // missing cannot be compared by the reader, which is the only comparison this
  // spec ships (the side-by-side diff view is deferred).
  'baselineTs': ?baseline?.ts,
  'baseline': baseline == null ? null : _sampleJson(baseline),
  'sampleCount': history.length,
  'samples': [for (final s in history) _sampleJson(s)],
};

/// Pretty-printed [metricsExportJson], ready to write or paste.
String metricsExportJsonString({
  required List<MetricsSample> history,
  required String appVersion,
  required String platform,
  MetricsSample? baseline,
}) => const JsonEncoder.withIndent('  ').convert(
  metricsExportJson(
    history: history,
    appVersion: appVersion,
    platform: platform,
    baseline: baseline,
  ),
);

/// A null-preserving surface encoding. `cpuPercent` stays null rather than
/// becoming 0, so a round-trip cannot manufacture a measurement that never
/// happened (decision 2).
Map<String, dynamic> _surfaceJson(SurfaceMetrics s) => {
  'pid': s.pid,
  'rssBytes': s.rssBytes,
  'cpuPercent': s.cpuPercent,
  'cpuSeconds': s.cpuSeconds,
};

Map<String, dynamic> _sampleJson(MetricsSample s) => {
  'ts': s.ts,
  'app': s.app == null ? null : _surfaceJson(s.app!),
  'server': {
    ..._surfaceJson(s.server),
    'eventLoop': {'p50': s.server.eventLoopP50, 'p99': s.server.eventLoopP99},
  },
  'agents': [
    for (final a in s.agents)
      {
        ..._surfaceJson(a),
        'sessionId': a.sessionId,
        'label': a.label,
        'inTurn': a.inTurn,
        'procs': a.procs,
        'uptimeMs': a.uptimeMs,
      },
  ],
  'wire': {
    'inBytesPerSec': s.wire.inBytesPerSec,
    'outBytesPerSec': s.wire.outBytesPerSec,
    'framesPerSec': s.wire.framesPerSec,
  },
  'storage': s.storage == null
      ? null
      : {'eventLogBytes': s.storage!.eventLogBytes},
  'sampler': {
    'cpuPercent': s.sampler.cpuPercent,
    'rssBytes': s.sampler.rssBytes,
  },
  'turnActive': s.turnActive,
  'procTableOk': s.procTableOk,
};

/// Highest value of [pick] across [history], or null when never measurable.
double? metricsPeakOf(
  List<MetricsSample> history,
  double? Function(MetricsSample) pick,
) {
  double? peak;
  for (final s in history) {
    final v = pick(s);
    if (v == null) continue;
    if (peak == null || v > peak) peak = v;
  }
  return peak;
}

/// A pasteable markdown summary — the form a perf claim actually travels in
/// (a PR comment, an issue). Leads with the headline numbers so the reader does
/// not have to parse JSON to see whether anything regressed.
String metricsExportMarkdown({
  required List<MetricsSample> history,
  required String appVersion,
  required String platform,
  MetricsSample? baseline,
}) {
  if (history.isEmpty) {
    return '### makit performance snapshot\n\n'
        '_No samples recorded._ ($appVersion · $platform)\n';
  }
  final latest = history.last;
  final spanMs = history.last.ts - history.first.ts;
  final peakCpu = metricsPeakOf(history, metricsTotalCpuPercent);
  final peakRss = history
      .map(metricsTotalRssBytes)
      .fold<int>(0, (a, b) => b > a ? b : a);
  final peakSampler = metricsPeakOf(history, (s) => s.sampler.cpuPercent);

  String cpu(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)}%';

  return [
    '### makit performance snapshot',
    '',
    '- **Build:** $appVersion · $platform',
    '- **Window:** ${history.length} samples over '
        '${(spanMs / 1000).round()}s',
    '- **Total CPU:** ${cpu(metricsTotalCpuPercent(latest))} now · '
        '${cpu(peakCpu)} peak',
    '- **Total resident:** ${formatBytes(metricsTotalRssBytes(latest))} now · '
        '${formatBytes(peakRss)} peak',
    '- **Server event loop:** p50 '
        '${latest.server.eventLoopP50.toStringAsFixed(1)}ms · p99 '
        '${latest.server.eventLoopP99.toStringAsFixed(1)}ms',
    // The self-cost line is the point of decision 10: a snapshot that omitted it
    // would be quoting the meter's numbers without its price.
    '- **Cost of measuring:** ${cpu(latest.sampler.cpuPercent)} now · '
        '${cpu(peakSampler)} peak',
    if (baseline != null)
      '- **Baseline:** ${cpu(metricsTotalCpuPercent(baseline))} CPU · '
          '${formatBytes(metricsTotalRssBytes(baseline))} resident',
    '',
    '| Process | PID | RSS | CPU | CPU-s |',
    '|---|---|---|---|---|',
    ...[
      if (latest.app case final app?)
        '| makit (app) | ${app.pid} | ${formatBytes(app.rssBytes)} | '
            '${cpu(app.cpuPercent)} | ${app.cpuSeconds.toStringAsFixed(1)} |',
      '| makit-server (Node) | ${latest.server.pid} | '
          '${formatBytes(latest.server.rssBytes)} | '
          '${cpu(latest.server.cpuPercent)} | '
          '${latest.server.cpuSeconds.toStringAsFixed(1)} |',
      for (final a in latest.agents)
        '| ${a.label} | ${a.pid} | ${formatBytes(a.rssBytes)} | '
            '${cpu(a.cpuPercent)} | ${a.cpuSeconds.toStringAsFixed(1)} |',
    ],
    '',
    if (!latest.procTableOk)
      '> ⚠️ The process table could not be read for the final sample, so app '
          'and agent rows are unknown (not zero).',
  ].join('\n');
}
