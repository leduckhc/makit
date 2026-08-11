/// Daemon lifecycle service for the macOS desktop control app (SPEC-03).
///
/// The control socket can only talk to a *running* daemon, so *starting* a
/// stopped one means spawning the `makit` CLI (`makit start`). This service wraps
/// `makit start` / `makit stop` / `makit restart` behind an injectable process
/// runner and CLI resolver so it is unit-testable and never hard-fails when the
/// CLI is missing (it reports [DaemonActionOutcome.cliNotFound] instead).
library;

import 'dart:io';

import 'daemon_result_utils.dart';

/// Runs an executable and resolves to its [ProcessResult]. Injected so tests
/// can assert on the spawned command without touching real processes.
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> args);

/// Locates the `makit` CLI on disk.
///
/// Discovery order (first hit wins): each of [candidatePaths] that [exists],
/// then a login-shell PATH lookup ([shellLookup]). Returns `null` when nothing
/// is found so callers can surface an "install the CLI" affordance.
class MakitCliResolver {
  /// Creates a resolver.
  ///
  /// [candidatePaths] defaults to the app-bundle-relative and common install
  /// locations; [exists] defaults to a real filesystem check; [shellLookup]
  /// defaults to `zsh -lic 'command -v makit'` so the resolved PATH matches the
  /// user's terminal.
  MakitCliResolver({
    List<String>? candidatePaths,
    bool Function(String path)? exists,
    Future<String?> Function()? shellLookup,
    String Function()? overridePath,
  }) : candidatePaths = candidatePaths ?? _defaultCandidatePaths(),
       _exists = exists ?? _fileIsExecutable,
       _shellLookup = shellLookup ?? _loginShellLookup,
       _overridePath = overridePath;

  /// Absolute paths checked, in order, before falling back to the shell lookup.
  final List<String> candidatePaths;
  final bool Function(String path) _exists;
  final Future<String?> Function() _shellLookup;

  /// Supplies a user-configured `makit` path (blank when none). Checked before
  /// [candidatePaths] so the desktop app can point at a specific binary. A set
  /// but missing path falls through to auto-discovery rather than hard-failing.
  final String Function()? _overridePath;

  /// Returns the absolute path to `makit`, or `null` if it cannot be found.
  ///
  /// [overridePath] takes precedence over the constructor's `overridePath`
  /// closure, so a caller acting on **another** profile can supply that
  /// profile's configured binary instead of the active profile's.
  Future<String?> resolve({String? overridePath}) async {
    final configured = overridePath ?? _overridePath?.call();
    final override = configured?.trim() ?? '';
    if (override.isNotEmpty && _exists(override)) return override;
    for (final path in candidatePaths) {
      if (_exists(path)) return path;
    }
    final viaShell = await _shellLookup();
    if (viaShell != null && viaShell.isNotEmpty) return viaShell;
    return null;
  }

  static List<String> _defaultCandidatePaths() {
    final paths = <String>[];
    // A copy bundled inside the .app (preferred zero-install end state).
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    paths.add('$exeDir/../Resources/makit/makit');
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) paths.add('$home/.local/bin/makit');
    paths.add('/opt/homebrew/bin/makit');
    paths.add('/usr/local/bin/makit');
    return paths;
  }

  /// True only when [path] is a regular file with an execute bit set.
  ///
  /// Guards against an override (or candidate) that exists but isn't runnable —
  /// a directory or a non-executable file — which would otherwise "win" here
  /// and make `Process.run` fail instead of falling back to discovery. A
  /// missing path (and, in Dart, a directory) already reports `existsSync() ==
  /// false`; the mode check additionally rejects a non-executable regular file.
  static bool _fileIsExecutable(String path) {
    final file = File(path);
    if (!file.existsSync()) return false;
    try {
      // Any of the owner/group/other execute bits (0o111 == 0x49).
      return (file.statSync().mode & 0x49) != 0;
    } on FileSystemException {
      return false;
    }
  }

  static Future<String?> _loginShellLookup() async {
    final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
    try {
      final res = await Process.run(shell, ['-lic', 'command -v makit']);
      if (res.exitCode != 0) return null;
      final out = (res.stdout as String).trim();
      return out.isEmpty ? null : out.split('\n').first.trim();
    } on ProcessException {
      return null;
    }
  }
}

/// Outcome of a lifecycle action.
enum DaemonActionOutcome {
  /// `makit start` succeeded.
  started,

  /// `makit stop` succeeded.
  stopped,

  /// `makit restart` succeeded.
  restarted,

  /// The `makit` CLI could not be located — prompt the user to install it.
  cliNotFound,

  /// The CLI ran but exited non-zero, or spawning threw.
  failed,
}

/// Builds the human-readable detail for a non-zero `makit <verb>` exit.
///
/// Both streams are consulted, because `makit start` reports *why* it failed on
/// **stdout**, not stderr: the daemon is spawned detached with its own output
/// redirected into the log file, so the parent process's only diagnostic is
/// `deps.out(...)` -> `console.log` (see `start` in
/// `server/src/daemon/service.ts` and `out:` in `server/src/index.ts`).
/// Reading stderr alone yielded the bare, useless `makit start exited 1: ` for
/// every real start failure -- including the common "port already in use" case,
/// whose message names the log file and the fix.
///
/// stderr comes first (it carries the lower-level cause), duplicates are
/// collapsed, and the separator is dropped entirely when neither stream said
/// anything -- so the message never ends in a dangling colon.

/// Result of a lifecycle action, with an optional human-readable [message].
class DaemonActionResult {
  /// Creates a result.
  const DaemonActionResult(this.outcome, {this.message});

  /// What happened.
  final DaemonActionOutcome outcome;

  /// Error detail (CLI stderr or exception text) when the action did not
  /// succeed; otherwise `null`.
  final String? message;

  /// Whether the action succeeded.
  bool get ok =>
      outcome != DaemonActionOutcome.cliNotFound &&
      outcome != DaemonActionOutcome.failed;
}

/// Starts, stops, and restarts the makit daemon via the `makit` CLI.
class DaemonLifecycle {
  /// Creates a lifecycle driver.
  ///
  /// [resolver] locates the CLI; [run] spawns it (defaults to [Process.run]).
  /// [environment] is merged into the spawned CLI's environment (on top of the
  /// inherited parent env) — used to pass `MAKIT_HOME` so this app instance's
  /// daemon is isolated from other builds. Ignored when a custom [run] is
  /// injected (tests supply their own runner).
  DaemonLifecycle({
    required this.resolver,
    ProcessRunner? run,
    Map<String, String>? environment,
  }) : run =
           run ??
           ((exe, args) => Process.run(exe, args, environment: environment));

  /// Locates the `makit` executable.
  final MakitCliResolver resolver;

  /// Spawns the CLI.
  final ProcessRunner run;

  /// Runs `makit start`, forwarding [serveArgs] (e.g. `--host`, `--lan`,
  /// `--port`) built by [ServerConfig.serveArgs].
  Future<DaemonActionResult> start({List<String> serveArgs = const []}) =>
      _invoke('start', DaemonActionOutcome.started, extraArgs: serveArgs);

  /// Runs `makit stop`.
  Future<DaemonActionResult> stop() =>
      _invoke('stop', DaemonActionOutcome.stopped);

  /// Runs `makit restart`, forwarding [serveArgs].
  Future<DaemonActionResult> restart({List<String> serveArgs = const []}) =>
      _invoke('restart', DaemonActionOutcome.restarted, extraArgs: serveArgs);

  Future<DaemonActionResult> _invoke(
    String verb,
    DaemonActionOutcome onSuccess, {
    List<String> extraArgs = const [],
  }) async {
    final path = await resolver.resolve();
    if (path == null) {
      return const DaemonActionResult(
        DaemonActionOutcome.cliNotFound,
        message:
            'The makit CLI was not found. Install it to control the server.',
      );
    }
    try {
      final res = await run(path, [verb, ...extraArgs]);
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
}
