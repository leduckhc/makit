/// The persisted set of server profiles, and the identity rules around it.
///
/// Backed by a single small JSON file, `<makitRoot>/profiles.json`, which is the
/// **source of truth for identity** (SPEC-50 D3). Before this existed a
/// profile's id was `fnv1a(repoRoot)` recomputed on every launch, so moving or
/// renaming a worktree minted a *new* profile and silently orphaned the old
/// one's `MAKIT_HOME`, pairings, projects and prefs. Measured on the author's
/// machine: 27 of 33 dev profile homes were already unreachable.
///
/// The registry also owns port allocation, because a port must be unique across
/// profiles — a set-wide invariant no single profile can enforce.
library;

import 'dart:convert';
import 'dart:io';

import 'server_profile.dart';
import 'server_profile_paths.dart';

/// Probes whether [port] is free. Injected so tests never bind real sockets.
typedef PortProbe = Future<bool> Function(int port);

/// Binds and immediately releases [port] on the loopback interface.
///
/// Loopback specifically: the daemon may bind a Tailscale or LAN address, but a
/// conflict on *any* interface of the same port is what matters, and loopback is
/// the one interface guaranteed to exist. `shared: false` so the probe cannot
/// succeed against a socket another process already holds.
Future<bool> probePortIsFree(int port) async {
  ServerSocket? socket;
  try {
    socket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      port,
      shared: false,
    );
    return true;
  } on SocketException {
    return false;
  } finally {
    await socket?.close();
  }
}

/// The profile set, loaded from and saved to `<makitRoot>/profiles.json`.
class ProfileRegistry {
  /// Creates a registry over [profiles]. Prefer [load].
  ///
  /// [fs] is retained so [save] needs no argument: persistence is the registry's
  /// own responsibility, and a caller that mutates it should not have to know
  /// where the bytes go.
  ProfileRegistry({
    required String makitRoot,
    required List<ServerProfile> profiles,
    PortProbe? probe,
    FileSystemAdapter? fs,
  }) : _makitRoot = makitRoot,
       _profiles = [...profiles],
       _probe = probe ?? probePortIsFree,
       _fs = fs ?? const FileSystemAdapter();

  final String _makitRoot;
  final List<ServerProfile> _profiles;
  final PortProbe _probe;
  final FileSystemAdapter _fs;

  /// Ids this instance deleted, so a concurrent-write merge cannot resurrect
  /// them from a stale on-disk copy. Persisted as `deletedIds` tombstones so
  /// *other* instances honour the deletion too (SPEC-50 D1).
  final Set<String> _deleted = {};

  /// Ids this instance actually mutated (rename/setPort/setOrigin/create), so
  /// [save] overrides the on-disk copy only for profiles it truly changed and
  /// never reverts another window's edit to a profile it merely happens to hold.
  final Set<String> _modified = {};

  /// Where the registry file lives.
  String get filePath => '$_makitRoot/profiles.json';

  /// Every known profile, in insertion order. Unmodifiable.
  List<ServerProfile> get profiles => List.unmodifiable(_profiles);

  /// The single [ProfileStorage.legacy] profile, or `null` before one exists.
  ServerProfile? get legacyProfile =>
      _profiles.where((p) => p.storage == ProfileStorage.legacy).firstOrNull;

  /// The profile with [id], or `null`.
  ServerProfile? byId(String id) =>
      _profiles.where((p) => p.id == id).firstOrNull;

  /// Reads the registry, tolerating a missing, empty or corrupt file by
  /// returning an empty registry rather than throwing — a bad `profiles.json`
  /// must never stop the app from launching. Unparseable entries are dropped
  /// individually.
  static ProfileRegistry load({
    required String makitRoot,
    PortProbe? probe,
    FileSystemAdapter? fs,
  }) {
    final io = fs ?? const FileSystemAdapter();
    final raw = io.readOrNull('$makitRoot/profiles.json');
    final deleted = _parseDeletedIds(raw);
    final parsed = raw == null ? const <ServerProfile>[] : _parse(raw);
    // Honour tombstones from any instance, then break any port collisions the
    // file may carry (a hand-edited or fallback port that duplicates another,
    // notably the legacy 7777) before they reach a daemon as `EADDRINUSE`.
    final live = [
      for (final p in parsed)
        if (!deleted.contains(p.id)) p,
    ];
    final reg = ProfileRegistry(
      makitRoot: makitRoot,
      profiles: _dedupePorts(live),
      probe: probe,
      fs: io,
    );
    reg._lastActiveId = _parseLastActive(raw);
    reg._deleted.addAll(deleted);
    return reg;
  }

  /// Reads the `deletedIds` tombstone list, tolerating every shape the file may
  /// take.
  static Set<String> _parseDeletedIds(String? raw) {
    if (raw == null || raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        final v = decoded['deletedIds'];
        if (v is List) {
          return {
            for (final e in v)
              if (e is String && e.isNotEmpty) e,
          };
        }
      }
    } on FormatException {
      return {};
    }
    return {};
  }

  /// Reads `lastActive`, tolerating every shape the file may take.
  static String? _parseLastActive(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        final v = decoded['lastActive'];
        if (v is String && v.isNotEmpty) return v;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// Parses a `profiles.json` body, dropping entries that cannot be trusted.
  ///
  /// Tolerant by design: a bad registry must never stop the app from launching.
  /// A corrupt file yields an empty list, the bootstrap re-creates the legacy
  /// profile, and dev profiles re-bind by `origin`, so little is lost.
  static List<ServerProfile> _parse(String raw) {
    final parsed = <ServerProfile>[];
    var seenLegacy = false;
    try {
      final decoded = jsonDecode(raw);
      final list = decoded is Map<String, Object?>
          ? decoded['profiles']
          : decoded;
      if (list is List) {
        for (final entry in list) {
          if (entry is! Map<String, Object?>) continue;
          final p = ServerProfile.fromJson(entry);
          if (p == null) continue;
          // Drop a duplicate id rather than letting two entries fight over one
          // home: first-seen wins, matching server-side mergeProjects.
          if (parsed.any((e) => e.id == p.id)) continue;
          // At most one legacy profile may exist (SPEC-50 D2): it owns the
          // unprefixed prefs keys and the unsuffixed secure-store file. A
          // hand-edited file with two would silently clobber each other's
          // settings and credentials, so extra legacy entries are dropped.
          if (p.storage == ProfileStorage.legacy) {
            if (seenLegacy) continue;
            seenLegacy = true;
          }
          parsed.add(p);
        }
      }
    } on FormatException {
      return const [];
    }
    return parsed;
  }

  /// Writes the registry atomically, merging in anything another instance added
  /// since this one loaded.
  ///
  /// Several app instances run at once by design (SPEC-50 D1), and each holds its
  /// own in-memory list. A plain whole-file write would therefore *lose* a
  /// profile another window created: window A adds `Personal` and saves; window
  /// B, loaded earlier, saves anything at all and clobbers the file. A `user`
  /// profile has no `origin`, so `resolveFor` could never re-bind it — its home,
  /// pairings and prefs would be exactly the kind of orphan this class exists to
  /// prevent.
  ///
  /// So: re-read immediately before writing and union by id, with **this**
  /// instance winning for ids it knows (its edits are the newer intent) and
  /// unknown ids preserved. Deletions are still honoured: [remove] records the
  /// id in [_deleted] so a merge cannot resurrect it.
  ///
  /// The whole read-merge-write runs under an inter-process advisory lock
  /// ([FileSystemAdapter.withLock]). Union-by-id alone loses an update when two
  /// instances *both* read the same on-disk state before either writes: each
  /// merges in only its own new profile and the second rename drops the first's.
  /// The lock serialises the sequence so the second instance always reads the
  /// first's write.
  ///
  /// `lastActive` is preserved from disk unless *this* instance explicitly set it
  /// via [setLastActive]. A window that loaded before another changed the active
  /// profile would otherwise write its stale (or null) id back on an unrelated
  /// rename/create, silently reopening the wrong profile next launch.
  ///
  /// The temp file is per-process, because two instances sharing one
  /// `profiles.json.tmp` would race and the loser's `renameSync` would throw out
  /// of `save()`.
  void save() {
    _fs.withLock(filePath, () {
      final diskRaw = _fs.readOrNull(filePath);
      // Learn deletions made by other instances so an unrelated save cannot
      // resurrect a profile another window already erased (its on-disk stores
      // are gone, so a revived entry would point at deleted data).
      _deleted.addAll(_parseDeletedIds(diskRaw));
      final diskProfiles = (diskRaw == null || diskRaw.trim().isEmpty)
          ? const <ServerProfile>[]
          : _parse(diskRaw);

      final merged = <String, ServerProfile>{};
      for (final p in diskProfiles) {
        if (_deleted.contains(p.id)) continue;
        merged[p.id] = p;
      }
      for (final p in _profiles) {
        if (_deleted.contains(p.id)) continue;
        // Override the on-disk copy only for profiles THIS instance actually
        // changed (or newly created / not yet on disk). An unmodified profile
        // this window merely holds must not overwrite another window's newer
        // rename/port/origin edit.
        if (_modified.contains(p.id) || !merged.containsKey(p.id)) {
          merged[p.id] = p;
        }
      }
      // Preserve this instance's order for the profiles it knows, then append
      // any it learned about from disk, so the list does not shuffle under the
      // user.
      final ordered = <ServerProfile>[
        for (final p in _profiles)
          if (merged.containsKey(p.id)) merged[p.id]!,
        for (final entry in merged.entries)
          if (!_profiles.any((p) => p.id == entry.key)) entry.value,
      ];
      // Break any port collision the merge produced: two instances can each
      // allocate the same free port before either writes (SPEC-50 D1), so the
      // reconcile happens here, under the lock, on the merged set.
      _profiles
        ..clear()
        ..addAll(_dedupePorts(ordered));

      // Keep the newer on-disk selection unless this instance changed it.
      if (!_lastActiveTouched) {
        _lastActiveId = _parseLastActive(diskRaw) ?? _lastActiveId;
      }

      final body = const JsonEncoder.withIndent('  ').convert({
        'profiles': [for (final p in _profiles) p.toJson()],
        if (_deleted.isNotEmpty) 'deletedIds': (_deleted.toList()..sort()),
        if (_lastActiveId != null) 'lastActive': _lastActiveId,
      });
      _fs.writeAtomic(filePath, '$body\n');
      // These edits are now persisted; a later unrelated save must not re-assert
      // them over another window's newer change (the reverse lost-update).
      _modified.clear();
    });
  }

  /// Reassigns any profile whose port duplicates an earlier one to a free port
  /// in the dev range, so no two profiles ever claim the same port.
  ///
  /// Protected (legacy) profiles keep their port unconditionally — 7777 is the
  /// shipped default and the one every device is paired against. A synchronous,
  /// deterministic reassignment (no probe) is enough: it only has to make the
  /// *set* internally consistent; a port also held by an external process is
  /// still caught by the daemon's own `EADDRINUSE` path.
  static List<ServerProfile> _dedupePorts(List<ServerProfile> profiles) {
    final claimed = <int>{
      for (final p in profiles)
        if (p.isProtected) p.port,
    };
    final result = <ServerProfile>[];
    for (final p in profiles) {
      if (p.isProtected) {
        result.add(p);
        continue;
      }
      if (!claimed.contains(p.port)) {
        claimed.add(p.port);
        result.add(p);
      } else {
        final port = _firstFreeDevPort(claimed);
        claimed.add(port);
        result.add(p.copyWith(port: port));
      }
    }
    return result;
  }

  /// The lowest dev-range port not in [claimed], wrapping to the range start.
  static int _firstFreeDevPort(Set<int> claimed) {
    for (var i = 0; i < kDevPortRangeLength; i++) {
      final candidate = kDevPortRangeStart + i;
      if (!claimed.contains(candidate)) return candidate;
    }
    // Every dev port is claimed (thousands of profiles): fall back to the start
    // and let the daemon's EADDRINUSE path sort it out rather than throwing.
    return kDevPortRangeStart;
  }

  /// Resolves the profile this executable should run against, creating one when
  /// the registry has never seen it.
  ///
  /// Bootstrap rules (SPEC-50 D3):
  /// - Not a dev-build path → the [ProfileStorage.legacy] profile, created with
  ///   the shipped `~/.makit` + port 7777 defaults if absent.
  /// - A dev-build path → the profile whose [ServerProfile.origin] matches this
  ///   repo root, so a *rebuilt* app re-binds instead of forking. Otherwise a
  ///   new `dev` profile with a freshly probed port.
  ///
  /// Reports whether the registry changed, so the caller decides when to [save].
  Future<({ServerProfile profile, bool created})> resolveFor({
    required String executablePath,
    required String home,
  }) async {
    final repoRoot = devBuildRepoRoot(executablePath);
    if (repoRoot == null) {
      final existing = legacyProfile;
      if (existing != null) return (profile: existing, created: false);
      final created = ServerProfile(
        id: 'default',
        name: 'Makit',
        kind: ProfileKind.user,
        home: '$home/.makit',
        port: kDefaultServerPort,
        storage: ProfileStorage.legacy,
      );
      _profiles.insert(0, created);
      _modified.add(created.id);
      return (profile: created, created: true);
    }

    final matched = _profiles
        .where((p) => p.kind == ProfileKind.dev && p.origin == repoRoot)
        .firstOrNull;
    if (matched != null) return (profile: matched, created: false);

    final id = _uniqueId(devIdGuess(repoRoot));
    final created = ServerProfile(
      id: id,
      name: labelForRepoRoot(repoRoot),
      kind: ProfileKind.dev,
      home: '$home/.makit-dev/$id',
      port: await allocatePort(startingGuess: devPortGuess(repoRoot)),
      storage: ProfileStorage.namespaced,
      origin: repoRoot,
    );
    _profiles.add(created);
    _modified.add(id);
    return (profile: created, created: true);
  }

  /// Creates a user profile named [name] under `<makitRoot>/profiles/<id>`.
  ///
  /// Throws [ArgumentError] on a blank name so a nameless row can never reach
  /// the registry.
  Future<ServerProfile> createUserProfile({required String name}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be blank');
    }
    final id = _uniqueId(_slug(trimmed));
    final created = ServerProfile(
      id: id,
      name: trimmed,
      kind: ProfileKind.user,
      home: '$_makitRoot/profiles/$id',
      port: await allocatePort(startingGuess: kDevPortRangeStart),
      storage: ProfileStorage.namespaced,
    );
    _profiles.add(created);
    _modified.add(id);
    return created;
  }

  /// Renames [id]. Returns false when no such profile exists or [name] is blank.
  bool rename(String id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final i = _profiles.indexWhere((p) => p.id == id);
    if (i < 0) return false;
    _profiles[i] = _profiles[i].copyWith(name: trimmed);
    _modified.add(id);
    return true;
  }

  /// Removes [id] from the registry. Refuses a protected (legacy) profile —
  /// deleting it would take `AuthKey_*.p8`, `ota/` and `push.json` with it.
  ///
  /// This drops only the *entry*; erasing the on-disk stores is the deleter's
  /// job, and it calls this last.
  bool remove(String id) {
    final p = byId(id);
    if (p == null || p.isProtected) return false;
    _profiles.removeWhere((e) => e.id == id);
    _deleted.add(id);
    return true;
  }

  /// Replaces [id]'s stored port, e.g. after an `EADDRINUSE` retry, so the new
  /// port survives the next launch instead of colliding again.
  bool setPort(String id, int port) {
    final i = _profiles.indexWhere((p) => p.id == id);
    if (i < 0 || port <= 0 || port > 65535) return false;
    _profiles[i] = _profiles[i].copyWith(port: port);
    _modified.add(id);
    return true;
  }

  /// Re-points [id]'s `origin` (and nothing else) at [repoRoot], for when a dev
  /// build is recognised at a new location.
  bool setOrigin(String id, String repoRoot) {
    final i = _profiles.indexWhere((p) => p.id == id);
    if (i < 0) return false;
    _profiles[i] = _profiles[i].copyWith(origin: repoRoot);
    _modified.add(id);
    return true;
  }

  /// The profile the user last switched to, or `null`.
  ///
  /// Read only when the *installed* app launches (see [preferredFor]): a dev
  /// build must always open its own profile, or building a worktree would
  /// silently reopen `Work` and look like the build did nothing.
  String? get lastActiveId => _lastActiveId;
  String? _lastActiveId;

  /// Whether *this* instance explicitly chose the last-active profile. Guards
  /// [save] from writing a stale in-memory id over a newer on-disk one another
  /// window persisted.
  bool _lastActiveTouched = false;

  /// Records [id] as the last profile the user chose. Returns false for an
  /// unknown id, so a stale value can never be written.
  bool setLastActive(String id) {
    if (byId(id) == null) return false;
    _lastActiveId = id;
    _lastActiveTouched = true;
    return true;
  }

  /// The profile to open for a [bootstrap] resolution.
  ///
  /// Honours [lastActiveId] **only** when the bootstrap profile is the installed
  /// (legacy) one. A dev build always gets its own profile: its whole purpose is
  /// to isolate that worktree, and reopening a different one would defeat it.
  ServerProfile preferredFor(ServerProfile bootstrap) {
    if (bootstrap.storage != ProfileStorage.legacy) return bootstrap;
    final last = _lastActiveId;
    if (last == null || last == bootstrap.id) return bootstrap;
    return byId(last) ?? bootstrap;
  }

  /// The `dev` profiles whose origin folder no longer exists (SPEC-50 D9).
  ///
  /// `user` profiles are never stale: they have no origin and were created
  /// deliberately. [dirExists] is injected so tests need no real directories.
  List<ServerProfile> staleProfiles({bool Function(String path)? dirExists}) {
    final exists = dirExists ?? _realDirExists;
    return [
      for (final p in _profiles)
        if (p.kind == ProfileKind.dev && p.origin != null && !exists(p.origin!))
          p,
    ];
  }

  static bool _realDirExists(String path) => Directory(path).existsSync();

  /// Finds a free port at or above [startingGuess], skipping ports already
  /// claimed by another profile in this registry.
  ///
  /// Two distinct sources of conflict, both real: another *profile* (which may
  /// not be running right now, so a probe would wrongly call its port free) and
  /// another *process*. Registry-claimed ports are excluded up front; the rest
  /// are probed.
  ///
  /// Wraps around the dev range before giving up, and falls back to the guess
  /// when every candidate is busy — the daemon's own `EADDRINUSE` path then
  /// reports it, which is strictly better than throwing during launch.
  Future<int> allocatePort({required int startingGuess}) async {
    final claimed = {for (final p in _profiles) p.port};
    final start = startingGuess < kDevPortRangeStart
        ? kDevPortRangeStart
        : startingGuess;
    for (var i = 0; i < kDevPortRangeLength; i++) {
      final candidate =
          kDevPortRangeStart +
          ((start - kDevPortRangeStart + i) % kDevPortRangeLength);
      if (claimed.contains(candidate)) continue;
      if (await _probe(candidate)) return candidate;
    }
    return startingGuess;
  }

  /// Mints an id from [seed] that is free of both live profiles **and**
  /// tombstoned ids.
  ///
  /// A tombstone (`_deleted`) causes [save] to drop any profile carrying that
  /// id, so reusing a just-deleted slug would silently discard the freshly
  /// created profile and orphan its home. An id is therefore “taken” if a live
  /// profile holds it or a tombstone still names it.
  String _uniqueId(String seed) {
    bool taken(String id) => byId(id) != null || _deleted.contains(id);
    final base = seed.isEmpty ? 'profile' : seed;
    if (!taken(base)) return base;
    for (var n = 2; n < 1000; n++) {
      final candidate = '$base-$n';
      if (!taken(candidate)) return candidate;
    }
    return '$base-${DateTime.now().microsecondsSinceEpoch}';
  }

  /// Whether every profile currently held would survive a save/reload cycle.
  ///
  /// A mint-time invariant: an id the registry creates but
  /// `ServerProfile.fromJson` later rejects would silently vanish on relaunch,
  /// taking the profile's home and pairings with it. Asserted by test after every
  /// mint path. (Not annotated `@visibleForTesting`: this repo co-locates tests
  /// inside `lib/`, where the analyzer does not recognise them as tests.)
  bool get allIdsRoundTrip => _profiles.every((p) => isSafeProfileId(p.id));

  /// Lowercase, `-`-separated, `[a-z0-9-]` only — safe in a path, a prefs key
  /// and a filename.
  ///
  /// Truncated to [_kMaxSlugLength] so the result always satisfies
  /// [isSafeProfileId], which caps ids at 64 characters. Without this cap the
  /// registry would happily *mint* a 100-character id from a long profile name
  /// and then silently **drop that profile** on the next launch, when
  /// `fromJson` rejected it — losing the user's data rather than protecting it.
  /// The margin below 64 leaves room for a `-2`-style uniqueness suffix.
  static String _slug(String name) {
    final s = name
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp('^-+'), '')
        .replaceAll(RegExp(r'-+$'), '');
    if (s.isEmpty) return 'profile';
    if (s.length <= _kMaxSlugLength) return s;
    // Trim to the cap, then drop a trailing '-' so the id never ends in one.
    return s.substring(0, _kMaxSlugLength).replaceAll(RegExp(r'-+$'), '');
  }

  /// Longest slug the registry will mint, leaving room under [isSafeProfileId]'s
  /// 64-character cap for a uniqueness suffix.
  static const int _kMaxSlugLength = 48;
}

/// The narrow slice of filesystem the registry needs, so tests can run without
/// touching a real disk.
class FileSystemAdapter {
  /// Creates an adapter over the real filesystem.
  const FileSystemAdapter();

  /// Directory mode for `~/.makit`, matching the server's `MAKIT_HOME_MODE`.
  static const int homeMode = 0x1c0; // 0700

  /// File mode for registry data, matching the server's `MAKIT_FILE_MODE`.
  static const int fileMode = 0x180; // 0600

  /// Runs [body] while holding an exclusive, inter-process advisory lock keyed
  /// on [path].
  ///
  /// Serialises the registry's read-merge-write across the several app instances
  /// that run at once (SPEC-50 D1). Without it, two instances can each read the
  /// same `profiles.json`, merge in only their own new profile, and have the
  /// second atomic rename silently drop the first's — orphaning a `user`
  /// profile's home, pairings and prefs, since it has no `origin` to re-bind by.
  /// The lock file (`<path>.lock`) is a separate sentinel so the data file's
  /// atomic replace is never itself the locked handle.
  T withLock<T>(String path, T Function() body) {
    final lockFile = File('$path.lock');
    RandomAccessFile? raf;
    try {
      lockFile.parent.createSync(recursive: true);
      raf = lockFile.openSync(mode: FileMode.write);
      raf.lockSync(FileLock.blockingExclusive);
      return body();
    } on FileSystemException {
      // If the lock cannot be taken (e.g. a filesystem that does not support
      // advisory locks), fall back to running unlocked rather than refusing to
      // persist — the union-by-id merge still protects the common case.
      return body();
    } finally {
      try {
        raf?.unlockSync();
      } on FileSystemException {
        // Best effort: the handle is closed next regardless.
      }
      try {
        raf?.closeSync();
      } on FileSystemException {
        // Nothing more to do.
      }
    }
  }

  /// Returns the contents of [path], or `null` when it does not exist or cannot
  /// be read.
  String? readOrNull(String path) {
    try {
      final f = File(path);
      return f.existsSync() ? f.readAsStringSync() : null;
    } on FileSystemException {
      return null;
    }
  }

  /// Writes [contents] to [path] via a temp file + rename, `0600`, inside a
  /// directory forced to `0700`.
  ///
  /// The modes are not cosmetic. The server guarantees `MAKIT_HOME` is `0700` and
  /// its files `0600` (`server/src/daemon/paths.ts`) because that directory holds
  /// an APNs auth key and a TLS private key. `Directory.createSync` gives `0755`
  /// and `writeAsStringSync` gives `0644`, so an app that created the directory
  /// first would silently *downgrade* the server's guarantee and leave those
  /// secrets readable by every local user.
  ///
  /// The temp name carries the pid: several app instances may save concurrently
  /// (SPEC-50 D1), and a shared `foo.tmp` would race — the loser's `renameSync`
  /// throwing a `FileSystemException` out of `save()`.
  void writeAtomic(String path, String contents) {
    final target = File(path);
    final dir = target.parent;
    dir.createSync(recursive: true);
    _chmod(dir.path, homeMode);
    final tmp = File('$path.$pid.tmp');
    tmp.writeAsStringSync(contents, flush: true);
    _chmod(tmp.path, fileMode);
    tmp.renameSync(path);
  }

  /// Best-effort `chmod`. POSIX-only; a failure must not stop the app from
  /// recording its profiles.
  static void _chmod(String path, int mode) {
    if (Platform.isWindows) return;
    try {
      Process.runSync('/bin/chmod', [
        mode.toRadixString(8).padLeft(3, '0'),
        path,
      ]);
    } on ProcessException {
      // Non-fatal: the write itself succeeded.
    }
  }
}
