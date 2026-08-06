/// The ports vocabulary (SPEC-41 §3): one string per terse token, so the three
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

/// Actions that already say what they do get no tooltip.
String? portActionTooltip(PortAction action) => null;

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
