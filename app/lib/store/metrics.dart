/// Performance-metrics models + providers (SPEC-37).
///
/// Tolerant by construction, mirroring [GithubBudget]: a malformed field
/// degrades to a null/empty value rather than taking down the socket, and the
/// two semantically-nullable fields the whole feature turns on —
/// [SurfaceMetrics.cpuPercent] and [MetricsSample.procTableOk] — are modelled
/// explicitly so the UI can render "—" / "measurement unavailable" instead of
/// fabricating a zero (spec decisions 2 and 13).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../transport/protocol.dart';
import 'connection.dart';
import 'store.dart';

int _asInt(Object? v) => v is num ? v.toInt() : 0;
double _asDouble(Object? v) => v is num ? v.toDouble() : 0;

/// `null` when no rate is computable yet (a rate needs two samples). Callers
/// render `—`; **never** coerce to 0 — that would be a fabrication (decision 2).
double? _asDoubleOrNull(Object? v) => v is num ? v.toDouble() : null;

int? _asIntOrNull(Object? v) => v is num ? v.toInt() : null;

/// One OS process surface: RSS + CPU. `cpuPercent` is nullable (see above).
class SurfaceMetrics {
  const SurfaceMetrics({
    required this.pid,
    required this.rssBytes,
    required this.cpuPercent,
    required this.cpuSeconds,
  });

  final int pid;
  final int rssBytes;

  /// Instantaneous CPU %, or null when no rate is computable yet (decision 2).
  final double? cpuPercent;
  final double cpuSeconds;

  static SurfaceMetrics? fromJson(Map<String, dynamic> j) {
    if (j['pid'] is! num) return null;
    return SurfaceMetrics(
      pid: _asInt(j['pid']),
      rssBytes: _asInt(j['rssBytes']),
      cpuPercent: _asDoubleOrNull(j['cpuPercent']),
      cpuSeconds: _asDouble(j['cpuSeconds']),
    );
  }
}

/// The server surface plus its event-loop latency percentiles.
class ServerMetrics extends SurfaceMetrics {
  const ServerMetrics({
    required super.pid,
    required super.rssBytes,
    required super.cpuPercent,
    required super.cpuSeconds,
    required this.eventLoopP50,
    required this.eventLoopP99,
  });

  final double eventLoopP50;
  final double eventLoopP99;

  static ServerMetrics? fromJson(Map<String, dynamic> j) {
    if (j['pid'] is! num) return null;
    final el = j['eventLoop'];
    final elMap = el is Map
        ? Map<String, dynamic>.from(el)
        : const <String, dynamic>{};
    return ServerMetrics(
      pid: _asInt(j['pid']),
      rssBytes: _asInt(j['rssBytes']),
      cpuPercent: _asDoubleOrNull(j['cpuPercent']),
      cpuSeconds: _asDouble(j['cpuSeconds']),
      eventLoopP50: _asDouble(elMap['p50']),
      eventLoopP99: _asDouble(elMap['p99']),
    );
  }
}

/// One agent's surface, tagged with its session. `procs`/`uptimeMs` are
/// **absent** on coarse (background-cadence) frames, so they are nullable —
/// not defaulted to 0.
class AgentMetrics extends SurfaceMetrics {
  const AgentMetrics({
    required super.pid,
    required super.rssBytes,
    required super.cpuPercent,
    required super.cpuSeconds,
    required this.sessionId,
    required this.label,
    required this.inTurn,
    this.procs,
    this.uptimeMs,
  });

  final String sessionId;
  final String label;
  final bool inTurn;

  /// Process count in this agent's tree, or null on coarse frames.
  final int? procs;

  /// Agent uptime in ms, or null on coarse frames.
  final int? uptimeMs;

  static AgentMetrics? fromJson(Map<String, dynamic> j) {
    if (j['pid'] is! num) return null;
    if (j['sessionId'] is! String || j['label'] is! String) return null;
    return AgentMetrics(
      pid: _asInt(j['pid']),
      rssBytes: _asInt(j['rssBytes']),
      cpuPercent: _asDoubleOrNull(j['cpuPercent']),
      cpuSeconds: _asDouble(j['cpuSeconds']),
      sessionId: j['sessionId'] as String,
      label: j['label'] as String,
      inTurn: j['inTurn'] == true,
      procs: _asIntOrNull(j['procs']),
      uptimeMs: _asIntOrNull(j['uptimeMs']),
    );
  }
}

/// Socket throughput for this tick.
class WireMetrics {
  const WireMetrics({
    required this.inBytesPerSec,
    required this.outBytesPerSec,
    required this.framesPerSec,
  });

  final double inBytesPerSec;
  final double outBytesPerSec;
  final double framesPerSec;

  static WireMetrics fromJson(Map<String, dynamic> j) => WireMetrics(
    inBytesPerSec: _asDouble(j['inBytesPerSec']),
    outBytesPerSec: _asDouble(j['outBytesPerSec']),
    framesPerSec: _asDouble(j['framesPerSec']),
  );
}

/// Event-log size, refreshed only every 6th tick (null otherwise).
class StorageMetrics {
  const StorageMetrics({required this.eventLogBytes});

  final int eventLogBytes;

  static StorageMetrics fromJson(Map<String, dynamic> j) =>
      StorageMetrics(eventLogBytes: _asInt(j['eventLogBytes']));
}

/// The meter's own cost — the feature exists to keep this tiny.
class SamplerMetrics {
  const SamplerMetrics({required this.cpuPercent, required this.rssBytes});

  /// Nullable for the same reason as [SurfaceMetrics.cpuPercent].
  final double? cpuPercent;

  /// **Null by design** (SPEC-37 decision 16): the sampler runs inside the
  /// server process, so its resident share is not separately attributable.
  /// The server previously sent `process.memoryUsage().rss` here, which merely
  /// restated the server row under an "own cost" label — the one dishonest
  /// number in the panel that exists to make the honesty claim falsifiable.
  final int? rssBytes;

  static SamplerMetrics fromJson(Map<String, dynamic> j) => SamplerMetrics(
    cpuPercent: _asDoubleOrNull(j['cpuPercent']),
    rssBytes: _asIntOrNull(j['rssBytes']),
  );
}

/// One performance sample (`metrics.sample` event).
class MetricsSample {
  const MetricsSample({
    required this.ts,
    required this.app,
    required this.server,
    required this.agents,
    required this.wire,
    required this.storage,
    required this.sampler,
    required this.turnActive,
    required this.procTableOk,
  });

  /// Epoch ms.
  final int ts;

  /// The desktop app surface, or null when no loopback client reported a pid,
  /// **or** when [procTableOk] is false (the server could not look).
  final SurfaceMetrics? app;
  final ServerMetrics server;
  final List<AgentMetrics> agents;
  final WireMetrics wire;

  /// Event-log size, or null on ticks that did not refresh it.
  final StorageMetrics? storage;
  final SamplerMetrics sampler;
  final bool turnActive;

  /// `false` means the `ps` read failed: [agents] is empty and [app] is null
  /// because the server could not measure, not because they exited. The UI must
  /// distinguish "measurement unavailable" from an empty machine (decision 13).
  final bool procTableOk;

  /// Tolerant decode: returns null only when a required scalar ([ts]) or the
  /// [server] surface is unrecoverable, so the codec can `_warn` + skip without
  /// throwing into the frame stream.
  static MetricsSample? fromJson(Map<String, dynamic> j) {
    if (j['ts'] is! num) return null;
    final server = j['server'] is Map
        ? ServerMetrics.fromJson(Map<String, dynamic>.from(j['server'] as Map))
        : null;
    if (server == null) return null;

    final rawApp = j['app'];
    final app = rawApp is Map
        ? SurfaceMetrics.fromJson(Map<String, dynamic>.from(rawApp))
        : null;

    final agents =
        (j['agents'] is List ? j['agents'] as List : const <Object?>[])
            .whereType<Map<dynamic, dynamic>>()
            .map((m) => AgentMetrics.fromJson(Map<String, dynamic>.from(m)))
            .whereType<AgentMetrics>()
            .toList();

    final rawStorage = j['storage'];
    final storage = rawStorage is Map
        ? StorageMetrics.fromJson(Map<String, dynamic>.from(rawStorage))
        : null;

    return MetricsSample(
      ts: _asInt(j['ts']),
      app: app,
      server: server,
      agents: agents,
      wire: WireMetrics.fromJson(
        j['wire'] is Map
            ? Map<String, dynamic>.from(j['wire'] as Map)
            : const {},
      ),
      storage: storage,
      sampler: SamplerMetrics.fromJson(
        j['sampler'] is Map
            ? Map<String, dynamic>.from(j['sampler'] as Map)
            : const {},
      ),
      turnActive: j['turnActive'] == true,
      // Present-and-true or absent ⇒ ok; only an explicit `false` marks the
      // read as failed. Absent is the normal healthy case.
      procTableOk: j['procTableOk'] != false,
    );
  }
}

/// Latest metrics sample, or null before the first `metrics.sample` frame.
final metricsProvider = Provider<MetricsSample?>((ref) {
  final list = ref.watch(storeControllerProvider).metrics;
  return list.isEmpty ? null : list.last;
});

/// The bounded metrics ring (oldest first), for charts.
final metricsHistoryProvider = Provider<List<MetricsSample>>(
  (ref) => ref.watch(storeControllerProvider).metrics,
);

/// Ref-counted `metrics.watch` gate (spec §Design, App).
///
/// The Tier-1 popover and the Tier-2 dashboard can both be open at once. The
/// server must receive exactly **one** `metrics.watch {on:true}` for the pair
/// and `{on:false}` only when the last watcher closes — otherwise the sampler
/// is pinned at 1 Hz forever, in the feature whose point is proving makit is
/// cheap.
class MetricsWatchController {
  MetricsWatchController(this._setWatch);

  /// Sends `metrics.watch {on:...}`. Injected so the ref-count is unit-testable
  /// without a live socket.
  final void Function(bool on) _setWatch;

  int _watchers = 0;

  /// Number of live watchers; exposed for tests/diagnostics.
  int get watcherCount => _watchers;

  /// Register a watcher. Sends `{on:true}` only on the 0→1 transition.
  void watch() {
    _watchers++;
    if (_watchers == 1) _setWatch(true);
  }

  /// Release a watcher. Sends `{on:false}` only on the 1→0 transition; a
  /// release with no live watchers is a no-op (never sends a spurious off).
  void release() {
    if (_watchers == 0) return;
    _watchers--;
    if (_watchers == 0) _setWatch(false);
  }
}

/// Wires [MetricsWatchController] to the real socket, reusing the same
/// best-effort `cmd` request path as [StoreController.refreshGithubBudget].
final metricsWatchControllerProvider = Provider<MetricsWatchController>((ref) {
  final conn = ref.read(connectionControllerProvider.notifier);
  return MetricsWatchController((on) {
    unawaited(() async {
      try {
        await conn.request(MsgType.cmd, {'kind': 'metrics.watch', 'on': on});
      } catch (_) {
        // Best-effort: a failed watch toggle must never surface as an error.
        // The server re-broadcasts on the next level change regardless.
      }
    }());
  });
});
