/// The ports vocabulary (SPEC-open-ports §3): one string per terse token, so the three
/// consumers — the desktop [Tooltip], the mobile long-press bubble, and the
/// `Semantics.label` a screen reader speaks — cannot drift apart.
///
/// Pure functions, no widgets. The tooltip is also where **freshness** lives
/// (`· probed N s ago`), which a short pill cannot carry.
library;

import '../../store/ports.dart';

/// The two per-row actions P1 ships. Both are self-describing, so they get no
/// tooltip — their label IS the tooltip (spec §3, "no tooltip on a control that
/// already says what it does").
enum PortAction { open, copyUrl }

/// The label of the forward action (SPEC-ports-forward P4b). "Open in browser" and not
/// "Forward": what the user wants is the page, and the tunnel is the mechanism.
const String portForwardLabel = 'Open in browser';

/// The label of the destructive control (SPEC-ports-kill D8), one string so the desktop
/// button and the mobile row cannot drift.
const String portKillLabel = 'Kill';

/// The mobile sheet's version, past the danger divider — the … says a confirm
/// follows, the same promise every other destructive row in the app makes.
const String portKillRowLabel = 'Kill this process…';

/// The confirm's body (D8): it names the process, the pid, the port and the
/// branch, and states what will be sent. Never "Are you sure?" — a confirm the
/// user cannot check is not a mitigation, and this exact sentence is what makes
/// a stolen-phone kill readable before it happens.
String portKillConfirmBody(PortInfo port, {String? branchLabel}) {
  final where = (branchLabel != null && branchLabel.isNotEmpty)
      ? ' in $branchLabel'
      : '';
  return 'Sends SIGTERM (then SIGKILL if it ignores it) to '
      '${portRowToken(port)} (pid ${port.pid}) serving :${port.port}$where.';
}

/// The bulk-kill label, with the count the mockup asks for (§6).
String portKillOrphansLabel(int count) => 'Kill all orphans ($count)';

/// What to tell the user after a bulk kill: how many endpoints are actually free
/// now, and how many are not. A partial result is the normal case (D5), so the
/// sentence never rounds it up to "done".
String portKillOrphansMessage(List<PortKillOutcome> outcomes) {
  if (outcomes.isEmpty) return 'No orphans left to kill.';
  final freed = outcomes.where((o) => o.releasedThePort).length;
  final stuck = outcomes.length - freed;
  final head = freed == 1 ? '1 port released' : '$freed ports released';
  return stuck == 0 ? '$head.' : '$head, $stuck still listening.';
}

/// What to tell the user after an attempt. Every outcome earns its own sentence:
/// a refusal explains itself, and "released" is claimed only when the server
/// actually verified the endpoint was freed.
String portKillOutcomeMessage(
  PortKillOutcome outcome, {
  required int port,
}) => switch (outcome) {
  PortKillOutcome.released => ':$port released.',
  PortKillOutcome.forceKilled => ':$port ignored SIGTERM — force-killed.',
  PortKillOutcome.survived =>
    ':$port survived SIGKILL. It is not yours to kill — open a terminal.',
  PortKillOutcome.notFound => ':$port was already gone.',
  PortKillOutcome.identityMismatch =>
    ':$port changed since you looked — nothing was killed. Rescan and try '
        'again.',
  PortKillOutcome.notOwned =>
    ':$port belongs to no worktree, so makit will not signal it.',
  PortKillOutcome.refusedProtected =>
    ':$port is held by a system process — refused.',
  PortKillOutcome.refusedSelf =>
    ':$port is makit itself — refused. Stop the server instead.',
  PortKillOutcome.refusedSession =>
    ':$port belongs to an agent session — stop the session instead.',
  // Deliberately "not confirmed", not "nothing was killed": the server
  // returns this both BEFORE signalling (nothing happened) and when a
  // post-signal verification could not be read, so the only sentence true in
  // both cases is that the outcome is unknown.
  PortKillOutcome.scanUnavailable =>
    'Could not read this machine’s sockets, so :$port was not confirmed. '
        'Rescan to see where it stands.',
  PortKillOutcome.failed => 'The kill did not go through.',
};

/// Actions that already say what they do get no tooltip.
String? portActionTooltip(PortAction action) => null;

/// The severity a terse token carries, derived from the fact rather than picked
/// at each call site — so a 404 reads the same amber in the popover, both
/// sheets and the global screen. Widget-free on purpose: the theme colour for a
/// tone is resolved in `port_token_pill.dart`, the words live here.
enum PortTone {
  /// Answering, or reachable only where you meant it to be.
  ok,

  /// Alive but not serving (`404`), or reachable further than loopback.
  warn,

  /// Bound but unusable — a crashed server still holding its socket.
  err,

  /// No verdict yet (or none coming). Never coloured as a verdict.
  idle,
}

/// The tone for a health verdict. `refused`/`timeout` are [PortTone.err] and
/// not merely a warning, because they mean "you cannot use this" — a different
/// instruction from a 404's "it is up, just not mounted at `/`".
PortTone portHealthTone(PortHealth? health) {
  if (health == null) return PortTone.idle;
  return switch (health.kind) {
    PortHealthKind.ok => PortTone.ok,
    PortHealthKind.httpError => PortTone.warn,
    PortHealthKind.refused || PortHealthKind.timeout => PortTone.err,
  };
}

/// The tone for a reach. `exposed` is the only security-relevant value, so it
/// is the one that must not be grey (mockup 116–118); `loopback` — the safe,
/// overwhelmingly common case — stays [PortTone.idle] so a list of them is calm.
PortTone portReachTone(PortReach reach) => switch (reach) {
  PortReach.loopback => PortTone.idle,
  PortReach.tailnet => PortTone.ok,
  PortReach.exposed => PortTone.warn,
};

/// Short pill text for a health verdict, or "not probed" when absent. The
/// glance form; [portHealthTooltip] is the explanation.
String portHealthPill(PortHealth? health) {
  if (health == null) return 'not probed';
  return switch (health.kind) {
    PortHealthKind.ok => '${health.status ?? 200}',
    PortHealthKind.httpError => '${health.status ?? 'error'}',
    PortHealthKind.refused => 'refused',
    PortHealthKind.timeout => 'timeout',
  };
}

/// The full health sentence, ending in the probe age — the honest admission
/// that the verdict is cached (stale-while-revalidate, D-cost section).
String portHealthTooltip(PortHealth? health, {required int nowMs}) {
  if (health == null) {
    // Covers both "unowned/deny-listed" and "first tick" — the socket facts are
    // instant, the probe lands on the next pass.
    return 'Not probed — the socket facts are instant; a health check lands on '
        'the next scan (or this port is not one P1 probes).';
  }
  final age = _probeAge(health.probedAt, nowMs);
  final body = switch (health.kind) {
    PortHealthKind.ok =>
      'HTTP GET / → ${health.status ?? 200} ${_statusName(health.status)} — '
          'answering.',
    PortHealthKind.httpError => () {
      // An explicit fallback so the sentence is always complete: the tolerant
      // decoder permits a null status, and an unrecognised code has no reason
      // phrase, so the head must never collapse to a hole (`→  —`).
      final status = health.status;
      final head = status == null
          ? 'an error'
          : '$status ${_statusName(status)}'.trim();
      return 'HTTP GET / → $head — '
          "it's alive, but nothing is mounted at the root.";
    }(),
    PortHealthKind.refused =>
      'TCP connect refused — the port is bound but nothing is accepting. '
          'Usually a crashed dev server holding its socket.',
    PortHealthKind.timeout =>
      'Connected, but no response in 800 ms — probably wedged, not dead.',
  };
  return '$body · $age';
}

/// The reach sentence — the security vocabulary.
String portReachTooltip(PortReach reach) => switch (reach) {
  PortReach.loopback =>
    'Bound to loopback — reachable only from this machine. Your phone cannot '
        'see it without forwarding.',
  PortReach.tailnet =>
    'Bound to this machine’s tailnet address — reachable by devices on your '
        'tailnet, but not the local Wi-Fi.',
  PortReach.exposed =>
    'Bound to a wildcard address — reachable from every interface, including '
        'whatever Wi-Fi you are on right now.',
};

/// Short uppercase pill text for the reach token.
String portReachPill(PortReach reach) => switch (reach) {
  PortReach.loopback => 'loopback',
  PortReach.tailnet => 'tailnet',
  PortReach.exposed => 'exposed',
};

/// The one word that ships with the orphan tint, so colour is never the only
/// signal (SPEC-open-ports's accessibility rule, spec §9).
const String portOrphanWord = 'orphan';

/// The one word that ships with the collision tint (spec §9 legend: "clash").
const String portClashWord = 'clash';

/// The one word a docker-published port's row carries (D13). A word, not only
/// the container name, because "why is this port not mine?" is the question the
/// row has to answer at a glance.
const String portDockerWord = 'docker';

/// The full docker sentence (spec §3 tooltip = Semantics.label): who published
/// the port, and — when the labels carried one — which compose file to edit.
/// Says nothing about reach: the reach pill next to it already reports the real
/// bind, and "docker" is ownership (D13).
String portDockerTooltip(PortDocker docker) {
  final compose = docker.compose;
  final where = (compose != null && compose.isNotEmpty)
      ? ' Defined in $compose.'
      : '';
  return 'Published by the docker container ${docker.container}, so the '
      'listener you see is docker’s proxy, not the server itself.$where';
}

/// What a row calls a port on line 1: the container name for a docker-published
/// port, the command's basename otherwise. Without this, every container port
/// reads `com.docker.backend` — identical for all of them, and identifying none.
/// The real process still shows on line 2 via [portProcessLine], so nothing is
/// hidden, only ordered by usefulness.
String portRowToken(PortInfo port) {
  final docker = port.docker;
  return docker != null ? docker.container : portCommandToken(port.command);
}

/// The orphan row's provenance line (D10): `was <branch>, removed Nd ago` when
/// history recorded both; it degrades to the branch alone, then to the cwd
/// path, and NEVER fabricates a date — a missing [PortOrphan.removedAt] renders
/// no date at all, the same discipline as [portUptimeLabel]'s empty string
/// rather than a zero-epoch "removed 56y ago".
String portOrphanLabel(PortOrphan orphan, {required int nowMs}) {
  final removed = _removedAge(orphan.removedAt, nowMs);
  final branch = orphan.formerBranch;
  if (branch != null && branch.isNotEmpty) {
    return removed.isEmpty ? 'was $branch' : 'was $branch, removed $removed';
  }
  // No branch recorded: say WHERE from, still with no fabricated date.
  final path = orphan.formerWorktreePath;
  if (path != null && path.isNotEmpty) {
    return removed.isEmpty ? 'cwd $path' : 'cwd $path, removed $removed';
  }
  return removed.isEmpty ? 'worktree gone' : 'removed $removed';
}

/// The full orphan sentence (spec §3/§9 tooltip = Semantics.label). Ends in the
/// removal age only when history holds it (D10) — never a fabricated date.
String portOrphanTooltip(PortOrphan orphan, {required int nowMs}) {
  final where = orphan.formerWorktreePath;
  final head = (where != null && where.isNotEmpty)
      ? 'Listening from $where, which stopped being a worktree'
      : 'Listening from a worktree that is gone';
  final removed = _removedAge(orphan.removedAt, nowMs);
  final when = removed.isEmpty ? '' : ' $removed';
  return '$head$when. Nothing will ever reclaim it but you.';
}

/// The collision line (D12): names the other branch and stops there — NO
/// suggested free port (that is SPEC-ports-kill/P3). `also wanted by <branch>`.
String portCollisionLabel(PortCollision collision, {required int port}) {
  final branch = collision.withBranch;
  return (branch != null && branch.isNotEmpty)
      ? '$port also wanted by $branch'
      : '$port also wanted by another worktree';
}

/// The full collision sentence (spec §3/§9 tooltip = Semantics.label). States
/// the clash honestly; carries no suggested port (D12).
String portCollisionTooltip(PortCollision collision, {required int port}) {
  final branch = collision.withBranch;
  final who = (branch != null && branch.isNotEmpty)
      ? branch
      : 'another worktree';
  return '$who already holds $port — a dev server started here would fail to '
      'bind.';
}

/// Why the glyph shows an honest unknown (`lsof` denied). [scanError] is the
/// server's one-line reason when it has one.
String portsScanUnavailableTooltip(String? scanError) {
  const base =
      'Could not read this machine’s sockets, so this list may be incomplete.';
  return scanError == null || scanError.isEmpty ? base : '$base ($scanError)';
}

/// "up 41m" / "up 3h" / "up 2d"; empty when the start time is unknown — never
/// a fabricated "up 56y" from an epoch-0 default (the absent-stays-absent rule).
String portUptimeLabel(int? startedAt, {required int nowMs}) {
  if (startedAt == null) return '';
  final ms = nowMs - startedAt;
  if (ms < 0) return '';
  final mins = ms ~/ 60000;
  if (mins < 60) return 'up ${mins}m';
  final hours = mins ~/ 60;
  if (hours < 24) return 'up ${hours}h';
  return 'up ${hours ~/ 24}d';
}

/// pid + command, one string for the process line.
String portPidCommandLabel(int pid, String command) => 'pid $pid · $command';

/// The command as a row shows it: argv[0] reduced to its basename, every
/// argument kept. Only argv[0] is shortened — a path *argument* says what the
/// process was told to do and must survive (`node dist/serve.js`).
String portCommandLine(String command) {
  final space = command.indexOf(' ');
  if (space < 0) return portCommandToken(command);
  final args = command.substring(space + 1);
  return '${portCommandToken(command.substring(0, space))} $args';
}

/// Line 2 of a port row: `pid 48211 · up 41m · node vite --port 5173`.
///
/// The order is load-bearing. Every row that renders this ellipses its tail, so
/// the age must sit AHEAD of the args or it is never seen — which is exactly
/// what happened when this line joined the full argv first and appended the
/// uptime last (mockup §2a puts pid, then age, then the command). The untruncated
/// argv is still one hover away via [portPidCommandLabel].
String portProcessLine(
  int pid,
  String command, {
  required int? startedAt,
  required int nowMs,
}) {
  final uptime = portUptimeLabel(startedAt, nowMs: nowMs);
  return [
    'pid $pid',
    if (uptime.isNotEmpty) uptime,
    portCommandLine(command),
  ].join(' · ');
}

/// The global screen's subtitle: how many are listening, and how old the scan
/// is. Freshness is a first-class fact here for the same reason the health
/// tooltip carries `probed N s ago` — every verdict on the screen is cached
/// (stale-while-revalidate), and a list with no age reads as live.
String portsScanSummary({
  required int listening,
  required int scannedAt,
  required int nowMs,
}) {
  final what = listening == 1 ? '1 listening' : '$listening listening';
  final secs = ((nowMs - scannedAt) ~/ 1000).clamp(0, 1 << 30);
  final age = secs < 90 ? '$secs s ago' : '${secs ~/ 60} min ago';
  return '$what · scanned $age';
}

/// The short command word line 1 shows: argv[0]'s basename, because a real
/// argv[0] is an absolute path (`/opt/homebrew/Cellar/node/26.5.1/bin/node`)
/// that ellipses to nothing in a 320 pt popover row. This is NOT the `kind`
/// guessing D5 cut — no pattern matching, no invented vocabulary; it is still
/// literally the command, just without the directories. The full argv stays one
/// hover away via [portPidCommandLabel].
String portCommandToken(String command) {
  final argv0 = command.split(' ').first;
  final slash = argv0.lastIndexOf('/');
  if (slash < 0) return argv0;
  final base = argv0.substring(slash + 1);
  // A trailing slash leaves no basename; show the path rather than a blank slot.
  return base.isEmpty ? argv0 : base;
}

/// The glyph's spoken label — a WORD for every tinted state, so colour is
/// never the only signal (worktree_row.dart's rule). Returns empty for
/// [PortsGlyphState.none] (nothing is drawn there).
String portsGlyphSemanticLabel(PortsGlyphState state, {required int count}) {
  final ports = count == 1 ? '1 port' : '$count ports';
  return switch (state) {
    PortsGlyphState.none => '',
    PortsGlyphState.serving => '$ports listening',
    PortsGlyphState.exposed => '$ports listening, one exposed off this machine',
    PortsGlyphState.attention => '$ports listening, one needs attention',
    PortsGlyphState.unknown => 'ports scan unavailable',
  };
}

/// "probed N s ago" / "probed N min ago". The tooltip's freshness clause.
String _probeAge(int probedAt, int nowMs) {
  final secs = ((nowMs - probedAt) ~/ 1000).clamp(0, 1 << 30);
  if (secs < 90) return 'probed $secs s ago';
  return 'probed ${secs ~/ 60} min ago';
}

/// "41m ago" / "3h ago" / "2d ago"; empty when the removal time is unknown —
/// the same absent-stays-absent discipline as [portUptimeLabel] (D10 forbids a
/// fabricated date).
String _removedAge(int? removedAt, int nowMs) {
  if (removedAt == null) return '';
  final ms = nowMs - removedAt;
  if (ms < 0) return '';
  final mins = ms ~/ 60000;
  if (mins < 60) return '${mins}m ago';
  final hours = mins ~/ 60;
  if (hours < 24) return '${hours}h ago';
  return '${hours ~/ 24}d ago';
}

/// The reason phrase for a status code (2xx/3xx/4xx/5xx). Terse; the tooltip
/// pairs it with the number.
String _statusName(int? status) => switch (status) {
  200 => 'OK',
  201 => 'Created',
  204 => 'No Content',
  301 || 302 || 307 || 308 => 'Redirect',
  304 => 'Not Modified',
  400 => 'Bad Request',
  401 => 'Unauthorized',
  403 => 'Forbidden',
  404 => 'Not Found',
  500 => 'Server Error',
  502 => 'Bad Gateway',
  503 => 'Unavailable',
  null => '',
  _ => '',
};
