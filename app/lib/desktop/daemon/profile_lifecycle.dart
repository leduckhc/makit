/// Per-profile daemon lifecycle for the macOS desktop control app (SPEC-profiles D7).
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
/// socket disappeared (SPEC-profiles D8) before anyone unlinks files under what might
/// still be a live daemon holding `makit.db-wal`.
library;

import 'dart:io';

import 'daemon_lifecycle.dart';
import 'daemon_result_utils.dart';
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
    int? Function(ServerProfile profile)? readPid,
    Future<bool> Function(int pid)? processAlive,
    String? Function(ServerProfile profile)? cliPathFor,
    List<String> Function(ServerProfile profile)? serveArgsFor,
  }) : run = run ?? _defaultRun,
       _socketExists = socketExists ?? _fileExists,
       _statusProbe = statusProbe ?? _connectProbe,
       _sleep = sleep ?? Future<void>.delayed,
       _readPid = readPid ?? _readPidFile,
       _processAlive = processAlive ?? _posixProcessAlive,
       _cliPathFor = cliPathFor,
       _serveArgsFor = serveArgsFor;

  /// Locates the `makit` executable.
  final MakitCliResolver resolver;

  /// Spawns the CLI with a per-profile environment.
  final ProfileProcessRunner run;

  final bool Function(String path) _socketExists;
  final Future<bool> Function(ServerProfile profile) _statusProbe;
  final Future<void> Function(Duration duration) _sleep;
  final int? Function(ServerProfile profile) _readPid;
  final Future<bool> Function(int pid) _processAlive;

  /// The `makit` binary configured for a **given** profile, or null to fall back
  /// to [resolver]'s own override. Without this, starting profile B from A's
  /// window used A's configured `cliPath`.
  final String? Function(ServerProfile profile)? _cliPathFor;

  /// The `serve` arguments configured for a **given** profile (host/port), used
  /// by [start]. Without this, `makit start` fell back to the CLI's default port
  /// (7777) instead of the target profile's allocated port — colliding with the
  /// legacy daemon or landing on an endpoint its own `ServerConfig` disagrees
  /// with.
  final List<String> Function(ServerProfile profile)? _serveArgsFor;

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

  /// Stops [profile]'s daemon, then polls until the daemon **process** has
  /// exited.
  ///
  /// Deleting a profile must not unlink files under a live daemon holding
  /// `makit.db-wal` (SPEC-profiles D8). Confirming only that the control socket
  /// stopped answering is not enough: the daemon's SIGTERM handler closes the
  /// socket *first* and calls `process.exit(0)` ~100 ms later, so there is a
  /// window where the socket is gone but the process is still alive and may
  /// still be writing the database. `makit stop` itself returns the instant it
  /// signals (it does not wait for exit) and removes the pid file, so this reads
  /// the pid **before** stopping and then polls the OS for the process itself.
  ///
  /// Returns `true` once the process is confirmed gone within [timeout], and
  /// `false` if it is still alive when time runs out — the caller must then abort
  /// the delete. When the pid cannot be read (older daemon, race), it falls back
  /// to the socket-liveness check ([isRunning]) so a profile is never made
  /// permanently undeletable. If the stop command itself fails (CLI not found,
  /// permission error), returns `false` immediately without polling.
  Future<bool> stopAndConfirm(
    ServerProfile profile, {
    Duration timeout = _kDefaultStopTimeout,
  }) async {
    final pid = _readPid(profile);
    final stopResult = await stop(profile);
    if (stopResult.outcome == DaemonActionOutcome.failed ||
        stopResult.outcome == DaemonActionOutcome.cliNotFound) {
      return false;
    }
    var elapsed = Duration.zero;

    // Phase 1: wait for the control socket to stop answering.
    while (elapsed < timeout) {
      if (!await isRunning(profile)) break;
      await _sleep(_kSocketPollInterval);
      elapsed += _kSocketPollInterval;
    }
    if (await isRunning(profile)) return false;

    // Phase 2: wait for the process itself to exit. Without a pid the socket
    // check above is all we have.
    if (pid == null) return true;
    while (elapsed < timeout) {
      if (!await _processAlive(pid)) return true;
      await _sleep(_kSocketPollInterval);
      elapsed += _kSocketPollInterval;
    }
    return !await _processAlive(pid);
  }

  Future<DaemonActionResult> _invoke(
    ServerProfile profile,
    String verb,
    DaemonActionOutcome onSuccess,
  ) async {
    // The TARGET profile's configured binary, not the active profile's.
    final path = await resolver.resolve(
      overridePath: _cliPathFor?.call(profile),
    );
    if (path == null) {
      return const DaemonActionResult(
        DaemonActionOutcome.cliNotFound,
        message:
            'The makit CLI was not found. Install it to control the server.',
      );
    }
    // Only `start` takes endpoint arguments; `stop` needs none.
    final args = <String>[
      verb,
      if (verb == 'start') ...?_serveArgsFor?.call(profile),
    ];
    try {
      final res = await run(path, args, environment: profile.environment);
      if (res.exitCode == 0) return DaemonActionResult(onSuccess);
      return DaemonActionResult(
        DaemonActionOutcome.failed,
        message: formatDaemonError(verb, res),
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

  /// Reads the daemon pid from `$MAKIT_HOME/makit.pid`, or `null` when the file
  /// is absent or unparseable. Read before `makit stop`, which deletes it.
  ///
  /// Synchronous on purpose: it is one small read, once per stop — unlike
  /// [_posixProcessAlive], which is polled up to ~100 times and therefore must
  /// be async. Making this async introduced real filesystem microtasks that a
  /// widget test's `pumpAndSettle` could never settle, hanging the delete tests.
  static int? _readPidFile(ServerProfile profile) {
    try {
      final file = File(profile.pidFilePath);
      if (!file.existsSync()) return null;
      return int.tryParse(file.readAsStringSync().trim());
    } on FileSystemException {
      return null;
    }
  }

  /// Whether an OS process [pid] is still alive, via POSIX `kill -0` (which only
  /// probes; it delivers no signal). Returns `false` off POSIX, where the pid
  /// wait is skipped and socket-liveness stands in.
  ///
  /// Asynchronous (`Process.run`, not `runSync`): `stopAndConfirm` can poll this
  /// up to ~100 times across the stop timeout, and a synchronous spawn each time
  /// would block the UI isolate during a profile deletion.
  static Future<bool> _posixProcessAlive(int pid) async {
    if (Platform.isWindows) return false;
    try {
      final res = await Process.run('/bin/kill', ['-0', '$pid']);
      return res.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

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
