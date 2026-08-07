/// Ports models + providers (SPEC-41).
///
/// Tolerant by construction, mirroring [MetricsSample]: a malformed field
/// degrades to a null/absent value rather than taking down the socket. The
/// semantically-nullable fields the feature turns on — [PortInfo.startedAt],
/// [PortInfo.worktreePath], [PortInfo.sessionId], [PortInfo.health],
/// [PortInfo.openUrl] — are modelled as absent, never coerced: a zero and an
/// "unknown" mean opposite things (the BudgetBucket/SurfaceMetrics rule), so
/// "not probed" must never render as a health of some default, and a missing
/// `openUrl` must hide `Open` rather than fabricate a URL.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../transport/protocol.dart';
import '../transport/transport.dart';
import 'connection.dart';
import 'store.dart';

/// Where a listening socket can be reached from (D2). Wildcard binds are
/// `exposed`, never `tailnet`.
enum PortReach { loopback, tailnet, exposed }

/// Verdict from one HTTP probe. Absent health means "not probed" (D3).
enum PortHealthKind { ok, httpError, refused, timeout }

PortReach? _parseReach(Object? v) => switch (v) {
  'loopback' => PortReach.loopback,
  'tailnet' => PortReach.tailnet,
  'exposed' => PortReach.exposed,
  _ => null,
};

PortHealthKind? _parseHealthKind(Object? v) => switch (v) {
  'ok' => PortHealthKind.ok,
  'http-error' => PortHealthKind.httpError,
  'refused' => PortHealthKind.refused,
  'timeout' => PortHealthKind.timeout,
  _ => null,
};

int? _asIntOrNull(Object? v) => v is num ? v.toInt() : null;

String? _asStringOrNull(Object? v) => v is String ? v : null;

/// One HTTP probe verdict. [status] is absent unless a status line was parsed
/// (D3); [probedAt] is required — it is what drives "probed N s ago".
class PortHealth {
  const PortHealth({required this.kind, required this.probedAt, this.status});

  final PortHealthKind kind;

  /// HTTP status when one was parsed (200, 404, 500); absent otherwise.
  final int? status;

  /// Epoch ms of the probe that produced this verdict.
  final int probedAt;

  /// Tolerant: a malformed kind or a missing [probedAt] yields null so the
  /// caller drops health without dropping the port — a bad probe is not a bad
  /// port.
  static PortHealth? fromJson(Map<String, dynamic> j) {
    final kind = _parseHealthKind(j['kind']);
    if (kind == null) return null;
    if (j['probedAt'] is! num) return null;
    return PortHealth(
      kind: kind,
      probedAt: (j['probedAt'] as num).toInt(),
      status: _asIntOrNull(j['status']),
    );
  }
}

/// SPEC-42 D10. Why a listener is an orphan: its process cwd sits under a
/// worktree that history records as removed, so nothing but the user will ever
/// reclaim the port. Every field is individually optional (the absent-stays-
/// absent rule): makit can prove the cwd is a dead worktree while knowing
/// neither its branch nor when it went, and a fabricated "removed 0d ago" is
/// exactly the "up 56y" lie [portUptimeLabel] refuses to tell.
class PortOrphan {
  const PortOrphan({
    this.formerBranch,
    this.formerWorktreePath,
    this.removedAt,
  });

  /// Branch the removed worktree was on, when history recorded it.
  final String? formerBranch;

  /// Absolute path of the worktree that is gone.
  final String? formerWorktreePath;

  /// Epoch ms the worktree was last seen active; absent ⇒ render NO date (D10).
  final int? removedAt;

  /// Tolerant decode of an orphan sub-object. The presence of the object is
  /// what marks the port orphaned, so this never returns null for a map — each
  /// field degrades to absent independently, never coerced (a bad `removedAt`
  /// stays null, never 0). The caller drops a non-map orphan to null while
  /// keeping the port.
  static PortOrphan fromJson(Map<String, dynamic> j) => PortOrphan(
    formerBranch: _asStringOrNull(j['formerBranch']),
    formerWorktreePath: _asStringOrNull(j['formerWorktreePath']),
    removedAt: _asIntOrNull(j['removedAt']),
  );
}

/// SPEC-42 D12. The rival claimant for a port: another still-active worktree
/// that history says also binds it, so a dev server started here would fail to
/// bind. Both fields are optional for the same absent-stays-absent reason.
class PortCollision {
  const PortCollision({this.withBranch, this.withWorktreePath});

  /// Branch of the other worktree that history says also uses this port.
  final String? withBranch;

  /// Absolute path of that worktree.
  final String? withWorktreePath;

  /// Tolerant decode; never null for a map (see [PortOrphan.fromJson]).
  static PortCollision fromJson(Map<String, dynamic> j) => PortCollision(
    withBranch: _asStringOrNull(j['withBranch']),
    withWorktreePath: _asStringOrNull(j['withWorktreePath']),
  );
}

/// One listening TCP port attributed (best-effort) to a worktree.
class PortInfo {
  const PortInfo({
    required this.key,
    required this.port,
    required this.address,
    required this.reach,
    required this.pid,
    required this.command,
    this.startedAt,
    this.worktreePath,
    this.sessionId,
    this.health,
    this.openUrl,
    this.orphan,
    this.collision,
  });

  /// Snapshot key, NOT an identity: `<pid>:<address>:<port>` (D6).
  final String key;
  final int port;
  final String address;
  final PortReach reach;
  final int pid;
  final String command;

  /// Epoch ms the process started; absent when unparsable (never epoch 0).
  final int? startedAt;

  /// Absolute worktree path that owns this port; absent when unowned.
  final String? worktreePath;

  /// Session whose process tree contains [pid], when there is one.
  final String? sessionId;

  /// Absent until probed, and absent forever for ports P1 does not probe (D3).
  final PortHealth? health;

  /// Canonical URL to open; absent ⇒ the UI hides Open / Copy URL rather than
  /// guessing.
  final String? openUrl;

  /// SPEC-42 D10: this port outlived its worktree; absent unless orphaned.
  final PortOrphan? orphan;

  /// SPEC-42 D12: another active worktree also binds this port; absent unless
  /// a collision was derived.
  final PortCollision? collision;

  /// Tolerant decode: returns null when a required scalar is unrecoverable
  /// (so the codec can drop just this entry). Absent optionals stay absent.
  static PortInfo? fromJson(Map<String, dynamic> j) {
    final key = j['key'];
    final address = j['address'];
    final command = j['command'];
    final reach = _parseReach(j['reach']);
    if (key is! String ||
        address is! String ||
        command is! String ||
        reach == null ||
        j['port'] is! num ||
        j['pid'] is! num) {
      return null;
    }
    final rawHealth = j['health'];
    final health = rawHealth is Map
        ? PortHealth.fromJson(Map<String, dynamic>.from(rawHealth))
        : null;
    // Tolerant: a malformed (non-map) annotation drops to null WITHOUT dropping
    // the port — a bad annotation must never lose a real listener (the
    // PortHealth precedent).
    final rawOrphan = j['orphan'];
    final orphan = rawOrphan is Map
        ? PortOrphan.fromJson(Map<String, dynamic>.from(rawOrphan))
        : null;
    final rawCollision = j['collision'];
    final collision = rawCollision is Map
        ? PortCollision.fromJson(Map<String, dynamic>.from(rawCollision))
        : null;
    return PortInfo(
      key: key,
      port: (j['port'] as num).toInt(),
      address: address,
      reach: reach,
      pid: (j['pid'] as num).toInt(),
      command: command,
      startedAt: _asIntOrNull(j['startedAt']),
      worktreePath: j['worktreePath'] is String
          ? j['worktreePath'] as String
          : null,
      sessionId: j['sessionId'] is String ? j['sessionId'] as String : null,
      health: health,
      openUrl: j['openUrl'] is String ? j['openUrl'] as String : null,
      orphan: orphan,
      collision: collision,
    );
  }
}

/// One host-wide ports scan (`ports.snapshot` event).
class PortsSnapshot {
  const PortsSnapshot({
    required this.ports,
    required this.scannedAt,
    required this.scanOk,
    this.scanError,
  });

  final List<PortInfo> ports;

  /// Epoch ms this scan completed.
  final int scannedAt;

  /// True when the scanner's commands ran (D7). It does NOT claim the whole
  /// machine was visible — attribution is best-effort.
  final bool scanOk;

  /// One-line reason when [scanOk] is false; rendered in the glyph's tooltip.
  final String? scanError;

  /// Tolerant decode: malformed port entries are dropped, the rest survive.
  /// Returns null when the snapshot's own required scalars are unrecoverable,
  /// so a truncated/malformed frame is dropped whole rather than fabricated
  /// into a "healthy and empty" scan.
  ///
  /// A missing `ports` or `scanOk` is exactly that fabrication risk: coercing a
  /// missing `ports` to `[]` would silently erase every glyph, and a missing
  /// `scanOk` to `true` would claim a scan that never reported succeeded — the
  /// opposite of the BudgetBucket/SurfaceMetrics rule that absence is never a
  /// value. Both are required; only the *entries* inside a valid list are
  /// dropped individually.
  static PortsSnapshot? fromJson(Map<String, dynamic> j) {
    if (j['scannedAt'] is! num || j['ports'] is! List || j['scanOk'] is! bool) {
      return null;
    }
    final ports = (j['ports'] as List)
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => PortInfo.fromJson(Map<String, dynamic>.from(m)))
        .whereType<PortInfo>()
        .toList();
    return PortsSnapshot(
      ports: ports,
      scannedAt: (j['scannedAt'] as num).toInt(),
      scanOk: j['scanOk'] as bool,
      scanError: j['scanError'] is String ? j['scanError'] as String : null,
    );
  }
}

/// What the row glyph should say. `unknown` is the honest state when the scan
/// itself failed (D7) — never a fake "nothing listening".
enum PortsGlyphState { none, serving, exposed, attention, unknown }

/// Ports owned by the worktree at [path], ascending by port then pid. Pure so
/// it can back both the provider and its test without a container.
List<PortInfo> portsForWorktree(PortsSnapshot? snapshot, String path) {
  if (snapshot == null) return const [];
  final list = snapshot.ports.where((p) => p.worktreePath == path).toList()
    ..sort((a, b) {
      final byPort = a.port.compareTo(b.port);
      return byPort != 0 ? byPort : a.pid.compareTo(b.pid);
    });
  return list;
}

/// The glyph-state ladder (pure). `unknown` (scan failed) wins over everything
/// because a failed scan cannot prove a worktree has no ports; then attention
/// (a port bound but not answering) beats a merely exposed reach.
PortsGlyphState portsGlyphState(PortsSnapshot? snapshot, String path) {
  if (snapshot == null) return PortsGlyphState.none;
  if (!snapshot.scanOk) return PortsGlyphState.unknown;
  final ports = portsForWorktree(snapshot, path);
  if (ports.isEmpty) return PortsGlyphState.none;
  final attention = ports.any(
    (p) =>
        p.health?.kind == PortHealthKind.refused ||
        p.health?.kind == PortHealthKind.timeout,
  );
  if (attention) return PortsGlyphState.attention;
  if (ports.any((p) => p.reach == PortReach.exposed)) {
    return PortsGlyphState.exposed;
  }
  return PortsGlyphState.serving;
}

/// Latest ports snapshot, or null before the first `ports.snapshot` frame.
final portsProvider = Provider<PortsSnapshot?>(
  (ref) => ref.watch(storeControllerProvider).ports,
);

/// Ports owned by a worktree, filtered + sorted. Derived here, never in a
/// widget.
final portsForWorktreeProvider = Provider.family<List<PortInfo>, String>(
  (ref, path) => portsForWorktree(ref.watch(portsProvider), path),
);

/// The row-glyph state for a worktree (SPEC-41 §1).
final portsGlyphStateProvider = Provider.family<PortsGlyphState, String>(
  (ref, path) => portsGlyphState(ref.watch(portsProvider), path),
);

/// Ref-counted `ports.watch` gate, mirroring [MetricsWatchController].
///
/// The home screen (mobile) and the sidebar (desktop) can both hold the watch
/// at once, and a single sidebar can mount many rows. The server must receive
/// exactly one `ports.watch {on:true}` for the set and `{on:false}` only when
/// the last holder releases — otherwise `lsof` polls forever in the feature
/// whose whole point is that it doesn't when nobody is looking.
class PortsWatch {
  PortsWatch(this._setWatch);

  /// Sends `ports.watch {on:...}`. Injected so the ref-count is unit-testable
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
  /// release with no live watchers is a no-op.
  void release() {
    if (_watchers == 0) return;
    _watchers--;
    if (_watchers == 0) _setWatch(false);
  }
}

/// Wires [PortsWatch] to the socket, capturing the connection controller so the
/// send is dispose-safe (a row disposing after the container is torn down must
/// not touch a disposed provider ref). Fire-and-forget via `send` (not
/// `request`), exactly like `sub`: the watch needs no ack.
///
/// Re-arms on reconnect: the server forgets per-client watchers on disconnect,
/// so a still-held watch must re-send `{on:true}` when the socket returns — the
/// same `ref.listen(connectionControllerProvider, …)` + `wasConnected`/
/// `nowConnected` guard `StoreController` uses to replay `sub`s and the budget
/// watch. Without it the row glyphs freeze after any blip.
final portsWatchProvider = Provider<PortsWatch>((ref) {
  final conn = ref.read(connectionControllerProvider.notifier);
  void sendWatch(bool on) {
    conn.send(
      Envelope(
        t: MsgType.cmd,
        id: 'ports-watch-${DateTime.now().microsecondsSinceEpoch}',
        body: {'kind': 'ports.watch', 'on': on},
      ),
    );
  }

  final watch = PortsWatch(sendWatch);
  ref.listen<MakitConnState>(connectionControllerProvider, (prev, next) {
    final wasConnected = prev?.wsState == WsState.connected;
    final nowConnected = next.wsState == WsState.connected;
    if (!wasConnected && nowConnected && watch.watcherCount > 0) {
      sendWatch(true);
    }
  });
  return watch;
});
