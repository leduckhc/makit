/// Docs models + providers (SPEC-46).
///
/// Tolerant by construction, mirroring [PortInfo]/[MetricsSample]: a malformed
/// field degrades to a null/absent value rather than taking down the socket.
/// The semantically-nullable fields — [DocInfo.sessionId], [DocInfo.changed],
/// [DocInfo.docStatus] — are modelled as absent, never coerced: an absent
/// `changed` is "undetermined", NOT "unchanged", and an absent `docStatus` is
/// "unstated", NOT "" (D5/D14, the BudgetBucket/SurfaceMetrics rule).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../transport/protocol.dart';
import '../transport/transport.dart';
import 'connection.dart';
import 'store.dart';

/// The two document kinds P1 indexes. HTML has warm accent, markdown cool
/// (mockup Card 2); the enum is the single source both the glyph and the row
/// read, so the two cannot drift.
enum DocKind { md, html }

DocKind? _parseKind(Object? v) => switch (v) {
  'md' => DocKind.md,
  'html' => DocKind.html,
  _ => null,
};

String? _asStringOrNull(Object? v) => v is String ? v : null;

/// One renderable document inside a worktree (SPEC-46 `DocDTO`).
class DocInfo {
  const DocInfo({
    required this.key,
    required this.relPath,
    required this.title,
    required this.kind,
    required this.bytes,
    required this.modifiedAt,
    required this.worktreePath,
    this.sessionId,
    this.changed,
    this.docStatus,
  });

  /// Snapshot key `<worktreePath>:<relPath>`, NOT an identity (D3). The UI
  /// re-selects by `(worktreePath, relPath)`.
  final String key;

  /// Worktree-relative POSIX path, e.g. `mockups/open-ports.html`.
  final String relPath;

  /// The extracted human title (D4) — `<title>` / first H1 / basename, never
  /// the raw filename when the file carries a better name.
  final String title;

  final DocKind kind;
  final int bytes;

  /// Epoch ms of the file mtime; rows sort by this, descending.
  final int modifiedAt;
  final String worktreePath;

  /// Session that last wrote it; absent (never guessed) when unknown.
  final String? sessionId;

  /// True when the file differs from the branch merge base (D5). **Absent when
  /// undetermined** — a null `changed` must never render as "unchanged".
  final bool? changed;

  /// Parsed from a leading `**Status:** …` line (D14). **Absent when unstated**
  /// — a doc without the line must not be labelled.
  final String? docStatus;

  /// Tolerant decode: returns null when a required scalar is unrecoverable (so
  /// the codec can drop just this entry). Absent optionals stay absent — a
  /// non-bool `changed` and a non-string `docStatus` both degrade to null
  /// rather than a fabricated `false`/`""`.
  static DocInfo? fromJson(Map<String, dynamic> j) {
    final key = j['key'];
    final relPath = j['relPath'];
    final title = j['title'];
    final worktreePath = j['worktreePath'];
    final kind = _parseKind(j['kind']);
    if (key is! String ||
        relPath is! String ||
        title is! String ||
        worktreePath is! String ||
        kind == null ||
        j['bytes'] is! num ||
        j['modifiedAt'] is! num) {
      return null;
    }
    return DocInfo(
      key: key,
      relPath: relPath,
      title: title,
      kind: kind,
      bytes: (j['bytes'] as num).toInt(),
      modifiedAt: (j['modifiedAt'] as num).toInt(),
      worktreePath: worktreePath,
      sessionId: _asStringOrNull(j['sessionId']),
      // A non-bool `changed` is undetermined, not false — stays null.
      changed: j['changed'] is bool ? j['changed'] as bool : null,
      docStatus: _asStringOrNull(j['docStatus']),
    );
  }
}

/// One host-wide document index (`docs.snapshot` event, SPEC-46 D11).
class DocsSnapshot {
  const DocsSnapshot({
    required this.docs,
    required this.scannedAt,
    required this.scanOk,
    this.scanError,
  });

  final List<DocInfo> docs;

  /// Epoch ms this walk completed.
  final int scannedAt;

  /// True when the walk ran (not that the list is complete) — the
  /// [PortsSnapshot.scanOk] rule.
  final bool scanOk;

  /// One-line reason when [scanOk] is false.
  final String? scanError;

  /// Tolerant decode: malformed doc entries are dropped, the rest survive.
  /// Returns null when the snapshot's own required scalars are unrecoverable,
  /// so a truncated frame is dropped whole rather than fabricated into a
  /// "healthy and empty" scan (the [PortsSnapshot.fromJson] discipline).
  static DocsSnapshot? fromJson(Map<String, dynamic> j) {
    if (j['scannedAt'] is! num || j['docs'] is! List || j['scanOk'] is! bool) {
      return null;
    }
    final docs = (j['docs'] as List)
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => DocInfo.fromJson(Map<String, dynamic>.from(m)))
        .whereType<DocInfo>()
        .toList();
    return DocsSnapshot(
      docs: docs,
      scannedAt: (j['scannedAt'] as num).toInt(),
      scanOk: j['scanOk'] as bool,
      scanError: _asStringOrNull(j['scanError']),
    );
  }
}

/// Where a published doc can be reached (SPEC-46 D15). `tailnet` when
/// `tailscale serve` fronted it, `lan` for the explicitly-labelled fallback.
enum DocReach { tailnet, lan }

DocReach? _parseReach(Object? v) => switch (v) {
  'tailnet' => DocReach.tailnet,
  'lan' => DocReach.lan,
  _ => null,
};

/// An active publication of one document (SPEC-46 `DocGrantDTO`, D9). The
/// `grantId` is the capability — 32 bytes of CSPRNG, treated as secret.
class DocGrant {
  const DocGrant({
    required this.grantId,
    required this.worktreePath,
    required this.relPath,
    required this.url,
    required this.reach,
    required this.expiresAt,
  });

  final String grantId;
  final String worktreePath;
  final String relPath;

  /// The full URL to hand over; never `localhost`.
  final String url;
  final DocReach reach;
  final int expiresAt;

  /// Tolerant decode: returns null when a required scalar is unrecoverable —
  /// including an unknown `reach`, so the app never renders a grant it cannot
  /// honestly label (D15).
  static DocGrant? fromJson(Map<String, dynamic> j) {
    final grantId = j['grantId'];
    final worktreePath = j['worktreePath'];
    final relPath = j['relPath'];
    final url = j['url'];
    final reach = _parseReach(j['reach']);
    if (grantId is! String ||
        worktreePath is! String ||
        relPath is! String ||
        url is! String ||
        reach == null ||
        j['expiresAt'] is! num) {
      return null;
    }
    return DocGrant(
      grantId: grantId,
      worktreePath: worktreePath,
      relPath: relPath,
      url: url,
      reach: reach,
      expiresAt: (j['expiresAt'] as num).toInt(),
    );
  }

  /// Parse a `docs.publish` **ack**, whose grant is nested under `grant`
  /// (`ctx.ack({grant})` in `server/src/ws/commands/docs.ts`).
  ///
  /// Reading the ack flat yields null for every real publish, which surfaces as
  /// "returned an unusable grant" — so the nesting lives here, once, with a test
  /// on the actual wire shape rather than on a hand-built DocGrant.
  static DocGrant? fromAck(Map<String, dynamic> ack) {
    final grant = ack['grant'];
    if (grant is! Map) return null;
    return fromJson(Map<String, dynamic>.from(grant));
  }
}

/// Documents owned by the worktree at [path], mtime-descending (D5) — the doc
/// you want is the one you just made. Pure so it backs both the provider and
/// its test without a container (mirrors [portsForWorktree]).
List<DocInfo> docsForWorktree(DocsSnapshot? snapshot, String path) {
  if (snapshot == null) return const [];
  return snapshot.docs.where((d) => d.worktreePath == path).toList()
    ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
}

/// Latest docs snapshot, or null before the first `docs.snapshot` frame.
final docsProvider = Provider<DocsSnapshot?>(
  (ref) => ref.watch(storeControllerProvider).docs,
);

/// Documents owned by a worktree, mtime-descending. Derived here, never in a
/// widget.
final docsForWorktreeProvider = Provider.family<List<DocInfo>, String>(
  (ref, path) => docsForWorktree(ref.watch(docsProvider), path),
);

/// Ref-counted `docs.watch` gate, mirroring [PortsWatch]. The server must
/// receive exactly one `docs.watch {on:true}` for the set and `{on:false}` only
/// when the last holder releases — otherwise the index walks forever in the
/// feature whose whole point is that it doesn't when nobody is looking (D11).
class DocsWatch {
  DocsWatch(this._setWatch);

  /// Sends `docs.watch {on:...}`. Injected so the ref-count is unit-testable
  /// without a live socket.
  final void Function(bool on) _setWatch;

  int _watchers = 0;

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

/// Wires [DocsWatch] to the socket, capturing the connection controller so the
/// send is dispose-safe. Fire-and-forget via `send` (not `request`): the watch
/// needs no ack, and a `request` from `initState` would leak its 10 s
/// ack-timeout timer (the documented trap). Re-arms on reconnect, exactly like
/// [portsWatchProvider].
final docsWatchProvider = Provider<DocsWatch>((ref) {
  final conn = ref.read(connectionControllerProvider.notifier);
  void sendWatch(bool on) {
    conn.send(
      Envelope(
        t: MsgType.cmd,
        id: 'docs-watch-${DateTime.now().microsecondsSinceEpoch}',
        body: {'kind': 'docs.watch', 'on': on},
      ),
    );
  }

  final watch = DocsWatch(sendWatch);
  ref.listen<MakitConnState>(connectionControllerProvider, (prev, next) {
    final wasConnected = prev?.wsState == WsState.connected;
    final nowConnected = next.wsState == WsState.connected;
    if (!wasConnected && nowConnected && watch.watcherCount > 0) {
      sendWatch(true);
    }
  });
  return watch;
});
