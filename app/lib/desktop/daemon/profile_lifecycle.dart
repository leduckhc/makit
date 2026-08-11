/// Per-profile daemon lifecycle for the macOS desktop control app (SPEC-50 D7).
///
/// [DaemonLifecycle] drives *the* daemon this app instance talks to: it captures
/// a single `environment` (its own `MAKIT_HOME`) at construction. But the
/// Profiles section must start and stop the daemon of an **arbitrary** profile —
/// one this window is not connected to — which needs a *different* `MAKIT_HOME`
/// per call. That is the whole reason this class exists.
///
/// It reuses the existing CLI verbs unchanged: `MAKIT_HOME=<home> makit start`
/// and `MAKIT_HOME=<home> makit stop` (`server/src/index.ts:130` →
/// `daemon.stop()`). SIGTERM→SIGKILL semantics already live in the CLI; here we
/// only spawn with the right home and, for deletion, *confirm* the control
/// socket disappeared (SPEC-50 D8) before anyone unlinks files under what might
/// still be a live daemon holding `makit.db-wal`.
library;

import 'dart:io';

import 'daemon_lifecycle.dart';
import 'server_profile.dart';

/// Runs an executable with an explicit [environment], resolving to its
/// [ProcessResult]. Distinct from [ProcessRunner] because a *profile's* daemon
/// needs a per-call `MAKIT_HOME`, not one fixed at construction. Injected so
/// tests never spawn a real process.
typedef ProfileProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> args, {
      Map<String, String>? environment,
    });

/// Default poll interval while waiting for a control socket to vanish.
const Duration _kSocketPollInterval = Duration(milliseconds: 50);

/// How long [ProfileLifecycle.stopAndConfirm] waits by default for the socket to
/// disappear after `makit stop`.
const Duration _kDefaultStopTimeout = Duration(seconds: 5);

/// Builds the human-readable detail for a non-zero `makit <verb>` exit.
///
/// Mirrors the logic in [DaemonLifecycle]: `makit start` reports *why* it failed
/// on **stdout** (the daemon is spawned detached), so both streams are consulted,
/// stderr first, duplicates collapsed, and the separator dropped when neither
/// stream said anything so the message never ends in a dangling colon.
String _failureMessage(String verb, ProcessResult res) {
  final head = 'makit $verb exited ${res.exitCode}';
  final parts = <String>[];
  for (final stream in [res.stderr, res.stdout]) {
    if (stream is! String) continue;
    final text = stream.trim();
    if (text.isNotEmpty && !parts.contains(text)) parts.add(text);
  }
  return parts.isEmpty ? head : '$head: ${parts.join(' — ')}';
}

/// Starts, stops, and probes the daemon of any [ServerProfile].
class ProfileLifecycle {
  /// Creates a per-profile lifecycle driver.
  ///
  /// [resolver] locates the `makit` CLI (reused from [DaemonLifecycle]); [run]
  /// spawns it with a per-profile environment (defaults to [Process.run]);
  /// [socketExists] tests for a profile's control socket (defaults to a real
  /// [File.existsSync]); [statusProbe] confirms a *live* daemon behind that
  /// socket (defaults to connecting to the unix socket); [sleep] paces polling
  /// (defaults to [Future.delayed]) and is injected so tests stay deterministic.
  ProfileLifecycle({
    required this.resolver,
    ProfileProcessRunner? run,
    bool Function(String path)? socketExists,
    Future<bool> Function(ServerProfile profile)? statusProbe,
    Future<void> Function(Duration duration)? sleep,
  }) : run = run ?? _defaultRun,
       _socketExists = socketExists ?? _fileExists,
       _statusProbe = statusProbe ?? _connectProbe,
       _sleep = sleep ?? Future<void>.delayed;

  /// Locates the `makit` executable.
  final MakitCliResolver resolver;

  /// Spawns the CLI with a per-profile environment.
  final ProfileProcessRunner run;

  final bool Function(String path) _socketExists;
  final Future<bool> Function(ServerProfile profile) _statusProbe;
  final Future<void> Function(Duration duration) _sleep;

  /// Runs `MAKIT_HOME=<profile.home> makit start`.
  Future<DaemonActionResult> start(ServerProfile profile) =>
      _invoke(profile, 'start', DaemonActionOutcome.started);

  /// Runs `MAKIT_HOME=<profile.home> makit stop` — the existing stop verb
  /// (`server/src/index.ts:130` → `daemon.stop()`), no server change needed.
  Future<DaemonActionResult> stop(ServerProfile profile) =>
      _invoke(profile, 'stop', DaemonActionOutcome.stopped);

  /// True when [profile]'s control socket exists **and** a status probe against
  /// it succeeds. The socket file can linger after a crash, so the existence
  /// check alone would report a dead daemon as running; the probe is what makes
  /// the answer trustworthy. Kept cheap: no probe is attempted when the socket
  /// is absent.
  Future<bool> isRunning(ServerProfile profile) async {
    if (!_socketExists(profile.controlSocketPath)) return false;
    return _statusProbe(profile);
  }

  /// Stops [profile]'s daemon, then polls until it is no longer *listening*.
  ///
  /// Deleting a profile must not unlink files under a live daemon holding
  /// `makit.db-wal` (SPEC-50 D8). The CLI already escalates SIGTERM→SIGKILL, so
  /// this only *confirms* the outcome: it returns `true` once the daemon stops
  /// answering within [timeout], and `false` if it is still answering when time
  /// runs out — the caller must then abort the delete.
  ///
  /// Liveness is [isRunning], **not** the presence of the socket file. A daemon
  /// killed with SIGKILL never unlinks its socket (it is removed only on
  /// graceful shutdown in `control-server.ts`), and `makit stop` on an
  /// already-dead daemon removes just the pid file. Verified against the real
  /// binary: after SIGKILL, `makit stop` prints "not running" and `control.sock`
  /// remains. Polling the file therefore reported every *crashed* profile as
  /// running forever — which made exactly the orphaned profiles that D9 exists to
  /// reclaim permanently undeletable.
  Future<bool> stopAndConfirm(
    ServerProfile profile, {
    Duration timeout = _kDefaultStopTimeout,
  }) async {
    await stop(profile);
    var elapsed = Duration.zero;
    while (elapsed < timeout) {
      if (!await isRunning(profile)) return true;
      await _sleep(_kSocketPollInterval);
      elapsed += _kSocketPollInterval;
    }
    return !await isRunning(profile);
  }

  Future<DaemonActionResult> _invoke(
    ServerProfile profile,
    String verb,
    DaemonActionOutcome onSuccess,
  ) async {
    final path = await resolver.resolve();
    if (path == null) {
      return const DaemonActionResult(
        DaemonActionOutcome.cliNotFound,
        message:
            'The makit CLI was not found. Install it to control the server.',
      );
    }
    try {
      final res = await run(path, [verb], environment: profile.environment);
      if (res.exitCode == 0) return DaemonActionResult(onSuccess);
      return DaemonActionResult(
        DaemonActionOutcome.failed,
        message: _failureMessage(verb, res),
      );
    } on ProcessException catch (e) {
      return DaemonActionResult(
        DaemonActionOutcome.failed,
        message: 'Failed to run makit $verb: ${e.message}',
      );
    }
  }

  static Future<ProcessResult> _defaultRun(
    String exe,
    List<String> args, {
    Map<String, String>? environment,
  }) => Process.run(exe, args, environment: environment);

  static bool _fileExists(String path) => File(path).existsSync();

  /// Connects to the unix control socket and immediately closes it. A daemon
  /// listening there accepts the connection; a stale socket file refuses it.
  static Future<bool> _connectProbe(ServerProfile profile) async {
    try {
      final socket = await Socket.connect(
        InternetAddress(
          profile.controlSocketPath,
          type: InternetAddressType.unix,
        ),
        0,
      );
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    } on OSError {
      return false;
    }
  }
}
