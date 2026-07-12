/// Daemon lifecycle service for the macOS desktop control app (SPEC-03).
///
/// The control socket can only talk to a *running* daemon, so *starting* a
/// stopped one means spawning the `makit` CLI (`makit start`). This service wraps
/// `makit start` / `makit stop` / `makit restart` behind an injectable process
/// runner and CLI resolver so it is unit-testable and never hard-fails when the
/// CLI is missing (it reports [DaemonActionOutcome.cliNotFound] instead).
library;

import 'dart:io';

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
  }) : candidatePaths = candidatePaths ?? _defaultCandidatePaths(),
       _exists = exists ?? _fileIsExecutable,
       _shellLookup = shellLookup ?? _loginShellLookup;

  /// Absolute paths checked, in order, before falling back to the shell lookup.
  final List<String> candidatePaths;
  final bool Function(String path) _exists;
  final Future<String?> Function() _shellLookup;

  /// Returns the absolute path to `makit`, or `null` if it cannot be found.
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
    paths.add('$exeDir/../Resources/makit/makit');
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) paths.add('$home/.local/bin/makit');
    paths.add('/opt/homebrew/bin/makit');
    paths.add('/usr/local/bin/makit');
    return paths;
  }

  static bool _fileIsExecutable(String path) => File(path).existsSync();

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
  DaemonLifecycle({required this.resolver, ProcessRunner? run})
    : run = run ?? Process.run;

  /// Locates the `makit` executable.
  final MakitCliResolver resolver;

  /// Spawns the CLI.
  final ProcessRunner run;

  /// Runs `makit start`, optionally binding a specific [host]/[port].
  Future<DaemonActionResult> start({String? host, int? port}) => _invoke(
        'start',
        DaemonActionOutcome.started,
        extraArgs: [
          if (host != null && host.isNotEmpty) ...['--host', host],
          if (port != null && port > 0) ...['--port', '$port'],
        ],
      );

  /// Runs `makit stop`.
  Future<DaemonActionResult> stop() =>
      _invoke('stop', DaemonActionOutcome.stopped);

  /// Runs `makit restart`, optionally binding a specific [host]/[port].
  Future<DaemonActionResult> restart({String? host, int? port}) => _invoke(
        'restart',
        DaemonActionOutcome.restarted,
        extraArgs: [
          if (host != null && host.isNotEmpty) ...['--host', host],
          if (port != null && port > 0) ...['--port', '$port'],
        ],
      );

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
      final stderr = (res.stderr is String) ? res.stderr as String : '';
      return DaemonActionResult(
        DaemonActionOutcome.failed,
        message: 'makit $verb exited ${res.exitCode}: ${stderr.trim()}',
      );
    } on ProcessException catch (e) {
      return DaemonActionResult(
        DaemonActionOutcome.failed,
        message: 'Failed to run makit $verb: ${e.message}',
      );
    }
  }
}
