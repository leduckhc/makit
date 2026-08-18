/// Atomic, four-store deletion of a server profile (SPEC-profiles D8).
///
/// A profile is not one directory. Erasing it means clearing **all four** of the
/// stores that back it, or the leftovers rot:
///
/// 1. `$MAKIT_HOME/` — the database, media, pairings, projects, certs and logs.
/// 2. The secure-store namespace file — the pairing bearer (`secure_store.<id>`).
/// 3. The profile's scoped preference keys (`<id>.*`).
/// 4. The registry entry in `profiles.json`.
///
/// Deleting only (1) leaks the other three; omitting (4) resurrects the profile
/// *empty* on the next launch. This class removes what it verifiably can and
/// **names what it skipped and why** — it never pretends to have purged a store
/// it cannot reach (see the prefs note on [ProfileDeleter.delete]).
///
/// Guards, in order and all refusals rather than throws: never the protected
/// legacy profile, never the currently active profile, never a `home` outside
/// `~/.makit*` (a corrupt registry entry must not delete the user's disk), and
/// never any unlink while the daemon is still confirmed live.
library;

import 'dart:io';

import 'profile_lifecycle.dart';
import 'profile_registry.dart';
import 'server_profile.dart';

/// The disposition of a [ProfileDeleter.delete] call.
enum ProfileDeletionOutcome {
  /// The profile's stores were erased (some may be [ProfileDeletionResult.skipped]).
  deleted,

  /// Refused: the profile is the protected legacy profile.
  refusedProtected,

  /// Refused: the profile is the currently active one.
  refusedActive,

  /// Refused: the profile's `home` is not under `~/.makit*`.
  refusedUnsafePath,

  /// Refused: the daemon would not stop, so nothing was unlinked.
  refusedDaemonRunning,
}

/// What a deletion did: its [outcome], a best-effort [bytesFreed], the human
/// descriptions of each store [removed], and each store [skipped] with its
/// reason. Immutable.
class ProfileDeletionResult {
  /// Creates a result.
  const ProfileDeletionResult({
    required this.outcome,
    this.bytesFreed = 0,
    this.removed = const [],
    this.skipped = const [],
  });

  /// What happened.
  final ProfileDeletionOutcome outcome;

  /// Best-effort sum of bytes reclaimed from the stores actually removed.
  final int bytesFreed;

  /// Human descriptions of the stores that were erased.
  final List<String> removed;

  /// Human descriptions of the stores that were *not* erased, each with a reason.
  final List<String> skipped;

  /// Whether the profile was deleted (as opposed to refused).
  bool get ok => outcome == ProfileDeletionOutcome.deleted;
}

/// The narrow filesystem slice the deleter needs, injected so tests never touch
/// a real disk.
abstract interface class ProfileFileSystem {
  /// Whether [path] exists (file or directory).
  bool exists(String path);

  /// Whether [path] exists **and is a directory**. Distinguished from [exists]
  /// because a `home` that is a regular file would silently no-op a recursive
  /// directory delete while still looking removed.
  bool isDirectory(String path);

  /// Recursive byte sum of [path] (a file's own size, or every file under a
  /// directory). `0` when [path] does not exist.
  Future<int> sizeOf(String path);

  /// Recursively deletes the directory at [path]. A no-op when absent.
  Future<void> deleteDirectory(String path);

  /// Deletes the file at [path]. A no-op when absent.
  Future<void> deleteFile(String path);

  /// Resolves [path] to its canonical real path, following symlinks in every
  /// ancestor component. Returns `null` when the path does not exist or cannot
  /// be resolved — the destructive guard treats “cannot resolve” as “no symlink
  /// to verify” and falls back to the lexical check.
  String? resolveRealPath(String path);
}

/// [ProfileFileSystem] over `dart:io`.
class RealProfileFileSystem implements ProfileFileSystem {
  /// Creates the real filesystem adapter.
  const RealProfileFileSystem();

  @override
  bool exists(String path) =>
      File(path).existsSync() || Directory(path).existsSync();

  @override
  bool isDirectory(String path) => Directory(path).existsSync();

  @override
  Future<int> sizeOf(String path) async {
    final dir = Directory(path);
    if (dir.existsSync()) {
      var total = 0;
      try {
        await for (final entity in dir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) {
            try {
              total += await entity.length();
            } on FileSystemException {
              // Skip an entry that vanished mid-walk rather than aborting the
              // sum.
            }
          }
        }
      } on FileSystemException {
        // An unreadable directory (permissions) must not throw out of a size
        // probe: report what was measured so far rather than failing the UI.
      }
      return total;
    }
    final file = File(path);
    if (file.existsSync()) {
      try {
        return await file.length();
      } on FileSystemException {
        return 0;
      }
    }
    return 0;
  }

  @override
  Future<void> deleteDirectory(String path) async {
    final dir = Directory(path);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  @override
  Future<void> deleteFile(String path) async {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }

  @override
  String? resolveRealPath(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      try {
        return File(path).resolveSymbolicLinksSync();
      } on FileSystemException {
        return null;
      }
    }
  }
}

/// Erases a profile across all four of its stores, or refuses with a reason.
class ProfileDeleter {
  /// Creates a deleter.
  ///
  /// [registry] owns the entry removed last; [lifecycle] stops and confirms the
  /// daemon; [activeProfileId] is the profile this window currently runs (never
  /// deletable); [homeDir] is the user's home (`~`), used to bound the safe path
  /// and locate the macOS secure-store file; [fs] is the filesystem slice.
  ProfileDeleter({
    required this.registry,
    required this.lifecycle,
    required this.activeProfileId,
    String? homeDir,
    ProfileFileSystem? fs,
    bool? isMacOS,
    Future<int> Function(ServerProfile profile)? purgePrefs,
  }) : homeDir = homeDir ?? (Platform.environment['HOME'] ?? ''),
       fs = fs ?? const RealProfileFileSystem(),
       _isMacOS = isMacOS ?? Platform.isMacOS,
       _purgePrefs = purgePrefs;

  /// The registry whose entry is removed last.
  final ProfileRegistry registry;

  /// Stops and confirms the daemon before any unlink.
  final ProfileLifecycle lifecycle;

  /// The currently active profile's id — refused to protect the live window.
  final String activeProfileId;

  /// The user's home directory (`~`).
  final String homeDir;

  /// The filesystem slice.
  final ProfileFileSystem fs;

  final bool _isMacOS;

  /// Purges a profile's preference keys, returning how many were removed (or a
  /// negative number when the scope refuses, e.g. the unscoped legacy view).
  /// Null where no prefs are wired (tests, headless contexts), in which case the
  /// store is honestly reported as skipped.
  final Future<int> Function(ServerProfile profile)? _purgePrefs;

  /// Recursive byte sum of [profile]'s `MAKIT_HOME`, for the Profiles UI size
  /// column. `0` when the home is gone. Does not include the tiny secure-store
  /// file, which is not part of the profile's disk footprint the user cares about.
  ///
  /// Refuses to measure a home the deleter would refuse to delete for being
  /// outside `~/.makit*` (a corrupt `profiles.json` with `home: "/"` would
  /// otherwise walk the whole disk). Unlike deletion, the protected legacy home
  /// (`~/.makit` itself, which has no child segment) is measurable, so this uses
  /// a containment check rather than the stricter delete guard.
  Future<int> diskUsage(ServerProfile profile) async {
    if (!_isMeasurableHome(profile)) return 0;
    return fs.sizeOf(profile.home);
  }

  /// Whether [profile]'s home is a concrete path at or under `~/.makit*`, so it
  /// is safe to recursively measure. Broader than [_unsafeHomeReason] by design:
  /// it admits the legacy `~/.makit` home, which is measurable but not deletable.
  bool _isMeasurableHome(ServerProfile profile) {
    final home = _canonical(profile.home);
    if (home == null) return false;
    final base = _canonical(homeDir);
    if (base == null) return false;
    return home == '$base/.makit' ||
        home.startsWith('$base/.makit/') ||
        home.startsWith('$base/.makit-dev/');
  }

  /// Erases [profile] across its four stores, or refuses.
  ///
  /// The prefs store (3) is purged through the injected `purgePrefs` hook. This
  /// is reachable because prefs are scoped by **key prefix**
  /// (`ProfileScopedPrefs`) rather than the global
  /// `SharedPreferences.setPrefix`, which could not be re-called after
  /// `getInstance()` and so pinned this process to the active profile. Where no
  /// prefs are wired (tests, headless contexts) the store is honestly reported in
  /// [ProfileDeletionResult.skipped] rather than silently no-op'd.
  Future<ProfileDeletionResult> delete(ServerProfile profile) async {
    if (profile.isProtected) {
      return const ProfileDeletionResult(
        outcome: ProfileDeletionOutcome.refusedProtected,
        skipped: ['protected legacy profile is never deletable'],
      );
    }
    if (profile.id == activeProfileId) {
      return const ProfileDeletionResult(
        outcome: ProfileDeletionOutcome.refusedActive,
        skipped: ['the active profile cannot be deleted from under itself'],
      );
    }
    final unsafe = _unsafeHomeReason(profile);
    if (unsafe != null) {
      return ProfileDeletionResult(
        outcome: ProfileDeletionOutcome.refusedUnsafePath,
        skipped: [unsafe],
      );
    }

    final stopped = await lifecycle.stopAndConfirm(profile);
    if (!stopped) {
      return const ProfileDeletionResult(
        outcome: ProfileDeletionOutcome.refusedDaemonRunning,
        skipped: [
          'daemon still running — refused to unlink under a live daemon',
        ],
      );
    }

    final removed = <String>[];
    final skipped = <String>[];
    var bytesFreed = 0;

    // (1) $MAKIT_HOME/
    //
    // Every store operation below is best-effort: a failure after the home is
    // erased must not throw out of the method, or the caller gets no result and
    // the registry entry survives to resurrect an empty home next launch. Each
    // failure is recorded in `skipped` and a result is always returned.
    try {
      if (fs.isDirectory(profile.home)) {
        bytesFreed += await fs.sizeOf(profile.home);
        await fs.deleteDirectory(profile.home);
        removed.add('MAKIT_HOME ${profile.home}');
      } else if (fs.exists(profile.home)) {
        // A regular file at `home` is not a profile home. A recursive directory
        // delete silently no-ops on it, so reporting it removed would be a lie;
        // erase it as a file instead.
        bytesFreed += await fs.sizeOf(profile.home);
        await fs.deleteFile(profile.home);
        removed.add('MAKIT_HOME ${profile.home} (was a file, not a directory)');
      } else {
        skipped.add('MAKIT_HOME ${profile.home}: already absent');
      }
    } on FileSystemException catch (e) {
      skipped.add('MAKIT_HOME ${profile.home}: $e');
    }

    // (2) secure-store namespace file
    final securePath = _secureStorePath(profile);
    if (securePath == null) {
      skipped.add(
        'secure store: no namespaced file to delete on this platform/profile',
      );
    } else {
      try {
        if (fs.exists(securePath)) {
          bytesFreed += await fs.sizeOf(securePath);
          await fs.deleteFile(securePath);
          removed.add('secure store $securePath');
        } else {
          skipped.add('secure store $securePath: already absent');
        }
      } on FileSystemException catch (e) {
        skipped.add('secure store $securePath: $e');
      }
    }

    // (3) preference keys. Reachable for a non-active profile now that prefs are
    // scoped by key prefix (ProfileScopedPrefs) rather than the global
    // SharedPreferences.setPrefix, so this actually purges instead of always
    // reporting the store skipped.
    final purge = _purgePrefs;
    if (purge == null) {
      skipped.add(
        'preference keys under "${profile.prefsKeyPrefix}": no prefs wired in '
        'this context',
      );
    } else {
      try {
        final count = await purge(profile);
        if (count < 0) {
          skipped.add(
            'preference keys under "${profile.prefsKeyPrefix}": refused — an '
            'unscoped view cannot tell this profile\'s keys from another\'s',
          );
        } else {
          removed.add(
            '$count preference key(s) under "${profile.prefsKeyPrefix}"',
          );
        }
      } catch (e) {
        skipped.add('preference keys under "${profile.prefsKeyPrefix}": $e');
      }
    }

    // (4) registry entry, LAST
    try {
      if (registry.remove(profile.id)) {
        registry.save();
        removed.add('registry entry ${profile.id}');
      } else {
        skipped.add('registry entry ${profile.id}: not present');
      }
    } on FileSystemException catch (e) {
      skipped.add(
        'registry entry ${profile.id}: could not persist removal: $e',
      );
    }

    return ProfileDeletionResult(
      outcome: ProfileDeletionOutcome.deleted,
      bytesFreed: bytesFreed,
      removed: removed,
      skipped: skipped,
    );
  }

  /// Why [profile]'s home must not be deleted, or `null` when it is safe.
  ///
  /// This is the guard that matters most: `profiles.json` is a plain
  /// user-writable file, so `home` is attacker-influenced. A corrupt entry
  /// pointing at `/` or `~` must never become a recursive delete of the
  /// user's disk.
  ///
  /// **Canonicalise before comparing.** An earlier version compared raw strings
  /// and was defeated by a single trailing slash: `~/.makit/` is not `==` to
  /// `~/.makit`, so a legacy-home check missed it while `startsWith('~/.makit/')`
  /// happily matched — and the delete erased `AuthKey_*.p8`, `server.key`,
  /// `devices.json`, `ota/`, `push.json` and `host.json`. `//`, `/.` and
  /// `/.makit-dev/../.makit` were the same class of bypass.
  ///
  /// Three rules, each proven to bite on its own by mutation:
  /// 1. The path must be absolute and canonical — no empty, `.` or `..` segments.
  ///    The registry only ever writes canonical paths, so a non-canonical home is
  ///    itself evidence the file was hand-edited. This is what stops
  ///    `~/.makit-dev/../../Documents`, which passes containment on its prefix.
  /// 2. It must sit **strictly inside** `~/.makit/` or `~/.makit-dev/`, with at
  ///    least one further segment. A bare `startsWith('$homeDir/.makit')`
  ///    accepted `~/.makitEVIL`; and requiring a child segment is what protects
  ///    the legacy home itself — `~/.makit` has no child — as well as the bare
  ///    `~/.makit-dev` container that every dev profile lives under.
  /// 3. A home another registry entry also claims is refused: deleting it would
  ///    erase that profile's data behind its back. This also covers a rogue entry
  ///    aimed at a *relocated* legacy home, since the legacy entry is itself in
  ///    the registry and would share it.
  ///
  /// A fourth rule — "refuse `home == registry.legacyProfile.home`" — was written
  /// and then removed: rules 2 and 3 already cover every reachable case, and
  /// mutation testing showed no test could distinguish its presence. Unreachable
  /// code on a destructive path is worse than no code, because it invites the
  /// belief that it is doing something.
  ///
  /// Note the entry's own `isProtected` flag is checked by the caller but is NOT
  /// relied on here: it lives in the same user-writable file.
  String? _unsafeHomeReason(ServerProfile profile) {
    final home = _canonical(profile.home);
    if (home == null) {
      return 'home "${profile.home}" is not an absolute, canonical path '
          '— refused';
    }
    final base = _canonical(homeDir);
    if (base == null) return 'no usable home directory — refused';
    if (home == base) return 'home is the home directory itself — refused';

    // Rule 2: strictly inside, with a real profile segment of its own.
    final inside =
        home.startsWith('$base/.makit/') ||
        home.startsWith('$base/.makit-dev/');
    if (!inside) {
      return 'home "$home" is not inside ~/.makit/ or ~/.makit-dev/ — refused';
    }

    // Rule 3: never a home another entry also claims.
    final sharers = registry.profiles.where(
      (p) => p.id != profile.id && _canonical(p.home) == home,
    );
    if (sharers.isNotEmpty) {
      return 'home "$home" is also claimed by "${sharers.first.id}" — refused';
    }

    // Rule 4: the *symlink-resolved* path must also be contained. The lexical
    // rules above are defeated by a symlinked ancestor: `~/.makit/profiles` may
    // itself be a link to an external directory, so a recursive delete would
    // follow it and destroy data outside `~/.makit*`. `Directory.delete` follows
    // ancestor symlinks, so the guard must too. Both sides are resolved so a
    // symlinked home dir (e.g. macOS temp `/var` → `/private/var`) is not a
    // false positive. "Cannot resolve" (absent path) falls back to the lexical
    // rules, since there is then nothing on disk to follow.
    final real = fs.resolveRealPath(profile.home);
    if (real != null) {
      final realHome = _canonical(real);
      final resolvedBase = fs.resolveRealPath(homeDir);
      final realBase = resolvedBase != null ? _canonical(resolvedBase) : base;
      final insideReal =
          realHome != null &&
          realBase != null &&
          (realHome.startsWith('$realBase/.makit/') ||
              realHome.startsWith('$realBase/.makit-dev/'));
      if (!insideReal) {
        return 'home "${profile.home}" resolves via symlink to "$real", '
            'outside ~/.makit/ or ~/.makit-dev/ — refused';
      }
    }
    return null;
  }

  /// An absolute path with duplicate separators collapsed, any trailing separator
  /// removed, and `null` when it is relative or contains a `.`/`..` segment.
  ///
  /// Rejecting rather than resolving `..` is deliberate: resolving would require
  /// touching the filesystem (and would follow symlinks), while the registry has
  /// no legitimate reason to ever produce such a path.
  static String? _canonical(String path) {
    if (path.isEmpty || !path.startsWith('/')) return null;
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.any((s) => s == '.' || s == '..')) return null;
    if (segments.isEmpty) return null;
    return '/${segments.join('/')}';
  }

  /// The macOS secure-store file for [profile], mirroring `defaultSecureStore`
  /// in `lib/store/secure_store.dart`. `null` on non-macOS (keychain-backed, no
  /// file to unlink) or for the unsuffixed legacy file (which is protected).
  String? _secureStorePath(ServerProfile profile) {
    if (!_isMacOS) return null;
    final namespace = profile.secureStoreNamespace;
    if (namespace == null || namespace.isEmpty) return null;
    return '$homeDir/Library/Application Support/dev.getmakit.app/'
        'secure_store.$namespace.json';
  }
}
