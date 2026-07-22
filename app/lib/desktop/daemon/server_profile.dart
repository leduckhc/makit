/// The isolated server "profile" a desktop app instance runs against.
///
/// A single Mac can run several makit desktop builds at once — e.g. one built
/// from `main` and one from a feature worktree. Without isolation they collide:
/// they share `~/.makit` (control socket, pid, db), the default port, and the
/// `NSUserDefaults` prefs domain, so one window's "restart server" hijacks the
/// other's daemon. See `docs/DEVELOPMENT.md`.
///
/// A [ServerProfile] gives each build its own `MAKIT_HOME`, port, prefs prefix,
/// and window label — derived deterministically from the running `.app`'s path,
/// so two builds never step on each other and each is stable across rebuilds in
/// the same location. No user configuration required.
///
/// The **default** profile (an installed app, e.g. in `/Applications`, whose
/// path is not a Flutter dev-build path) keeps the historical `~/.makit` + port
/// 7777 + `flutter.` prefs prefix, so shipped users are unaffected.
library;

import 'dart:io';

import '../settings/server_config.dart' show kDefaultServerPort;

/// A per-build server profile. Immutable; derived by [ServerProfile.resolve].
class ServerProfile {
  /// Creates a profile. Prefer [ServerProfile.resolve].
  const ServerProfile({
    required this.id,
    required this.label,
    required this.isDefault,
    required this.makitHome,
    required this.port,
  });

  /// Stable, filesystem/prefs-safe key fragment. `'default'` for the installed
  /// app; an 8-char hex hash of the repo root for a dev build.
  final String id;

  /// Human label used in the window title and the in-app badge — the repo/
  /// worktree folder name for a dev build, or `'makit'` for the default.
  final String label;

  /// True for the installed app: uses the historical `~/.makit`, port 7777, and
  /// the legacy `flutter.` prefs prefix (backward compatible).
  final bool isDefault;

  /// Absolute `MAKIT_HOME` this instance's daemon and control socket live under.
  final String makitHome;

  /// The default bind port seeded into this instance's [ServerConfig] (the user
  /// can still override it in Settings; that override is stored per profile).
  final int port;

  /// Where this instance's daemon exposes its control socket. The app's control
  /// client connects here; the spawned CLI (with `MAKIT_HOME=[makitHome]`)
  /// creates it here.
  String get controlSocketPath => '$makitHome/control.sock';

  /// The `SharedPreferences` key prefix that namespaces this instance's
  /// settings. The default profile keeps `flutter.` so existing prefs survive.
  String get prefsPrefix => isDefault ? 'flutter.' : 'flutter.$id.';

  /// The native window title, so builds are distinguishable in Cmd-Tab / the
  /// Window menu / Mission Control.
  String get windowTitle => isDefault ? 'Makit' : 'Makit — $label';

  /// The `MAKIT_HOME` environment override passed to the spawned `makit` CLI.
  Map<String, String> get environment => {'MAKIT_HOME': makitHome};

  /// Matches a macOS Flutter dev-build executable path and captures the repo
  /// root in group 1:
  /// `<repoRoot>/app/build/macos/Build/Products/<cfg>/<name>.app/Contents/MacOS/<exe>`
  static final RegExp _devBuildPath = RegExp(
    r'^(.*)/app/build/macos/Build/Products/[^/]+/[^/]+\.app/Contents/MacOS/[^/]+$',
  );

  /// Derives the profile for the running instance.
  ///
  /// [executablePath] defaults to [Platform.resolvedExecutable] and [home] to
  /// `$HOME`; both are injectable for tests.
  static ServerProfile resolve({String? executablePath, String? home}) {
    final exe = executablePath ?? Platform.resolvedExecutable;
    final resolvedHome = home ?? Platform.environment['HOME'] ?? '';

    final match = _devBuildPath.firstMatch(exe);
    if (match == null) {
      return ServerProfile(
        id: 'default',
        label: 'makit',
        isDefault: true,
        makitHome: '$resolvedHome/.makit',
        port: kDefaultServerPort,
      );
    }

    final repoRoot = match.group(1)!;
    final h = _fnv1a(repoRoot);
    final id = h.toRadixString(16).padLeft(8, '0');
    final label = repoRoot.split('/').where((s) => s.isNotEmpty).last;
    // 7800–7899: a stable, collision-unlikely dev range that avoids the 7777
    // default. A user can still override the port per profile in Settings.
    final port = 7800 + (h % 100);
    return ServerProfile(
      id: id,
      label: label,
      isDefault: false,
      makitHome: '$resolvedHome/.makit-dev/$id',
      port: port,
    );
  }

  /// 32-bit FNV-1a — a small, deterministic, cross-launch-stable string hash.
  /// (Dart's `String.hashCode` is not guaranteed stable across runs.)
  static int _fnv1a(String s) {
    var hash = 0x811c9dc5;
    for (final c in s.codeUnits) {
      hash ^= c;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }
}
