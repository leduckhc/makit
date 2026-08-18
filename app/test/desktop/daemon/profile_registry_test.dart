// Unit tests for [ServerProfile] and [ProfileRegistry] (SPEC-profiles P1).
// Co-located with the code under test (per SPEC-desktop-control-app desktop layout).
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/profile_registry.dart';
import 'package:makit/desktop/daemon/server_profile.dart';
import 'package:makit/desktop/daemon/server_profile_paths.dart';

/// An in-memory [FileSystemAdapter] so no test touches a real `profiles.json`.
class _MemoryFs extends FileSystemAdapter {
  _MemoryFs([this.seed]);
  final String? seed;
  final Map<String, String> written = {};

  @override
  String? readOrNull(String path) => written[path] ?? seed;

  @override
  void writeAtomic(String path, String contents) => written[path] = contents;
  @override
  T withLock<T>(String path, T Function() body) => body();
}

/// Every port is free.
Future<bool> _allFree(int port) async => true;

/// Only ports in [free] are available.
PortProbe _onlyFree(Set<int> free) =>
    (port) async => free.contains(port);

const String kHome = '/Users/dev';
const String kRoot = '$kHome/.makit';
const String kDevRoot = '/Users/dev/work/feat-profiles';
const String kDevExe =
    '$kDevRoot/app/build/macos/Build/Products/Release/'
    'makit.app/Contents/MacOS/makit';
const String kInstalledExe = '/Applications/makit.app/Contents/MacOS/makit';

ProfileRegistry _empty({PortProbe? probe}) => ProfileRegistry(
  makitRoot: kRoot,
  profiles: const [],
  probe: probe ?? _allFree,
);

const ServerProfile _legacy = ServerProfile(
  id: 'default',
  name: 'Makit',
  kind: ProfileKind.user,
  home: '$kHome/.makit',
  port: kDefaultServerPort,
  storage: ProfileStorage.legacy,
);

const ServerProfile _dev = ServerProfile(
  id: 'a1b2c3d4',
  name: 'feat-profiles',
  kind: ProfileKind.dev,
  home: '$kHome/.makit-dev/a1b2c3d4',
  port: 7813,
  storage: ProfileStorage.namespaced,
  origin: kDevRoot,
);

void main() {
  group('ServerProfile', () {
    test('legacy storage keeps the shipped key layout', () {
      // The whole point of D2: renameable, but its storage never moves.
      expect(_legacy.prefsKeyPrefix, '');
      expect(_legacy.secureStoreNamespace, isNull);
      expect(_legacy.isProtected, isTrue);
      expect(_legacy.controlSocketPath, '$kHome/.makit/control.sock');
      expect(_legacy.environment, {'MAKIT_HOME': '$kHome/.makit'});
    });

    test('namespaced storage prefixes keys and secrets by id', () {
      expect(_dev.prefsKeyPrefix, 'a1b2c3d4.');
      expect(_dev.secureStoreNamespace, 'a1b2c3d4');
      expect(_dev.isProtected, isFalse);
    });

    test(
      'the effective prefs key matches the pre-SPEC-profiles layout exactly',
      () {
        // D11's no-migration claim, asserted rather than argued in prose:
        // shared_preferences composes '$_prefix$key', so with the default
        // 'flutter.' prefix our key must reproduce the old
        // setPrefix('flutter.<id>.') + 'desktop_server_port'.
        expect(
          'flutter.${_dev.prefsKeyPrefix}desktop_server_port',
          'flutter.a1b2c3d4.desktop_server_port',
        );
        expect(
          'flutter.${_legacy.prefsKeyPrefix}desktop_server_port',
          'flutter.desktop_server_port',
        );
      },
    );

    test('every profile has a titled window, including the legacy one', () {
      expect(_legacy.windowTitle, 'Makit — Makit');
      expect(_dev.windowTitle, 'Makit — feat-profiles');
    });

    // The invariant that made the D11 switch-over a no-op rather than a
    // migration: the effective stored key stays byte-for-byte what the old
    // `SharedPreferences.setPrefix` mechanism produced (`flutter.<id>.<key>`,
    // or `flutter.<key>` for the legacy profile).
    test(
      'prefsKeyPrefix yields the historical setPrefix key for every profile',
      () {
        for (final key in ['desktop_server_port', 'groups.v2', 'a.b.c']) {
          // Legacy: unprefixed, so the effective key is the shipped `flutter.<key>`.
          expect('flutter.${_legacy.prefsKeyPrefix}$key', 'flutter.$key');
          // Namespaced: `flutter.<id>.<key>`, identical to setPrefix('flutter.<id>.').
          expect(
            'flutter.${_dev.prefsKeyPrefix}$key',
            'flutter.${_dev.id}.$key',
            reason: 'key layout diverged for ${_dev.id}/$key',
          );
        }
      },
    );

    test('json round-trips, and omits origin when absent', () {
      expect(ServerProfile.fromJson(_dev.toJson()), _dev);
      expect(ServerProfile.fromJson(_legacy.toJson()), _legacy);
      expect(_legacy.toJson().keys.contains('origin'), isFalse);
      expect(_dev.toJson()['origin'], kDevRoot);
    });

    test('fromJson drops an entry with no identity', () {
      expect(ServerProfile.fromJson({'name': 'x', 'home': '/h'}), isNull);
      expect(ServerProfile.fromJson({'id': 'x'}), isNull);
      expect(ServerProfile.fromJson({'id': '', 'home': '/h'}), isNull);
    });

    test(
      'fromJson rejects a relative home (must be an absolute MAKIT_HOME)',
      () {
        // A relative home resolves against the spawned CLI's cwd, putting the
        // daemon and its data in the wrong place.
        expect(ServerProfile.fromJson({'id': 'x', 'home': '.makit'}), isNull);
        expect(
          ServerProfile.fromJson({'id': 'x', 'home': 'relative/path'}),
          isNull,
        );
        expect(ServerProfile.fromJson({'id': 'x', 'home': ''}), isNull);
        // An absolute home is accepted.
        expect(
          ServerProfile.fromJson({'id': 'x', 'home': '/abs/home'}),
          isNotNull,
        );
      },
    );

    test('fromJson repairs a missing name/port/storage', () {
      final p = ServerProfile.fromJson({'id': 'x', 'home': '/h'})!;
      expect(p.name, 'x');
      expect(p.port, kFallbackServerPort);
      expect(p.storage, ProfileStorage.namespaced);
      expect(p.kind, ProfileKind.user);
    });

    test('fromJson falls back for an out-of-range port', () {
      // A hand-edited `{"port": 70000}` cannot be bound; it must fall back the
      // same way a missing/non-positive port does, not wedge the profile.
      final tooHigh = ServerProfile.fromJson({
        'id': 'x',
        'home': '/h',
        'port': 70000,
      })!;
      expect(tooHigh.port, kFallbackServerPort);
      final zero = ServerProfile.fromJson({
        'id': 'x',
        'home': '/h',
        'port': 0,
      })!;
      expect(zero.port, kFallbackServerPort);
      // A valid port is kept.
      final ok = ServerProfile.fromJson({
        'id': 'x',
        'home': '/h',
        'port': 8123,
      })!;
      expect(ok.port, 8123);
    });

    test('copyWith cannot change frozen identity fields', () {
      final renamed = _dev.copyWith(name: 'other', port: 7999);
      expect(renamed.id, _dev.id);
      expect(renamed.kind, _dev.kind);
      expect(renamed.storage, _dev.storage);
      expect(renamed.name, 'other');
      expect(renamed.port, 7999);
    });
  });

  group('ProfileRegistry.resolveFor', () {
    test('installed app bootstraps the legacy profile once', () async {
      final reg = _empty();
      final first = await reg.resolveFor(
        executablePath: kInstalledExe,
        home: kHome,
      );
      expect(first.created, isTrue);
      expect(first.profile.storage, ProfileStorage.legacy);
      expect(first.profile.home, '$kHome/.makit');
      expect(first.profile.port, kDefaultServerPort);

      final second = await reg.resolveFor(
        executablePath: kInstalledExe,
        home: kHome,
      );
      expect(second.created, isFalse);
      expect(second.profile, first.profile);
      expect(reg.profiles.length, 1);
    });

    test('a dev build gets its own namespaced profile', () async {
      final reg = _empty();
      final r = await reg.resolveFor(executablePath: kDevExe, home: kHome);
      expect(r.created, isTrue);
      expect(r.profile.kind, ProfileKind.dev);
      expect(r.profile.origin, kDevRoot);
      expect(r.profile.name, 'feat-profiles');
      expect(r.profile.home, '$kHome/.makit-dev/${r.profile.id}');
      expect(r.profile.storage, ProfileStorage.namespaced);
    });

    // The orphaning bug this class exists to kill: a *rebuilt* app at the same
    // origin must re-bind, not fork.
    test('a rebuilt dev app re-binds to its existing profile', () async {
      final reg = _empty();
      final first = await reg.resolveFor(executablePath: kDevExe, home: kHome);
      final again = await reg.resolveFor(
        executablePath:
            '$kDevRoot/app/build/macos/Build/Products/Debug/'
            'makit.app/Contents/MacOS/makit',
        home: kHome,
      );
      expect(again.created, isFalse);
      expect(again.profile.id, first.profile.id);
      expect(reg.profiles.length, 1);
    });

    test('two different worktrees get two different profiles', () async {
      final reg = _empty();
      final a = await reg.resolveFor(executablePath: kDevExe, home: kHome);
      final b = await reg.resolveFor(
        executablePath:
            '/Users/dev/work/other/app/build/macos/Build/Products/'
            'Release/makit.app/Contents/MacOS/makit',
        home: kHome,
      );
      expect(a.profile.id, isNot(b.profile.id));
      expect(a.profile.port, isNot(b.profile.port));
      expect(reg.profiles.length, 2);
    });
  });

  group('ProfileRegistry.allocatePort', () {
    test('takes the guess when it is free', () async {
      expect(await _empty().allocatePort(startingGuess: 7813), 7813);
    });

    // The collision bug: two worktrees whose hashes agree mod 100 used to get
    // the same port, and the second daemon simply died.
    test('skips a port already claimed by another profile', () async {
      final reg = ProfileRegistry(
        makitRoot: kRoot,
        probe: _allFree,
        profiles: const [
          ServerProfile(
            id: 'a',
            name: 'a',
            kind: ProfileKind.dev,
            home: '/h/a',
            port: 7813,
            storage: ProfileStorage.namespaced,
          ),
        ],
      );
      expect(await reg.allocatePort(startingGuess: 7813), 7814);
    });

    test('skips a port a foreign process holds', () async {
      final reg = _empty(probe: _onlyFree({7815}));
      expect(await reg.allocatePort(startingGuess: 7813), 7815);
    });

    test('wraps around the dev range', () async {
      final reg = _empty(probe: _onlyFree({7801}));
      expect(await reg.allocatePort(startingGuess: 7899), 7801);
    });

    test('falls back to the guess when the whole range is busy', () async {
      // Better to hand back the guess and let the daemon report EADDRINUSE than
      // to throw during launch.
      final reg = _empty(probe: _onlyFree(const {}));
      expect(await reg.allocatePort(startingGuess: 7842), 7842);
    });

    test('never returns a port below the dev range', () async {
      expect(
        await _empty().allocatePort(startingGuess: 80),
        greaterThanOrEqualTo(kDevPortRangeStart),
      );
    });
  });

  group('ProfileRegistry persistence', () {
    test('save writes a profiles.json the loader accepts', () {
      final fs = _MemoryFs();
      final reg = ProfileRegistry(
        makitRoot: kRoot,
        probe: _allFree,
        fs: fs,
        profiles: const [
          ServerProfile(
            id: 'default',
            name: 'Work',
            kind: ProfileKind.user,
            home: '$kHome/.makit',
            port: 7777,
            storage: ProfileStorage.legacy,
          ),
        ],
      );
      reg.save();
      final raw = fs.written['$kRoot/profiles.json']!;
      expect(jsonDecode(raw), isA<Map<String, Object?>>());

      final again = ProfileRegistry.load(
        makitRoot: kRoot,
        fs: _MemoryFs(raw),
        probe: _allFree,
      );
      expect(again.profiles.single.name, 'Work');
      expect(again.profiles.single.storage, ProfileStorage.legacy);
    });

    test('a corrupt file yields an empty registry, not a crash', () {
      final reg = ProfileRegistry.load(
        makitRoot: kRoot,
        fs: _MemoryFs('{not json'),
        probe: _allFree,
      );
      expect(reg.profiles, isEmpty);
    });

    test('a missing file yields an empty registry', () {
      final reg = ProfileRegistry.load(
        makitRoot: kRoot,
        fs: _MemoryFs(),
        probe: _allFree,
      );
      expect(reg.profiles, isEmpty);
    });

    test('a duplicate id is dropped, first-seen wins', () {
      final raw = jsonEncode({
        'profiles': [
          {'id': 'x', 'home': '/a', 'name': 'first'},
          {'id': 'x', 'home': '/b', 'name': 'second'},
        ],
      });
      final reg = ProfileRegistry.load(
        makitRoot: kRoot,
        fs: _MemoryFs(raw),
        probe: _allFree,
      );
      expect(reg.profiles.single.name, 'first');
    });

    test('a bare JSON array is accepted too', () {
      final raw = jsonEncode([
        {'id': 'x', 'home': '/a', 'name': 'first'},
      ]);
      final reg = ProfileRegistry.load(
        makitRoot: kRoot,
        fs: _MemoryFs(raw),
        probe: _allFree,
      );
      expect(reg.profiles.single.id, 'x');
    });

    // SPEC-profiles D1 runs several instances at once, each with its own in-memory
    // list. A plain whole-file write loses whatever another window added: a
    // `user` profile has no `origin`, so resolveFor could never re-bind it and
    // its home/pairings/prefs would be orphaned -- the exact failure this class
    // exists to prevent.
    test('save merges in a profile another instance added', () async {
      final fs = _MemoryFs();
      final a = ProfileRegistry(
        makitRoot: kRoot,
        probe: _allFree,
        fs: fs,
        profiles: const [_legacy],
      );
      final b = ProfileRegistry(
        makitRoot: kRoot,
        probe: _allFree,
        fs: fs,
        profiles: const [_legacy],
      );

      // Window A creates Personal and saves.
      await a.createUserProfile(name: 'Personal');
      a.save();

      // Window B, which never saw Personal, now saves its own edit.
      b.rename('default', 'Work');
      b.save();

      final onDisk = ProfileRegistry.load(
        makitRoot: kRoot,
        fs: _MemoryFs(fs.written['$kRoot/profiles.json']),
        probe: _allFree,
      );
      expect(
        onDisk.byId('personal'),
        isNotNull,
        reason: 'window B clobbered a profile window A created',
      );
      expect(onDisk.byId('default')!.name, 'Work');
    });

    test('a merge cannot resurrect a profile this instance deleted', () {
      final fs = _MemoryFs();
      final reg = ProfileRegistry(
        makitRoot: kRoot,
        probe: _allFree,
        fs: fs,
        profiles: const [_legacy, _dev],
      );
      reg.save();
      // Someone else's stale copy still lists _dev; ours deletes it.
      expect(reg.remove(_dev.id), isTrue);
      reg.save();

      final onDisk = ProfileRegistry.load(
        makitRoot: kRoot,
        fs: _MemoryFs(fs.written['$kRoot/profiles.json']),
        probe: _allFree,
      );
      expect(onDisk.byId(_dev.id), isNull);
    });

    test('an unmodified profile does not revert another window\'s rename', () {
      // Window A renames X and saves; window B (loaded before) saves an
      // unrelated change. B must not write its stale copy of X back over A's
      // rename (SPEC-profiles D1 lost-update).
      final fs = _MemoryFs();
      final a = ProfileRegistry(
        makitRoot: kRoot,
        probe: _allFree,
        fs: fs,
        profiles: const [_legacy, _dev],
      );
      final b = ProfileRegistry(
        makitRoot: kRoot,
        probe: _allFree,
        fs: fs,
        profiles: const [_legacy, _dev],
      );

      a.rename(_dev.id, 'Renamed');
      a.save();

      // B never touched _dev, but still holds it; its unrelated save must keep
      // A's rename rather than clobber it.
      b.rename('default', 'Work');
      b.save();

      final onDisk = ProfileRegistry.load(
        makitRoot: kRoot,
        fs: _MemoryFs(fs.written['$kRoot/profiles.json']),
        probe: _allFree,
      );
      expect(onDisk.byId(_dev.id)!.name, 'Renamed');
      expect(onDisk.byId('default')!.name, 'Work');
    });

    test('a deletion by another window is honoured, not resurrected', () {
      // A deletes X (persisting a tombstone) after B loaded X. B's later save
      // must not bring X back — its on-disk stores are already gone.
      final fs = _MemoryFs();
      final a = ProfileRegistry(
        makitRoot: kRoot,
        probe: _allFree,
        fs: fs,
        profiles: const [_legacy, _dev],
      );
      final b = ProfileRegistry(
        makitRoot: kRoot,
        probe: _allFree,
        fs: fs,
        profiles: const [_legacy, _dev],
      );
      a.save();

      a.remove(_dev.id);
      a.save(); // writes deletedIds: [_dev.id]

      // B still lists _dev and saves an unrelated edit.
      b.rename('default', 'Work');
      b.save();

      final onDisk = ProfileRegistry.load(
        makitRoot: kRoot,
        fs: _MemoryFs(fs.written['$kRoot/profiles.json']),
        probe: _allFree,
      );
      expect(
        onDisk.byId(_dev.id),
        isNull,
        reason: 'a stale window resurrected a deleted profile',
      );
    });

    test(
      'a profile created after a delete is not dropped by the tombstone',
      () async {
        // _uniqueId must avoid tombstoned ids: reusing a just-deleted slug would
        // make save() drop the new profile (it honours the tombstone) and orphan
        // its home.
        final fs = _MemoryFs();
        final reg = ProfileRegistry(
          makitRoot: kRoot,
          probe: _allFree,
          fs: fs,
          profiles: const [_legacy],
        );
        final first = await reg.createUserProfile(name: 'Personal');
        reg.save();
        expect(reg.remove(first.id), isTrue); // tombstones 'personal'
        reg.save();

        final second = await reg.createUserProfile(name: 'Personal');
        expect(
          second.id,
          isNot(first.id),
          reason: 'must not mint a tombstoned id',
        );
        reg.save();

        final onDisk = ProfileRegistry.load(
          makitRoot: kRoot,
          fs: _MemoryFs(fs.written['$kRoot/profiles.json']),
          probe: _allFree,
        );
        expect(
          onDisk.byId(second.id),
          isNotNull,
          reason:
              'the new profile must persist, not be swallowed by the tombstone',
        );
      },
    );

    test('a duplicate port on load is reassigned to a free one', () {
      // A hand-edited (or fallback-7777) namespaced profile that collides with
      // the legacy port must be moved off it, or its daemon fails to bind.
      final raw = jsonEncode({
        'profiles': [
          {
            'id': 'default',
            'home': '/h/.makit',
            'name': 'Work',
            'storage': 'legacy',
            'port': 7777,
          },
          {
            'id': 'clash',
            'home': '/h/.makit-dev/clash',
            'name': 'Clash',
            'storage': 'namespaced',
            'port': 7777,
          },
        ],
      });
      final reg = ProfileRegistry.load(
        makitRoot: kRoot,
        fs: _MemoryFs(raw),
        probe: _allFree,
      );
      expect(reg.byId('default')!.port, 7777, reason: 'legacy keeps its port');
      expect(reg.byId('clash')!.port, isNot(7777));
    });

    test('a second legacy profile is dropped on load (D2)', () {
      final raw = jsonEncode({
        'profiles': [
          {'id': 'default', 'home': '/h/.makit', 'storage': 'legacy'},
          {'id': 'intruder', 'home': '/h/.makit2', 'storage': 'legacy'},
        ],
      });
      final reg = ProfileRegistry.load(
        makitRoot: kRoot,
        fs: _MemoryFs(raw),
        probe: _allFree,
      );
      expect(reg.byId('default'), isNotNull);
      expect(
        reg.byId('intruder'),
        isNull,
        reason: 'two legacy profiles would share creds and prefs',
      );
    });

    test(
      'two instances that allocate the same port are reconciled on save',
      () async {
        // Each instance probes with only its own list visible, so both can pick
        // the same free port. save() must detect the post-merge collision and
        // move one, or a daemon fails with EADDRINUSE next launch.
        final fs = _MemoryFs();
        final a = ProfileRegistry(
          makitRoot: kRoot,
          probe: _allFree,
          fs: fs,
          profiles: const [_legacy],
        );
        final b = ProfileRegistry(
          makitRoot: kRoot,
          probe: _allFree,
          fs: fs,
          profiles: const [_legacy],
        );

        final pa = await a.createUserProfile(name: 'Alpha');
        final pb = await b.createUserProfile(name: 'Beta');
        expect(pa.port, pb.port, reason: 'the scenario needs them to collide');
        final contestedPort = pa.port;

        a.save(); // Alpha is persisted first, on the contested port.
        b.save(); // Beta collides; the already-persisted Alpha must keep it.

        final onDisk = ProfileRegistry.load(
          makitRoot: kRoot,
          fs: _MemoryFs(fs.written['$kRoot/profiles.json']),
          probe: _allFree,
        );
        final ports = onDisk.profiles.map((p) => p.port).toList();
        expect(
          ports.toSet().length,
          ports.length,
          reason: 'no two profiles may share a port after the merge',
        );
        // The on-disk (possibly-running) profile keeps its port; the newcomer
        // yields.
        expect(onDisk.byId(pa.id)!.port, contestedPort);
        expect(onDisk.byId(pb.id)!.port, isNot(contestedPort));
      },
    );
    // The id is interpolated into a filesystem path (the secure-store namespace
    // file) and into preference keys, and profiles.json is user-writable.
    test('an id that could escape its directory is dropped', () {
      for (final bad in [
        '../../../../tmp/x',
        'a/b',
        'a.b',
        '..',
        '.',
        'UPPER',
        '-leading',
        '',
        'has space',
      ]) {
        expect(
          ServerProfile.fromJson({'id': bad, 'home': '/h'}),
          isNull,
          reason: 'accepted unsafe id "$bad"',
        );
      }
      // ...and the ids the registry itself mints still parse.
      for (final good in ['default', 'a1b2c3d4', 'my-personal', 'personal-2']) {
        expect(
          ServerProfile.fromJson({'id': good, 'home': '/h'}),
          isNotNull,
          reason: 'rejected a legitimate id "$good"',
        );
      }
    });
  });

  group('ProfileRegistry mutations', () {
    Future<ProfileRegistry> seeded() async {
      final reg = _empty();
      await reg.resolveFor(executablePath: kInstalledExe, home: kHome);
      await reg.resolveFor(executablePath: kDevExe, home: kHome);
      return reg;
    }

    test('createUserProfile slugs the name into id and home', () async {
      final reg = await seeded();
      final p = await reg.createUserProfile(name: 'My Personal!');
      expect(p.id, 'my-personal');
      expect(p.home, '$kRoot/profiles/my-personal');
      expect(p.kind, ProfileKind.user);
      expect(p.storage, ProfileStorage.namespaced);
      expect(p.isProtected, isFalse);
    });

    test('a duplicate name gets a distinct id, not a shared home', () async {
      final reg = await seeded();
      final a = await reg.createUserProfile(name: 'Personal');
      final b = await reg.createUserProfile(name: 'Personal');
      expect(a.id, 'personal');
      expect(b.id, 'personal-2');
      expect(a.home, isNot(b.home));
    });

    test('a blank name is refused', () async {
      final reg = await seeded();
      expect(
        () => reg.createUserProfile(name: '   '),
        throwsA(isA<ArgumentError>()),
      );
    });

    // A mint/validate mismatch is data loss, not a cosmetic wart: an id the
    // registry creates but fromJson later rejects means the profile silently
    // vanishes on the next launch, taking its home and pairings with it.
    test('a very long name still mints an id that survives a reload', () async {
      final reg = await seeded();
      final created = await reg.createUserProfile(name: 'Q' * 200);

      expect(isSafeProfileId(created.id), isTrue);
      expect(created.id.length, lessThanOrEqualTo(64));
      expect(created.id, isNot(endsWith('-')));
      expect(reg.allIdsRoundTrip, isTrue);
      // And it really does come back.
      expect(ServerProfile.fromJson(created.toJson()), created);
    });

    test(
      'two long names with the same prefix still get distinct ids',
      () async {
        final reg = await seeded();
        final a = await reg.createUserProfile(name: 'Z' * 100);
        final b = await reg.createUserProfile(name: 'Z' * 100);
        expect(a.id, isNot(b.id));
        expect(isSafeProfileId(a.id), isTrue);
        expect(isSafeProfileId(b.id), isTrue);
        expect(a.home, isNot(b.home));
      },
    );

    test('the legacy profile can be renamed but never removed', () async {
      final reg = await seeded();
      expect(reg.rename('default', 'Work'), isTrue);
      expect(reg.byId('default')!.name, 'Work');
      // D2/D8: it holds AuthKey_*.p8, ota/ and push.json.
      expect(reg.remove('default'), isFalse);
      expect(reg.byId('default'), isNotNull);
    });

    test('a dev profile can be removed', () async {
      final reg = await seeded();
      final dev = reg.profiles.firstWhere((p) => p.kind == ProfileKind.dev);
      expect(reg.remove(dev.id), isTrue);
      expect(reg.byId(dev.id), isNull);
    });

    test('rename refuses a blank name and an unknown id', () async {
      final reg = await seeded();
      expect(reg.rename('default', '  '), isFalse);
      expect(reg.rename('nope', 'x'), isFalse);
    });

    test('setPort persists a retried port and validates the range', () async {
      final reg = await seeded();
      expect(reg.setPort('default', 7900), isTrue);
      expect(reg.byId('default')!.port, 7900);
      expect(reg.setPort('default', 0), isFalse);
      expect(reg.setPort('default', 70000), isFalse);
    });

    test('setOrigin re-points a moved dev build', () async {
      final reg = await seeded();
      final dev = reg.profiles.firstWhere((p) => p.kind == ProfileKind.dev);
      expect(reg.setOrigin(dev.id, '/moved/here'), isTrue);
      expect(reg.byId(dev.id)!.origin, '/moved/here');
    });
  });

  group('last active profile', () {
    Future<ProfileRegistry> seeded(_MemoryFs fs) async {
      final reg = ProfileRegistry(
        makitRoot: kRoot,
        probe: _allFree,
        fs: fs,
        profiles: const [_legacy],
      );
      await reg.createUserProfile(name: 'Personal');
      return reg;
    }

    test('round-trips through profiles.json', () async {
      final fs = _MemoryFs();
      final reg = await seeded(fs);
      expect(reg.setLastActive('personal'), isTrue);
      reg.save();

      final again = ProfileRegistry.load(
        makitRoot: kRoot,
        fs: _MemoryFs(fs.written['$kRoot/profiles.json']),
        probe: _allFree,
      );
      expect(again.lastActiveId, 'personal');
    });

    test(
      'an unknown id is refused, so a stale value is never written',
      () async {
        final reg = await seeded(_MemoryFs());
        expect(reg.setLastActive('nope'), isFalse);
        expect(reg.lastActiveId, isNull);
      },
    );

    test('the installed app reopens the last profile chosen', () async {
      final reg = await seeded(_MemoryFs());
      reg.setLastActive('personal');
      expect(reg.preferredFor(_legacy).id, 'personal');
    });

    // A dev build exists to isolate its worktree. Reopening Work would make
    // building that worktree look like it did nothing.
    test(
      'a dev build always opens its own profile, ignoring last active',
      () async {
        final reg = await seeded(_MemoryFs());
        reg.setLastActive('personal');
        expect(reg.preferredFor(_dev).id, _dev.id);
      },
    );

    test(
      'a last-active profile that has since been deleted falls back',
      () async {
        final reg = await seeded(_MemoryFs());
        reg.setLastActive('personal');
        reg.remove('personal');
        expect(reg.preferredFor(_legacy).id, _legacy.id);
      },
    );

    test('absent lastActive leaves the file free of the key', () async {
      final fs = _MemoryFs();
      (await seeded(fs)).save();
      expect(fs.written['$kRoot/profiles.json'], isNot(contains('lastActive')));
    });

    test(
      'save() preserves a newer on-disk lastActive it did not set itself',
      () async {
        // Shared "disk": both registries read and write the same map.
        final fs = _MemoryFs();
        final regA = ProfileRegistry(
          makitRoot: kRoot,
          probe: _allFree,
          fs: fs,
          profiles: const [_legacy],
        );
        await regA.createUserProfile(name: 'Personal');
        regA.save(); // disk: [legacy, personal], no lastActive

        // Another window loads the same disk and switches the active profile.
        final regB = ProfileRegistry.load(
          makitRoot: kRoot,
          fs: fs,
          probe: _allFree,
        );
        expect(regB.setLastActive('personal'), isTrue);
        regB.save(); // disk lastActive = personal

        // regA (loaded before that, never touched lastActive) saves an
        // unrelated rename. It must NOT clobber the newer selection.
        expect(regA.rename('personal', 'Personal 2'), isTrue);
        regA.save();

        final reloaded = ProfileRegistry.load(
          makitRoot: kRoot,
          fs: fs,
          probe: _allFree,
        );
        expect(reloaded.lastActiveId, 'personal');
      },
    );
  });

  group('ProfileRegistry.staleProfiles', () {
    test('lists dev profiles whose origin is gone, and only those', () async {
      final reg = _empty();
      await reg.resolveFor(executablePath: kInstalledExe, home: kHome);
      await reg.resolveFor(executablePath: kDevExe, home: kHome);
      await reg.createUserProfile(name: 'Personal');

      final stale = reg.staleProfiles(dirExists: (_) => false);
      expect(stale.length, 1);
      expect(stale.single.origin, kDevRoot);

      expect(reg.staleProfiles(dirExists: (_) => true), isEmpty);
    });
  });

  group('probePortIsFree', () {
    test('reports a really-held port as busy and a free one as free', () async {
      final held = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => held.close());
      expect(await probePortIsFree(held.port), isFalse);

      final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final freePort = free.port;
      await free.close();
      expect(await probePortIsFree(freePort), isTrue);
    });
  });
}
