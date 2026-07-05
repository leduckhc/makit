/// Daemon lifecycle service for the macOS desktop control app (SPEC-03).
///
/// The control socket can only talk to a *running* daemon, so *starting* a
/// stopped one means spawning the `pino` CLI (`pino start`). This service wraps
/// `pino start` / `pino stop` / `pino restart` behind an injectable process
/// runner and CLI resolver so it is unit-testable and never hard-fails when the
/// CLI is missing (it reports [DaemonActionOutcome.cliNotFound] instead).
library;

import 'dart:io';

/// Runs an executable and resolves to its [ProcessResult]. Injected so tests
/// can assert on the spawned command without touching real processes.
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> args);

/// Locates the `pino` CLI on disk.
///
/// Discovery order (first hit wins): each of [candidatePaths] that [exists],
/// then a login-shell PATH lookup ([shellLookup]). Returns `null` when nothing
/// is found so callers can surface an "install the CLI" affordance.
class PinoCliResolver {
  /// Creates a resolver.
  ///
  /// [candidatePaths] defaults to the app-bundle-relative and common install
  /// locations; [exists] defaults to a real filesystem check; [shellLookup]
  /// defaults to `zsh -lic 'command -v pino'` so the resolved PATH matches the
  /// user's terminal.
  PinoCliResolver({
    List<String>? candidatePaths,
    bool Function(String path)? exists,
    Future<String?> Function()? shellLookup,
  }) : candidatePaths = candidatePaths ?? _defaultCandidatePaths(),
       _exists = exists ?? _fileIsExecutable,
       _shellLookup = shellLookup ?? _loginShellLookup;

  /// Absolute paths checked, in order, before falling back to the shell lookup.
  final List<String> candidatePaths;
  final bool Function(String path) _exists;
  final Future<String?> Function() _shellLookup;

  /// Returns the absolute path to `pino`, or `null` if it cannot be found.
  Future<String?> resolve() async {
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
    paths.add('$exeDir/../Resources/pino/pino');
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) paths.add('$home/.local/bin/pino');
    paths.add('/opt/homebrew/bin/pino');
    paths.add('/usr/local/bin/pino');
    return paths;
  }

  static bool _fileIsExecutable(String path) => File(path).existsSync();

  static Future<String?> _loginShellLookup() async {
    final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
    try {
      final res = await Process.run(shell, ['-lic', 'command -v pino']);
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
  /// `pino start` succeeded.
  started,

  /// `pino stop` succeeded.
  stopped,

  /// `pino restart` succeeded.
  restarted,

  /// The `pino` CLI could not be located — prompt the user to install it.
  cliNotFound,

  /// The CLI ran but exited non-zero, or spawning threw.
  failed,
}

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

/// Starts, stops, and restarts the pino daemon via the `pino` CLI.
class DaemonLifecycle {
  /// Creates a lifecycle driver.
  ///
  /// [resolver] locates the CLI; [run] spawns it (defaults to [Process.run]).
  DaemonLifecycle({required this.resolver, ProcessRunner? run})
    : run = run ?? Process.run;

  /// Locates the `pino` executable.
  final PinoCliResolver resolver;

  /// Spawns the CLI.
  final ProcessRunner run;

  /// Runs `pino start`.
  Future<DaemonActionResult> start() =>
      _invoke('start', DaemonActionOutcome.started);

  /// Runs `pino stop`.
  Future<DaemonActionResult> stop() =>
      _invoke('stop', DaemonActionOutcome.stopped);

  /// Runs `pino restart`.
  Future<DaemonActionResult> restart() =>
      _invoke('restart', DaemonActionOutcome.restarted);

  Future<DaemonActionResult> _invoke(
    String verb,
    DaemonActionOutcome onSuccess,
  ) async {
    final path = await resolver.resolve();
    if (path == null) {
      return const DaemonActionResult(
        DaemonActionOutcome.cliNotFound,
        message: 'The pino CLI was not found. Install it to control the server.',
      );
    }
    try {
      final res = await run(path, [verb]);
      if (res.exitCode == 0) return DaemonActionResult(onSuccess);
      final stderr = (res.stderr is String) ? res.stderr as String : '';
      return DaemonActionResult(
        DaemonActionOutcome.failed,
        message: 'pino $verb exited ${res.exitCode}: ${stderr.trim()}',
      );
    } on ProcessException catch (e) {
      return DaemonActionResult(
        DaemonActionOutcome.failed,
        message: 'Failed to run pino $verb: ${e.message}',
      );
    }
  }
}
