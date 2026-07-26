/// One-click installer for the `makit` CLI.
///
/// Release builds ship a self-contained CLI inside the app bundle at
/// `Contents/Resources/makit/makit` (see `scripts/bundle-makit-cli.sh`). This
/// service installs a tiny wrapper at `~/.local/bin/makit` that execs the
/// bundled copy, so the CLI resolver (and the user's terminal) can find it
/// without any manual setup.
///
/// A symlink would not work: the bundled shim locates its sibling `node` and
/// `dist/` via `dirname "$0"`, which for a symlink resolves to the *link's*
/// directory. The wrapper execs the bundled shim by absolute path instead, so
/// `$0` stays inside the bundle.
library;

import 'dart:io';

/// Result of a [CliInstaller.install] attempt.
class CliInstallResult {
  const CliInstallResult.success(String this.installedPath) : error = null;
  const CliInstallResult.failure(String this.error) : installedPath = null;

  /// Absolute path of the installed wrapper, when [ok].
  final String? installedPath;

  /// Human-readable failure reason, when not [ok].
  final String? error;

  bool get ok => installedPath != null;
}

/// Installs a wrapper for the app-bundled `makit` CLI into `~/.local/bin`.
class CliInstaller {
  /// [bundledCliPath] supplies the bundled CLI location (defaults to the
  /// running .app's `Contents/Resources/makit/makit`); [homeDir] the user's
  /// home. Both injectable for tests.
  CliInstaller({String Function()? bundledCliPath, String Function()? homeDir})
    : _bundledCliPath = bundledCliPath ?? _defaultBundledCliPath,
      _homeDir = homeDir ?? (() => Platform.environment['HOME'] ?? '');

  final String Function() _bundledCliPath;
  final String Function() _homeDir;

  /// Absolute path of the bundled CLI, or `null` when this build ships none
  /// (e.g. a `flutter run` dev build without `scripts/bundle-makit-cli.sh`).
  String? get bundledCli {
    final path = _bundledCliPath();
    return File(path).existsSync() ? path : null;
  }

  /// Writes an executable wrapper at `~/.local/bin/makit` exec'ing the
  /// bundled CLI. Overwrites any existing file at that path.
  Future<CliInstallResult> install() async {
    final bundled = bundledCli;
    if (bundled == null) {
      return const CliInstallResult.failure(
        'This build has no bundled makit CLI.',
      );
    }
    final home = _homeDir();
    if (home.isEmpty) {
      return const CliInstallResult.failure('HOME is not set.');
    }
    final target = '$home/.local/bin/makit';
    try {
      File(target).parent.createSync(recursive: true);
      File(target).writeAsStringSync(
        '#!/bin/sh\n'
        '# Installed by the Makit app — execs the CLI bundled inside the .app.\n'
        'exec "$bundled" "\$@"\n',
      );
      final chmod = Process.runSync('chmod', ['755', target]);
      if (chmod.exitCode != 0) {
        return CliInstallResult.failure('chmod failed: ${chmod.stderr}');
      }
      return CliInstallResult.success(target);
    } on FileSystemException catch (e) {
      return CliInstallResult.failure(e.message);
    }
  }

  static String _defaultBundledCliPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return '$exeDir/../Resources/makit/makit';
  }
}
