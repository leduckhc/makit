/// Path and identity derivation shared by [ServerProfile] and `ProfileRegistry`.
///
/// Kept in its own library so the profile *model* stays free of filesystem
/// concerns and the registry can reuse the derivation without a circular import.
library;

/// The port the installed (legacy) profile binds, matching the server's own
/// default in `serve.ts`.
const int kDefaultServerPort = 7777;

/// Used when a persisted entry carries no usable port. Distinct from
/// [kDefaultServerPort] only in intent: this is a repair value, not a default.
const int kFallbackServerPort = kDefaultServerPort;

/// The low end of the dev-profile port range.
const int kDevPortRangeStart = 7800;

/// The number of ports in the dev range (7800–7899).
const int kDevPortRangeLength = 100;

/// Matches a macOS Flutter dev-build executable path and captures the repo root
/// in group 1:
/// `<repoRoot>/app/build/macos/Build/Products/<cfg>/<name>.app/Contents/MacOS/<exe>`
final RegExp _devBuildPath = RegExp(
  r'^(.*)/app/build/macos/Build/Products/[^/]+/[^/]+\.app/Contents/MacOS/[^/]+$',
);

/// The repo root of a Flutter dev build, or `null` for an installed app.
String? devBuildRepoRoot(String executablePath) =>
    _devBuildPath.firstMatch(executablePath)?.group(1);

/// A human label for a repo root: its last path segment (`feat-profiles`).
String labelForRepoRoot(String repoRoot) =>
    repoRoot.split('/').where((s) => s.isNotEmpty).lastOrNull ?? 'makit';

/// 32-bit FNV-1a — a small, deterministic, cross-launch-stable string hash.
/// (Dart's `String.hashCode` is not guaranteed stable across runs.)
int fnv1a(String s) {
  var hash = 0x811c9dc5;
  for (final c in s.codeUnits) {
    hash ^= c;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// The 8-hex-char id a dev build *starts* from. Only a first guess: the registry
/// resolves collisions, and once minted the id is persisted forever (SPEC-50 D3).
String devIdGuess(String repoRoot) =>
    fnv1a(repoRoot).toRadixString(16).padLeft(8, '0');

/// The port a dev build *starts* probing from. Only a first guess: 100 slots for
/// an unbounded number of worktrees means collisions are expected, so the
/// registry probes upward from here and persists the result (SPEC-50 D4).
int devPortGuess(String repoRoot) =>
    kDevPortRangeStart + (fnv1a(repoRoot) % kDevPortRangeLength);
