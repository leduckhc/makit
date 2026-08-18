// Live, real-filesystem tests for [ProfileDeleter] (SPEC-profiles D8).
//
// The unit tests inject a fake filesystem, which is right for covering branches
// but cannot prove the thing that actually matters: that a recursive delete
// removes what it should and *nothing else*, against the real OS. These tests
// build a genuine profile home in a temp directory — database, WAL, media,
// pairings, TLS keypair — delete it through the real code path, and inspect the
// disk afterwards.
//
// Every test scopes `homeDir` to its own temp root, so nothing here can touch
// the developer's real `~/.makit`.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart'
    show MakitCliResolver;
import 'package:makit/desktop/daemon/profile_deleter.dart';
import 'package:makit/desktop/daemon/profile_lifecycle.dart';
import 'package:makit/desktop/daemon/profile_registry.dart';
import 'package:makit/desktop/daemon/server_profile.dart';

/// A lifecycle that reports the daemon already stopped, so these tests exercise
/// the filesystem path rather than process control (covered by its own tests).
class _StoppedLifecycle implements ProfileLifecycle {
  @override
  Future<bool> stopAndConfirm(
    ServerProfile profile, {
    Duration timeout = const Duration(seconds: 5),
  }) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A lifecycle that refuses to stop, to prove nothing is unlinked underneath it.
class _StuckLifecycle implements ProfileLifecycle {
  @override
  Future<bool> stopAndConfirm(
    ServerProfile profile, {
    Duration timeout = const Duration(seconds: 5),
  }) async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('spec50-live-'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Builds a realistic profile home and returns the profile describing it.
  ServerProfile seedProfile({String id = 'dev1', String? homeOverride}) {
    final home = homeOverride ?? '${root.path}/.makit-dev/$id';
    Directory('$home/media').createSync(recursive: true);
    // The files a real home carries, taken from an actual ~/.makit-dev/<id>.
    File('$home/makit.db').writeAsStringSync('sqlite');
    File('$home/makit.db-wal').writeAsStringSync('wal');
    File('$home/makit.db-shm').writeAsStringSync('shm');
    File('$home/devices.json').writeAsStringSync('[{"id":"phone"}]');
    File('$home/projects.json').writeAsStringSync('[]');
    File('$home/server.crt').writeAsStringSync('cert');
    File('$home/server.key').writeAsStringSync('PRIVATE KEY');
    File('$home/makit.log').writeAsStringSync('log');
    File('$home/media/shot.png').writeAsStringSync('png');
    return ServerProfile(
      id: id,
      name: id,
      kind: ProfileKind.dev,
      home: home,
      port: 7801,
      storage: ProfileStorage.namespaced,
      origin: '/gone',
    );
  }

  ({ProfileDeleter deleter, ProfileRegistry registry}) build(
    ServerProfile profile, {
    String active = 'default',
    ProfileLifecycle? lifecycle,
  }) {
    final registry = ProfileRegistry(
      makitRoot: '${root.path}/.makit',
      profiles: [
        const ServerProfile(
          id: 'default',
          name: 'Makit',
          kind: ProfileKind.user,
          home: '/anywhere',
          port: 7777,
          storage: ProfileStorage.legacy,
        ),
        profile,
      ],
    );
    return (
      deleter: ProfileDeleter(
        registry: registry,
        lifecycle: lifecycle ?? _StoppedLifecycle(),
        activeProfileId: active,
        homeDir: root.path,
      ),
      registry: registry,
    );
  }

  test('erases a real profile home and drops the registry entry', () async {
    final profile = seedProfile();
    final built = build(profile);
    built.registry.save();

    final result = await built.deleter.delete(profile);

    expect(result.outcome, ProfileDeletionOutcome.deleted);
    expect(Directory(profile.home).existsSync(), isFalse);
    expect(built.registry.byId('dev1'), isNull);
    // Persisted, not just in memory: the profile must not come back on relaunch.
    // (The id survives only as a `deletedIds` tombstone, so a stale window can't
    // resurrect it — assert on the reloaded registry, not a raw substring.)
    final reloaded = ProfileRegistry.load(makitRoot: '${root.path}/.makit');
    expect(reloaded.byId('dev1'), isNull);
    expect(reloaded.byId('default'), isNotNull);
    // The database was the bulk of it, so bytes freed must be non-trivial.
    expect(result.bytesFreed, greaterThan(0));
  });

  test('leaves every sibling profile home untouched', () async {
    final victim = seedProfile(id: 'victim');
    final bystander = seedProfile(id: 'bystander');
    final built = build(victim);

    await built.deleter.delete(victim);

    expect(Directory(victim.home).existsSync(), isFalse);
    expect(Directory(bystander.home).existsSync(), isTrue);
    expect(File('${bystander.home}/server.key').existsSync(), isTrue);
  });

  test(
    'refuses a home outside the makit namespace, and deletes nothing',
    () async {
      // The scenario that matters: a hand-edited or corrupted profiles.json
      // pointing `home` at real user data.
      final documents = Directory('${root.path}/Documents')
        ..createSync(recursive: true);
      File(
        '${documents.path}/thesis.txt',
      ).writeAsStringSync('do not delete me');
      final profile = seedProfile(homeOverride: documents.path);

      final result = await build(profile).deleter.delete(profile);

      expect(result.outcome, ProfileDeletionOutcome.refusedUnsafePath);
      expect(File('${documents.path}/thesis.txt').existsSync(), isTrue);
      expect(documents.existsSync(), isTrue);
    },
  );

  test('refuses the protected profile', () async {
    final built = build(seedProfile());
    final legacy = built.registry.byId('default')!;
    final result = await built.deleter.delete(legacy);
    expect(result.outcome, ProfileDeletionOutcome.refusedProtected);
    expect(built.registry.byId('default'), isNotNull);
  });

  test('refuses the active profile', () async {
    final profile = seedProfile();
    final built = build(profile, active: profile.id);
    final result = await built.deleter.delete(profile);
    expect(result.outcome, ProfileDeletionOutcome.refusedActive);
    expect(Directory(profile.home).existsSync(), isTrue);
  });

  test('unlinks nothing while the daemon refuses to stop', () async {
    // Unlinking under a live daemon holding makit.db-wal is how a delete
    // corrupts a database, so this must abort before touching the disk.
    final profile = seedProfile();
    final built = build(profile, lifecycle: _StuckLifecycle());
    final result = await built.deleter.delete(profile);
    expect(result.outcome, ProfileDeletionOutcome.refusedDaemonRunning);
    expect(Directory(profile.home).existsSync(), isTrue);
    expect(File('${profile.home}/makit.db').existsSync(), isTrue);
    expect(built.registry.byId(profile.id), isNotNull);
  });

  test('diskUsage measures the real tree', () async {
    final profile = seedProfile();
    final bytes = await build(profile).deleter.diskUsage(profile);
    // 9 seeded files, all non-empty.
    expect(bytes, greaterThan(20));
  });

  test('reclaims an orphan whose crashed daemon left a stale socket', () async {
    // The bug this guards: `makit stop` on an already-dead daemon removes the pid
    // file but NOT control.sock (verified against the real binary -- after
    // SIGKILL it prints "not running" and the socket remains). While
    // stopAndConfirm polled the socket FILE, every crashed profile looked alive
    // forever, so ProfileDeleter refused it and the orphans D9 exists to reclaim
    // could never be deleted.
    final profile = seedProfile(id: 'crashed');
    File(profile.controlSocketPath).writeAsStringSync('');
    expect(File(profile.controlSocketPath).existsSync(), isTrue);

    final registry = ProfileRegistry(
      makitRoot: '${root.path}/.makit',
      profiles: [profile],
    );
    final deleter = ProfileDeleter(
      registry: registry,
      // A REAL lifecycle: only the CLI spawn is stubbed, so the socket check and
      // the liveness probe are the production ones.
      lifecycle: ProfileLifecycle(
        resolver: MakitCliResolver(
          candidatePaths: const [],
          exists: (_) => false,
          shellLookup: () async => '/usr/local/bin/makit',
        ),
        run: (exe, args, {environment}) async => ProcessResult(0, 0, '', ''),
        sleep: (_) async {},
      ),
      activeProfileId: 'someone-else',
      homeDir: root.path,
    );

    final result = await deleter.delete(profile);

    expect(
      result.outcome,
      ProfileDeletionOutcome.deleted,
      reason: 'a stale socket must not make an orphan undeletable',
    );
    expect(Directory(profile.home).existsSync(), isFalse);
  });

  test('refuses a rogue entry that aims at the legacy home by path', () async {
    // The protected guard keys on the entry's own `storage` flag, but
    // profiles.json is a plain user-writable file. One hand-added line --
    // {"id":"x","storage":"namespaced","home":"~/.makit"} -- would otherwise be
    // neither protected nor active, and ~/.makit passes a bare prefix check, so
    // the delete would take the APNs key, the TLS keypair, devices.json, ota/,
    // push.json and host.json with it. Rule 2 of `_unsafeHomeReason` refuses it:
    // a home must sit strictly inside ~/.makit/ or ~/.makit-dev/ with at least
    // one further segment, and bare ~/.makit has none.
    final legacyHome = '${root.path}/.makit';
    Directory(legacyHome).createSync(recursive: true);
    File('$legacyHome/AuthKey_ABCD1234.p8').writeAsStringSync('APNS SECRET');
    File('$legacyHome/server.key').writeAsStringSync('TLS SECRET');
    File('$legacyHome/devices.json').writeAsStringSync('[{"id":"phone"}]');

    const legacy = ServerProfile(
      id: 'default',
      name: 'Makit',
      kind: ProfileKind.user,
      home: 'PLACEHOLDER',
      port: 7777,
      storage: ProfileStorage.legacy,
    );
    final rogue = ServerProfile(
      id: 'rogue',
      name: 'rogue',
      kind: ProfileKind.user,
      home: legacyHome,
      port: 7899,
      storage: ProfileStorage.namespaced,
    );
    final registry = ProfileRegistry(
      makitRoot: legacyHome,
      profiles: [
        // Registered somewhere else entirely, so the shared-home rule cannot
        // fire and rule 2 (strictly-inside, one segment below ~/.makit/) is what
        // refuses. An earlier version of this test registered both at the same
        // home, and so stayed green even with rule 2 deleted.
        legacy.copyWith(home: '/somewhere/else/entirely'),
        rogue,
      ],
    );
    final deleter = ProfileDeleter(
      registry: registry,
      lifecycle: _StoppedLifecycle(),
      activeProfileId: 'someone-else',
      homeDir: root.path,
    );

    final result = await deleter.delete(rogue);

    expect(result.outcome, ProfileDeletionOutcome.refusedUnsafePath);
    expect(
      File('$legacyHome/AuthKey_ABCD1234.p8').existsSync(),
      isTrue,
      reason: 'the APNs key was destroyed',
    );
    expect(File('$legacyHome/server.key').existsSync(), isTrue);
    expect(File('$legacyHome/devices.json').existsSync(), isTrue);
  });

  test('refuses a home shared with another registry entry', () async {
    // Two entries pointing at one home: deleting either would erase the other's
    // data behind its back.
    final shared = seedProfile(id: 'twinA');
    final twin = ServerProfile(
      id: 'twinB',
      name: 'twinB',
      kind: ProfileKind.dev,
      home: shared.home,
      port: 7803,
      storage: ProfileStorage.namespaced,
    );
    final registry = ProfileRegistry(
      makitRoot: '${root.path}/.makit',
      profiles: [shared, twin],
    );
    final result = await ProfileDeleter(
      registry: registry,
      lifecycle: _StoppedLifecycle(),
      activeProfileId: 'someone-else',
      homeDir: root.path,
    ).delete(twin);

    expect(result.outcome, ProfileDeletionOutcome.refusedUnsafePath);
    expect(Directory(shared.home).existsSync(), isTrue);
  });

  test('refuses a sibling directory that merely shares the prefix', () async {
    // `startsWith('$home/.makit')` accepted ~/.makitEVIL and ~/.makitother/x.
    for (final rogueHome in [
      '${root.path}/.makitEVIL',
      '${root.path}/.makitother/x',
    ]) {
      Directory(rogueHome).createSync(recursive: true);
      File('$rogueHome/keep.txt').writeAsStringSync('keep');
      final profile = ServerProfile(
        id: 'sneaky',
        name: 'sneaky',
        kind: ProfileKind.dev,
        home: rogueHome,
        port: 7804,
        storage: ProfileStorage.namespaced,
      );
      final result = await ProfileDeleter(
        registry: ProfileRegistry(
          makitRoot: '${root.path}/.makit',
          profiles: [profile],
        ),
        lifecycle: _StoppedLifecycle(),
        activeProfileId: 'someone-else',
        homeDir: root.path,
      ).delete(profile);

      expect(
        result.outcome,
        ProfileDeletionOutcome.refusedUnsafePath,
        reason: 'accepted $rogueHome',
      );
      expect(File('$rogueHome/keep.txt').existsSync(), isTrue);
    }
  });

  test('no spelling of ~/.makit reaches the delete', () async {
    // A string-equality guard is defeated by one trailing slash: `~/.makit/` is
    // not `==` to `~/.makit`, yet it satisfies a `startsWith('~/.makit/')`
    // containment check. Every spelling below reached deleteDirectory in an
    // earlier version and destroyed the APNs key.
    //
    // The legacy profile is deliberately NOT registered here, so the shared-home
    // rule cannot backstop it: each spelling must be refused on its own merits,
    // by canonicalisation (`//`, `/.`, `..`) or by containment requiring a child
    // segment (`~/.makit`, `~/.makit/`).
    final legacyHome = '${root.path}/.makit';
    for (final spelling in [
      legacyHome,
      '$legacyHome/',
      '$legacyHome//',
      '$legacyHome/.',
      '$legacyHome/./',
      '${root.path}//.makit',
      '${root.path}/.makit/../.makit',
      '${root.path}/.makit-dev/../.makit',
    ]) {
      Directory(legacyHome).createSync(recursive: true);
      final secret = File('$legacyHome/AuthKey_ABCD1234.p8')
        ..writeAsStringSync('APNS SECRET');

      final rogue = ServerProfile(
        id: 'rogue',
        name: 'rogue',
        kind: ProfileKind.user,
        home: spelling,
        port: 7899,
        storage: ProfileStorage.namespaced,
      );
      final result = await ProfileDeleter(
        registry: ProfileRegistry(makitRoot: legacyHome, profiles: [rogue]),
        lifecycle: _StoppedLifecycle(),
        activeProfileId: 'someone-else',
        homeDir: root.path,
      ).delete(rogue);

      expect(
        result.outcome,
        ProfileDeletionOutcome.refusedUnsafePath,
        reason: 'accepted the spelling "$spelling"',
      );
      expect(
        secret.existsSync(),
        isTrue,
        reason: 'the APNs key was destroyed via "$spelling"',
      );
    }
  });

  test(
    "refuses the legacy profile's registered home wherever it points",
    () async {
      // Rule 3 of `_unsafeHomeReason` (shared-home refusal): the legacy entry
      // may legitimately live somewhere other than ~/.makit, and a rogue aiming
      // at *that* home is refused because the legacy entry claims it too.
      final legacyHome = '${root.path}/.makit-dev/relocated-legacy';
      Directory(legacyHome).createSync(recursive: true);
      File('$legacyHome/AuthKey_X.p8').writeAsStringSync('APNS');

      final rogue = ServerProfile(
        id: 'rogue2',
        name: 'rogue2',
        kind: ProfileKind.dev,
        home: legacyHome,
        port: 7898,
        storage: ProfileStorage.namespaced,
      );
      final result = await ProfileDeleter(
        registry: ProfileRegistry(
          makitRoot: '${root.path}/.makit',
          profiles: [
            ServerProfile(
              id: 'default',
              name: 'Makit',
              kind: ProfileKind.user,
              home: legacyHome,
              port: 7777,
              storage: ProfileStorage.legacy,
            ),
            rogue,
          ],
        ),
        lifecycle: _StoppedLifecycle(),
        activeProfileId: 'someone-else',
        homeDir: root.path,
      ).delete(rogue);

      expect(result.outcome, ProfileDeletionOutcome.refusedUnsafePath);
      expect(File('$legacyHome/AuthKey_X.p8').existsSync(), isTrue);
    },
  );

  test('refuses a traversal that starts inside the namespace', () async {
    // The one path-escape class with no coverage before: a home that begins
    // legitimately under ~/.makit-dev/ and then climbs out with `..`. Containment
    // alone would accept it, since it does start with the right prefix.
    final documents = Directory('${root.path}/Documents')
      ..createSync(recursive: true);
    File('${documents.path}/thesis.txt').writeAsStringSync('years of work');

    for (final rogueHome in [
      '${root.path}/.makit-dev/../Documents',
      '${root.path}/.makit-dev/x/../../Documents',
      '${root.path}/.makit/profiles/../../Documents',
      '',
      root.path,
      '/',
      'relative/path',
    ]) {
      final profile = ServerProfile(
        id: 'traversal',
        name: 'traversal',
        kind: ProfileKind.dev,
        home: rogueHome,
        port: 7897,
        storage: ProfileStorage.namespaced,
      );
      final result = await ProfileDeleter(
        registry: ProfileRegistry(
          makitRoot: '${root.path}/.makit',
          profiles: [profile],
        ),
        lifecycle: _StoppedLifecycle(),
        activeProfileId: 'someone-else',
        homeDir: root.path,
      ).delete(profile);

      expect(
        result.outcome,
        ProfileDeletionOutcome.refusedUnsafePath,
        reason: 'accepted "$rogueHome"',
      );
      expect(
        File('${documents.path}/thesis.txt').existsSync(),
        isTrue,
        reason: 'user data destroyed via "$rogueHome"',
      );
    }
  });

  test('refuses ~/.makit-dev itself, with no profile segment', () async {
    final bare = '${root.path}/.makit-dev';
    Directory(bare).createSync(recursive: true);
    File('$bare/other-profile-data').writeAsStringSync('x');
    final profile = ServerProfile(
      id: 'bare',
      name: 'bare',
      kind: ProfileKind.dev,
      home: bare,
      port: 7805,
      storage: ProfileStorage.namespaced,
    );
    final result = await ProfileDeleter(
      registry: ProfileRegistry(
        makitRoot: '${root.path}/.makit',
        profiles: [profile],
      ),
      lifecycle: _StoppedLifecycle(),
      activeProfileId: 'someone-else',
      homeDir: root.path,
    ).delete(profile);

    expect(result.outcome, ProfileDeletionOutcome.refusedUnsafePath);
    expect(File('$bare/other-profile-data').existsSync(), isTrue);
  });

  test('a home that is a symlink out of the namespace is not followed', () async {
    // If the recursive delete followed a symlink, a profile home pointing at
    // real data would take it with it.
    final outside = Directory('${root.path}/outside')
      ..createSync(recursive: true);
    File('${outside.path}/keepme.txt').writeAsStringSync('keep');

    final home = '${root.path}/.makit-dev/linked';
    Directory('${root.path}/.makit-dev').createSync(recursive: true);
    Link(home).createSync(outside.path);

    final profile = ServerProfile(
      id: 'linked',
      name: 'linked',
      kind: ProfileKind.dev,
      home: home,
      port: 7802,
      storage: ProfileStorage.namespaced,
    );

    final result = await build(profile).deleter.delete(profile);

    // The symlink resolves out of ~/.makit*, so the guard refuses it outright.
    expect(result.outcome, ProfileDeletionOutcome.refusedUnsafePath);
    // Whatever happened to the link itself, the data it pointed at must survive.
    expect(
      File('${outside.path}/keepme.txt').existsSync(),
      isTrue,
      reason: 'recursive delete followed a symlink out of the namespace',
    );
  });

  test('an ancestor symlink out of the namespace is refused', () async {
    // The Critical case: a *parent* component is a symlink, so a lexically-
    // contained home (`~/.makit/profiles/victim`) resolves to an external dir.
    // Directory.delete follows ancestor symlinks, so the guard must resolve
    // them and re-check containment rather than trust the lexical path.
    final external = Directory('${root.path}/outside/victim')
      ..createSync(recursive: true);
    File('${external.path}/keepme.txt').writeAsStringSync('keep');

    // `~/.makit/profiles` -> `~/outside`, so `.../profiles/victim` is external.
    Directory('${root.path}/.makit').createSync(recursive: true);
    Link('${root.path}/.makit/profiles').createSync('${root.path}/outside');
    final home = '${root.path}/.makit/profiles/victim';

    final profile = ServerProfile(
      id: 'victim',
      name: 'victim',
      kind: ProfileKind.dev,
      home: home,
      port: 7803,
      storage: ProfileStorage.namespaced,
    );

    final result = await build(profile).deleter.delete(profile);

    expect(result.outcome, ProfileDeletionOutcome.refusedUnsafePath);
    expect(
      File('${external.path}/keepme.txt').existsSync(),
      isTrue,
      reason: 'delete followed an ancestor symlink out of the namespace',
    );
  });
}
