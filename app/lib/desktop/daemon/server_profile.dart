/// The isolated server **profile** an app instance runs against.
///
/// A profile owns a whole server instance: its own `MAKIT_HOME` (and therefore
/// its own daemon, database, media, pairings and projects), its own port, and
/// its own slice of app preferences. Several may run at once — a `Work` profile
/// and a feature worktree's dev profile coexist on different ports without
/// seeing each other. See `docs/specs/2026-08-10-SPEC-50-profiles.md`.
///
/// Identity is **persisted, not derived** (SPEC-50 D3). `ProfileRegistry` mints
/// [id] once into `~/.makit/profiles.json`; path-hashing survives only as the
/// bootstrap for a dev build the registry has never seen. Deriving the id from
/// the filesystem path — as this class used to — silently orphaned a profile's
/// home, pairings and prefs whenever a worktree moved.
library;

import 'dart:io' show Platform;

import 'server_profile_paths.dart';

String _resolvedExecutable() => Platform.resolvedExecutable;
String _homeDir() => Platform.environment['HOME'] ?? '';

/// How a profile came into existence.
enum ProfileKind {
  /// Created deliberately by the user (e.g. `Work`, `Personal`). Never
  /// auto-removed, and never considered stale.
  user,

  /// Auto-created for a Flutter dev build so a worktree cannot collide with the
  /// installed app. Carries an [ServerProfile.origin] and can go stale.
  dev,
}

/// Which on-disk key layout a profile's preferences and secrets use.
///
/// This is a **compatibility** fact, frozen at creation — deliberately separate
/// from [ServerProfile.name], which is a UI fact the user may change at will
/// (SPEC-50 D2). Fusing the two into one `isDefault` boolean was what made the
/// installed profile un-renameable.
enum ProfileStorage {
  /// The shipped layout: unprefixed preference keys (so the effective
  /// `NSUserDefaults` key stays `flutter.<key>`) and the unsuffixed secure-store
  /// file. **At most one profile may use this**, and it is implicitly protected:
  /// it is the profile holding `AuthKey_*.p8`, `ota/`, `push.json` and
  /// `host.json`.
  legacy,

  /// Keys and secrets namespaced by [ServerProfile.id].
  namespaced,
}

/// Matches an id safe to interpolate into a path or a preference key.
final RegExp _safeProfileId = RegExp(r'^[a-z0-9][a-z0-9-]*$');

/// Whether [id] is safe to use in a filesystem path and a preference key.
///
/// Lowercase alphanumerics and `-` only, and never empty. Rejects `.`, `/`, `..`
/// and every separator, which is what keeps a hand-edited `profiles.json` from
/// steering a file operation out of its directory.
bool isSafeProfileId(String id) =>
    id.isNotEmpty && id.length <= 64 && _safeProfileId.hasMatch(id);

/// A persisted server profile. Immutable; mutate via [copyWith].
class ServerProfile {
  /// Creates a profile. Prefer `ProfileRegistry` over constructing directly.
  const ServerProfile({
    required this.id,
    required this.name,
    required this.kind,
    required this.home,
    required this.port,
    required this.storage,
    this.origin,
  });

  /// Reads a profile from its `profiles.json` object, tolerating unknown and
  /// missing fields so a newer registry never hard-fails an older build.
  ///
  /// Returns `null` when the entry lacks the fields that have no safe default
  /// ([id], [home]) — the caller drops it rather than inventing an identity — or
  /// when [id] is not a safe slug.
  ///
  /// The charset check is a containment guard, not tidiness: `id` is interpolated
  /// into a filesystem path (the secure-store namespace file) and into preference
  /// keys. `profiles.json` is a plain user-writable file, so a hand-edited id of
  /// `../../../../tmp/x` would otherwise steer a delete outside the app-support
  /// directory. Anything the registry itself mints already satisfies this.
  static ServerProfile? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final home = json['home'];
    if (id is! String || !isSafeProfileId(id)) return null;
    if (home is! String || home.isEmpty) return null;
    final port = json['port'];
    final name = json['name'];
    final origin = json['origin'];
    return ServerProfile(
      id: id,
      name: (name is String && name.isNotEmpty) ? name : id,
      kind: json['kind'] == 'dev' ? ProfileKind.dev : ProfileKind.user,
      home: home,
      port: (port is int && port > 0) ? port : kFallbackServerPort,
      storage: json['storage'] == 'legacy'
          ? ProfileStorage.legacy
          : ProfileStorage.namespaced,
      origin: (origin is String && origin.isNotEmpty) ? origin : null,
    );
  }

  /// Serialises to its `profiles.json` object. `origin` is omitted when absent
  /// so a user profile's entry stays free of null noise.
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'home': home,
    'port': port,
    'storage': storage.name,
    if (origin != null) 'origin': origin,
  };

  /// A profile derived from [executablePath] alone, without consulting the
  /// registry.
  ///
  /// The fallback for contexts that have no registry: widget tests, and a safety
  /// net should a future entry point forget to override `serverProfileProvider`.
  /// It reproduces what `ProfileRegistry.resolveFor` mints for the same path —
  /// same id, home and *guessed* port — but persists nothing and does **not**
  /// probe the port, so two bootstrap profiles can collide. Production resolves
  /// through the registry, which persists identity and probes (SPEC-50 D3/D4).
  static ServerProfile bootstrap({String? executablePath, String? home}) {
    final exe = executablePath ?? _resolvedExecutable();
    final resolvedHome = home ?? _homeDir();
    final repoRoot = devBuildRepoRoot(exe);
    if (repoRoot == null) {
      return ServerProfile(
        id: 'default',
        name: 'Makit',
        kind: ProfileKind.user,
        home: '$resolvedHome/.makit',
        port: kDefaultServerPort,
        storage: ProfileStorage.legacy,
      );
    }
    final id = devIdGuess(repoRoot);
    return ServerProfile(
      id: id,
      name: labelForRepoRoot(repoRoot),
      kind: ProfileKind.dev,
      home: '$resolvedHome/.makit-dev/$id',
      port: devPortGuess(repoRoot),
      storage: ProfileStorage.namespaced,
      origin: repoRoot,
    );
  }

  /// Stable, filesystem- and prefs-safe key. Minted once and never re-derived.
  final String id;

  /// What the user calls this profile. Editable, and shown in the window title,
  /// the switcher badge and the Profiles list.
  final String name;

  /// Whether the user created this profile or a dev build did.
  final ProfileKind kind;

  /// Absolute `MAKIT_HOME` this profile's daemon and control socket live under.
  final String home;

  /// The port this profile's daemon binds. Allocated once by probing and
  /// persisted (SPEC-50 D4) — never recomputed from a hash.
  final int port;

  /// Which on-disk key layout this profile uses. Frozen at creation.
  final ProfileStorage storage;

  /// For [ProfileKind.dev]: the repo root this profile was created from.
  ///
  /// Two jobs, both cheap: re-bind a moved or rebuilt dev build to its existing
  /// profile instead of forking a new one, and detect staleness with a plain
  /// `existsSync` (SPEC-50 D3/D9) — no hashing, no guessing.
  final String? origin;

  /// Where this profile's daemon exposes its control socket.
  String get controlSocketPath => '$home/control.sock';

  /// The prefix this profile's **own** preference keys carry.
  ///
  /// Deliberately *not* `SharedPreferences.setPrefix`, which throws once
  /// `getInstance()` has run and so makes in-place switching impossible
  /// (SPEC-50 D11). Because the plugin composes keys by plain concatenation,
  /// `'flutter.' + '<id>.key'` and today's `setPrefix('flutter.<id>.') + 'key'`
  /// produce a byte-identical stored key — so adopting this needs no migration.
  ///
  /// **Not yet in use.** [prefsPrefix] is still what runs; this getter exists so
  /// the equivalence can be asserted by test before the switch-over lands.
  String get prefsKeyPrefix => storage == ProfileStorage.legacy ? '' : '$id.';

  /// The global `SharedPreferences.setPrefix` value used **today**.
  ///
  /// Interim: this is the mechanism [prefsKeyPrefix] replaces under SPEC-50 D11.
  /// It cannot support in-place profile switching (the plugin throws if the
  /// prefix changes after `getInstance()`), but it is what ships right now, and
  /// swapping the two is a separate, testable step. The invariant tying them
  /// together — `prefsPrefix + key == 'flutter.' + prefsKeyPrefix + key` — is
  /// asserted in `profile_registry_test.dart`.
  String get prefsPrefix =>
      storage == ProfileStorage.legacy ? 'flutter.' : 'flutter.$id.';

  /// The secure-store namespace, or `null` for the legacy unsuffixed file.
  String? get secureStoreNamespace =>
      storage == ProfileStorage.legacy ? null : id;

  /// True when this profile may never be deleted. Implied by
  /// [ProfileStorage.legacy] rather than stored separately, so the two can never
  /// drift apart.
  bool get isProtected => storage == ProfileStorage.legacy;

  /// The native window title, so builds are distinguishable in Cmd-Tab.
  String get windowTitle => 'Makit — $name';

  /// The `MAKIT_HOME` override passed to this profile's spawned `makit` CLI.
  Map<String, String> get environment => {'MAKIT_HOME': home};

  /// Returns a copy with the given overrides. [storage], [id] and [kind] are
  /// deliberately absent: they are frozen at creation.
  ServerProfile copyWith({
    String? name,
    String? home,
    int? port,
    String? origin,
  }) => ServerProfile(
    id: id,
    name: name ?? this.name,
    kind: kind,
    home: home ?? this.home,
    port: port ?? this.port,
    storage: storage,
    origin: origin ?? this.origin,
  );

  @override
  bool operator ==(Object other) =>
      other is ServerProfile &&
      other.id == id &&
      other.name == name &&
      other.kind == kind &&
      other.home == home &&
      other.port == port &&
      other.storage == storage &&
      other.origin == origin;

  @override
  int get hashCode => Object.hash(id, name, kind, home, port, storage, origin);

  @override
  String toString() =>
      'ServerProfile($id, $name, ${kind.name}, $home, $port, ${storage.name})';
}
