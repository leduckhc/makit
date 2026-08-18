/// Ports models + providers (SPEC-open-ports).
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

/// SPEC-ports-global-view D10. Why a listener is an orphan: its process cwd sits under a
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

/// SPEC-ports-global-view D12. The rival claimant for a port: another still-active worktree
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

/// SPEC-ports-global-view D13. The container that published this port, so a listener held by
/// `com.docker.backend` stops reading as unowned system noise. Ownership only:
/// [PortInfo.reach] still reports the real bind, because "docker" would be the
/// reassuring reading of a `0.0.0.0` publish.
class PortDocker {
  const PortDocker({required this.container, this.compose});

  /// Container name as `docker ps` reports it.
  final String container;

  /// Compose file that defines the container, when its labels carry one.
  final String? compose;

  /// Tolerant decode. Unlike [PortOrphan]/[PortCollision] this CAN return null:
  /// [container] is the whole content of the annotation, so an object without a
  /// usable name says nothing and is dropped — the port survives.
  static PortDocker? fromJson(Map<String, dynamic> j) {
    final container = _asStringOrNull(j['container']);
    if (container == null || container.isEmpty) return null;
    return PortDocker(
      container: container,
      compose: _asStringOrNull(j['compose']),
    );
  }
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
    this.docker,
    this.watched = false,
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

  /// SPEC-ports-global-view D10: this port outlived its worktree; absent unless orphaned.
  final PortOrphan? orphan;

  /// SPEC-ports-global-view D12: another active worktree also binds this port; absent unless
  /// a collision was derived.
  final PortCollision? collision;

  /// SPEC-ports-global-view D13: the container that published this port; absent when this is
  /// not a container port, or when no docker daemon could be read at all.
  final PortDocker? docker;

  /// SPEC-ports-forward D7: the user asked to be told if this endpoint stops listening.
  ///
  /// A plain bool, not a nullable one: unlike every OTHER optional field here,
  /// "absent" and "false" mean the same thing for a watch (nobody asked), so
  /// there is no unknown state to protect.
  final bool watched;

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
    final rawDocker = j['docker'];
    final docker = rawDocker is Map
        ? PortDocker.fromJson(Map<String, dynamic>.from(rawDocker))
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
      docker: docker,
      watched: j['watched'] == true,
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

/// The row-glyph state for a worktree (SPEC-open-ports §1).
final portsGlyphStateProvider = Provider.family<PortsGlyphState, String>(
  (ref, path) => portsGlyphState(ref.watch(portsProvider), path),
);

/// Ref-counted `ports.watch` gate, mirroring [MetricsWatchController].
///
/// The endpoint a kill names, captured from the row the user was looking at
/// (SPEC-ports-kill D1/D8): the confirm dialog names this tuple and the command carries
/// exactly it, so the server can re-verify that the process it signals is the
/// one the user saw.
class PortKillTarget {
  const PortKillTarget({
    required this.address,
    required this.port,
    required this.pid,
    required this.startedAt,
  });

  final String address;
  final int port;
  final int pid;

  /// Epoch ms the process started — required, unlike [PortInfo.startedAt].
  final int startedAt;

  /// The target for [port], or **null** when its start time is unknown.
  ///
  /// Null is a refusal, not a fallback: without a start time the server cannot
  /// tell this process from a later one that reused its pid (D1), so the UI must
  /// not offer to kill it at all.
  static PortKillTarget? of(PortInfo port) {
    final startedAt = port.startedAt;
    if (startedAt == null) return null;
    return PortKillTarget(
      address: port.address,
      port: port.port,
      pid: port.pid,
      startedAt: startedAt,
    );
  }

  Map<String, dynamic> toCommand() => {
    'kind': 'ports.kill',
    'address': address,
    'port': port,
    'pid': pid,
    'startedAt': startedAt,
  };
}

/// What became of a kill (SPEC-ports-kill D2/D3). Mirrors the server's `PortKillOutcome`
/// plus [failed], which the server never sends — see [parsePortKillOutcome].
enum PortKillOutcome {
  released,
  forceKilled,
  survived,
  notFound,
  identityMismatch,
  notOwned,
  refusedProtected,
  refusedSelf,
  refusedSession,
  scanUnavailable,

  /// The request failed, or answered with something this build does not know.
  /// Local only: it exists so an unrecognised answer can never be mistaken for
  /// a success.
  failed;

  /// Whether the endpoint is actually free now. Only these two mean "gone".
  bool get releasedThePort =>
      this == PortKillOutcome.released || this == PortKillOutcome.forceKilled;
}

/// Tolerant decode of the ack's `outcome`. Anything unrecognised (a newer
/// server, a truncated frame, a null) becomes [PortKillOutcome.failed]: the one
/// rule that must never bend is that an answer we cannot read is not a success.
PortKillOutcome parsePortKillOutcome(Object? v) => switch (v) {
  'released' => PortKillOutcome.released,
  'force-killed' => PortKillOutcome.forceKilled,
  'survived' => PortKillOutcome.survived,
  'not_found' => PortKillOutcome.notFound,
  'identity_mismatch' => PortKillOutcome.identityMismatch,
  'not_owned' => PortKillOutcome.notOwned,
  'refused_protected' => PortKillOutcome.refusedProtected,
  'refused_self' => PortKillOutcome.refusedSelf,
  'refused_session' => PortKillOutcome.refusedSession,
  'scan_unavailable' => PortKillOutcome.scanUnavailable,
  _ => PortKillOutcome.failed,
};

/// Sends `ports.kill` and reports what happened.
///
/// Uses the socket's **request** path, unlike [PortsWatch]'s fire-and-forget
/// `send`: the whole point of a kill is the outcome, and every refusal is an ack
/// the user must be shown. A transport failure degrades to
/// [PortKillOutcome.failed] rather than throwing into a button handler.
class PortsKiller {
  PortsKiller(this._request);

  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body)
  _request;

  Future<PortKillOutcome> kill(PortKillTarget target) async {
    try {
      final reply = await _request(target.toCommand());
      return parsePortKillOutcome(reply['outcome']);
    } catch (_) {
      return PortKillOutcome.failed;
    }
  }

  /// SPEC-ports-kill P3b: kill every orphan the SERVER currently sees, and report one
  /// outcome per endpoint.
  ///
  /// The endpoints are deliberately not named by the client: the orphan set is
  /// derived from the server's fresh scan (D5), which is also what stops this
  /// from becoming "kill this arbitrary list". An unreadable answer degrades to a
  /// single [PortKillOutcome.failed], never to an empty (= "nothing to do") list.
  Future<List<PortKillOutcome>> killOrphans() async {
    try {
      final reply = await _request({'kind': 'ports.killOrphans'});
      final results = reply['results'];
      if (results is! List) return const [PortKillOutcome.failed];
      return [
        for (final r in results)
          parsePortKillOutcome(r is Map ? r['outcome'] : null),
      ];
    } catch (_) {
      return const [PortKillOutcome.failed];
    }
  }
}

/// A minted forward: what to open, and when it dies (SPEC-ports-forward P4b).
class ForwardGrant {
  const ForwardGrant({
    required this.grantId,
    required this.port,
    required this.path,
    required this.expiresAt,
    required this.browser,
  });

  final String grantId;
  final int port;

  /// Path on the makit listener, e.g. `/forward/<grantId>/`. The client joins it
  /// to the origin it is already connected to — only the client knows which of
  /// the host's addresses it can actually reach.
  final String path;

  /// Epoch ms the grant dies regardless of activity.
  final int expiresAt;

  /// True when the id alone authorises, because the consumer is the system
  /// browser and cannot send an `Authorization` header.
  final bool browser;

  /// Tolerant decode; null when the ack is missing anything the client must have.
  static ForwardGrant? fromJson(Map<String, dynamic> j) {
    final grantId = _asStringOrNull(j['grantId']);
    final path = _asStringOrNull(j['path']);
    final port = _asIntOrNull(j['port']);
    final expiresAt = _asIntOrNull(j['expiresAt']);
    if (grantId == null || path == null || port == null || expiresAt == null) {
      return null;
    }
    return ForwardGrant(
      grantId: grantId,
      port: port,
      path: path,
      expiresAt: expiresAt,
      browser: j['browser'] == true,
    );
  }
}

/// The result of asking for a forward: a grant, or the server's reason.
class ForwardResult {
  const ForwardResult({this.grant, this.refusal});

  final ForwardGrant? grant;

  /// The server's one-line reason, shown verbatim — it names the actual rule
  /// ("database and shell ports are never forwarded"), which a generic failure
  /// could not.
  final String? refusal;
}

/// Mints and revokes forwards (SPEC-ports-forward P4b).
class PortsForwarder {
  PortsForwarder(this._request);

  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body)
  _request;

  /// Ask for a forward of [port] owned by [worktreePath].
  ///
  /// [browser] declares that the URL is going to the user's own browser, which
  /// cannot send a bearer — so the grant id becomes the capability. Passed
  /// explicitly rather than assumed, because it is the weaker mode.
  Future<ForwardResult> forward({
    required String worktreePath,
    required int port,
    bool browser = false,
  }) async {
    try {
      final reply = await _request({
        'kind': 'ports.forward',
        'worktreePath': worktreePath,
        'port': port,
        'browser': browser,
      });
      final raw = reply['grant'];
      final grant = raw is Map
          ? ForwardGrant.fromJson(Map<String, dynamic>.from(raw))
          : null;
      if (grant == null) {
        return const ForwardResult(
          refusal: 'the server did not mint a forward',
        );
      }
      return ForwardResult(grant: grant);
    } catch (e) {
      // The server errs with the REASON for a refusal (unlike a kill, where every
      // refusal is an ack), so the message is the useful part.
      return ForwardResult(refusal: _reasonFrom(e));
    }
  }

  /// Revoke a forward. Best-effort: an already-dead grant is a success.
  Future<void> stop(String grantId) async {
    try {
      await _request({'kind': 'ports.forward.stop', 'grantId': grantId});
    } catch (_) {
      // The grant expires on its own within 30 min and is idle-reaped in 60 s, so
      // a lost `stop` is not a leak worth surfacing.
    }
  }

  static String _reasonFrom(Object error) {
    final message = error is StateError ? error.message : error.toString();
    return message.isEmpty ? 'could not forward that port' : message;
  }
}

/// Wires [PortsForwarder] to the socket's request path.
final portsForwarderProvider = Provider<PortsForwarder>((ref) {
  final conn = ref.read(connectionControllerProvider.notifier);
  return PortsForwarder((body) => conn.request(MsgType.cmd, body));
});

/// Toggles the persisted "tell me if this stops listening" flag (SPEC-ports-forward D7).
///
/// Identified by `(worktreePath, port)`, never the snapshot key: the point of a
/// watch is to survive the dev-server restart that changes the pid.
class PortsWatchPort {
  PortsWatchPort(this._request);

  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body)
  _request;

  /// Returns true when the server acked the write. False on any failure, so the
  /// UI can revert its toggle instead of showing a watch that does not exist.
  Future<bool> set({
    required String worktreePath,
    required int port,
    required bool on,
  }) async {
    try {
      await _request({
        'kind': 'ports.watchPort',
        'worktreePath': worktreePath,
        'port': port,
        'on': on,
      });
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Wires [PortsWatchPort] to the socket's request path.
final portsWatchPortProvider = Provider<PortsWatchPort>((ref) {
  final conn = ref.read(connectionControllerProvider.notifier);
  return PortsWatchPort((body) => conn.request(MsgType.cmd, body));
});

/// Wires [PortsKiller] to the socket's request path.
final portsKillerProvider = Provider<PortsKiller>((ref) {
  final conn = ref.read(connectionControllerProvider.notifier);
  return PortsKiller((body) => conn.request(MsgType.cmd, body));
});

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
