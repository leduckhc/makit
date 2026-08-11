// Unit tests for [ProfileDeleter] (SPEC-50 P3, D8).
// Co-located with the code under test (per SPEC-03 desktop layout).
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';
import 'package:makit/desktop/daemon/profile_deleter.dart';
import 'package:makit/desktop/daemon/profile_lifecycle.dart';
import 'package:makit/desktop/daemon/profile_registry.dart';
import 'package:makit/desktop/daemon/server_profile.dart';

const String _homeDir = '/Users/tester';

/// In-memory [ProfileFileSystem]: `paths` maps an existing path to its byte
/// size; every delete is recorded so tests can assert what was unlinked.
class _FakeFs implements ProfileFileSystem {
  _FakeFs(this.paths, {this.files = const {}});
  final Map<String, int> paths;

  /// Seeded paths that are regular FILES rather than directories.
  final Set<String> files;
  final List<String> deleted = [];

  @override
  bool exists(String path) => paths.containsKey(path);

  @override
  bool isDirectory(String path) =>
      paths.containsKey(path) && !files.contains(path);

  @override
  Future<int> sizeOf(String path) async => paths[path] ?? 0;

  @override
  Future<void> deleteDirectory(String path) async {
    deleted.add(path);
    paths.remove(path);
  }

  @override
  Future<void> deleteFile(String path) async {
    deleted.add(path);
    paths.remove(path);
  }

  @override
  String? resolveRealPath(String path) => null;
}

/// A [ProfileFileSystem] that throws a [FileSystemException] on a chosen store
/// operation, to prove [ProfileDeleter.delete] stays best-effort.
class _ThrowingFs implements ProfileFileSystem {
  _ThrowingFs(this.paths, {this.throwOnDeleteDirectory = false});
  final Map<String, int> paths;
  final bool throwOnDeleteDirectory;

  @override
  bool exists(String path) => paths.containsKey(path);

  @override
  bool isDirectory(String path) => paths.containsKey(path);

  @override
  Future<int> sizeOf(String path) async => paths[path] ?? 0;

  @override
  Future<void> deleteDirectory(String path) async {
    if (throwOnDeleteDirectory) {
      throw const FileSystemException('permission denied');
    }
    paths.remove(path);
  }

  @override
  Future<void> deleteFile(String path) async => paths.remove(path);

  @override
  String? resolveRealPath(String path) => null;
}

MakitCliResolver _resolver() => MakitCliResolver(
  candidatePaths: const [],
  exists: (_) => false,
  shellLookup: () async => '/usr/local/bin/makit',
);

/// A lifecycle whose daemon is [running] or not; `stopAndConfirm` returns
/// `!running` without spawning anything real.
///
/// Both the socket check and the liveness probe are driven by [running], because
/// "still running" now means *still answering* — a socket file left behind by a
/// SIGKILLed daemon must NOT count as running, or an orphaned profile could never
/// be deleted (see `stopAndConfirm`).
ProfileLifecycle _lifecycle({required bool running}) => ProfileLifecycle(
  resolver: _resolver(),
  run: (exe, args, {environment}) async => ProcessResult(0, 0, '', ''),
  socketExists: (_) => running,
  statusProbe: (_) async => running,
  sleep: (_) async {},
);

ServerProfile _profile({
  String id = 'work',
  String home = '$_homeDir/.makit/profiles/work',
  ProfileStorage storage = ProfileStorage.namespaced,
}) => ServerProfile(
  id: id,
  name: 'Work',
  kind: ProfileKind.user,
  home: home,
  port: 7801,
  storage: storage,
);

String _securePath(String namespace) =>
    '$_homeDir/Library/Application Support/dev.getmakit.app/'
    'secure_store.$namespace.json';

late Directory _tempRoot;

ProfileRegistry _registry(List<ServerProfile> profiles) =>
    ProfileRegistry(makitRoot: _tempRoot.path, profiles: profiles);

ProfileDeleter _deleter({
  required ProfileRegistry registry,
  required ProfileLifecycle lifecycle,
  required _FakeFs fs,
  String activeProfileId = 'other',
  Future<int> Function(ServerProfile)? purgePrefs,
}) => ProfileDeleter(
  registry: registry,
  lifecycle: lifecycle,
  activeProfileId: activeProfileId,
  homeDir: _homeDir,
  fs: fs,
  isMacOS: true,
  purgePrefs: purgePrefs,
);

void main() {
  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('profile_deleter_test');
  });
  tearDown(() {
    if (_tempRoot.existsSync()) _tempRoot.deleteSync(recursive: true);
  });

  group('ProfileDeleter guards', () {
    test('refuses the protected legacy profile', () async {
      final profile = _profile(id: 'default', storage: ProfileStorage.legacy);
      final fs = _FakeFs({profile.home: 100});
      final result = await _deleter(
        registry: _registry([profile]),
        lifecycle: _lifecycle(running: false),
        fs: fs,
      ).delete(profile);

      expect(result.outcome, ProfileDeletionOutcome.refusedProtected);
      expect(fs.deleted, isEmpty);
    });

    test('refuses the currently active profile', () async {
      final profile = _profile();
      final fs = _FakeFs({profile.home: 100});
      final result = await _deleter(
        registry: _registry([profile]),
        lifecycle: _lifecycle(running: false),
        fs: fs,
        activeProfileId: 'work',
      ).delete(profile);

      expect(result.outcome, ProfileDeletionOutcome.refusedActive);
      expect(fs.deleted, isEmpty);
    });

    test('refuses a home outside ~/.makit* — the disk-safety guard', () async {
      final profile = _profile(id: 'corrupt', home: '/');
      final fs = _FakeFs({'/': 999999});
      final result = await _deleter(
        registry: _registry([profile]),
        lifecycle: _lifecycle(running: false),
        fs: fs,
      ).delete(profile);

      expect(result.outcome, ProfileDeletionOutcome.refusedUnsafePath);
      expect(fs.deleted, isEmpty);
    });

    test('refuses a home outside ~/.makit* even under the home dir', () async {
      final profile = _profile(id: 'evil', home: '$_homeDir/Documents');
      final fs = _FakeFs({'$_homeDir/Documents': 100});
      final result = await _deleter(
        registry: _registry([profile]),
        lifecycle: _lifecycle(running: false),
        fs: fs,
      ).delete(profile);

      expect(result.outcome, ProfileDeletionOutcome.refusedUnsafePath);
      expect(fs.deleted, isEmpty);
    });

    test(
      'refuses when the daemon will not stop — never unlinks live',
      () async {
        final profile = _profile();
        final fs = _FakeFs({profile.home: 100});
        final result = await _deleter(
          registry: _registry([profile]),
          lifecycle: _lifecycle(running: true),
          fs: fs,
        ).delete(profile);

        expect(result.outcome, ProfileDeletionOutcome.refusedDaemonRunning);
        expect(fs.deleted, isEmpty);
      },
    );
  });

  group('ProfileDeleter.delete happy path', () {
    test(
      'erases home + secure store + registry entry, reports bytes',
      () async {
        final profile = _profile();
        final securePath = _securePath('work');
        final fs = _FakeFs({profile.home: 4096, securePath: 32});
        final registry = _registry([profile]);
        final deleter = _deleter(
          registry: registry,
          lifecycle: _lifecycle(running: false),
          fs: fs,
        );

        final result = await deleter.delete(profile);

        expect(result.outcome, ProfileDeletionOutcome.deleted);
        expect(result.bytesFreed, 4096 + 32);
        expect(fs.deleted, containsAll([profile.home, securePath]));
        expect(registry.byId('work'), isNull);
        expect(result.removed, contains('registry entry work'));
      },
    );

    test('purges the profile\'s preference keys (store 3)', () async {
      // Prefs are reachable for a non-active profile now that scoping is by key
      // prefix, so the deleter must actually purge them rather than always
      // reporting the store skipped.
      final profile = _profile();
      final fs = _FakeFs({profile.home: 10});
      final purged = <String>[];
      final result = await _deleter(
        registry: _registry([profile]),
        lifecycle: _lifecycle(running: false),
        fs: fs,
        purgePrefs: (p) async {
          purged.add(p.id);
          return 4;
        },
      ).delete(profile);

      expect(purged, ['work']);
      expect(
        result.removed.any((s) => s.contains('4 preference key(s)')),
        isTrue,
        reason: 'a successful purge must be reported as removed, not skipped',
      );
    });

    test('reports prefs as skipped when no prefs are wired', () async {
      final profile = _profile();
      final fs = _FakeFs({profile.home: 10});
      final result = await _deleter(
        registry: _registry([profile]),
        lifecycle: _lifecycle(running: false),
        fs: fs, // no purgePrefs
      ).delete(profile);

      expect(
        result.skipped.any((s) => s.contains('preference keys')),
        isTrue,
        reason: 'prefs must be reported, never silently dropped',
      );
    });

    test('a prefs purge failure is recorded, not thrown', () async {
      final profile = _profile();
      final fs = _FakeFs({profile.home: 10});
      final result = await _deleter(
        registry: _registry([profile]),
        lifecycle: _lifecycle(running: false),
        fs: fs,
        purgePrefs: (_) async => throw Exception('prefs boom'),
      ).delete(profile);

      expect(result.outcome, ProfileDeletionOutcome.deleted);
      expect(result.skipped.any((s) => s.contains('prefs boom')), isTrue);
    });

    test('a regular file at home is erased, not falsely reported', () async {
      // fs.exists() is true for files too, so a recursive directory delete would
      // silently no-op while the result still claimed the home was removed.
      final profile = _profile();
      final fs = _FakeFs({profile.home: 10}, files: {profile.home});
      final result = await _deleter(
        registry: _registry([profile]),
        lifecycle: _lifecycle(running: false),
        fs: fs,
      ).delete(profile);

      expect(result.outcome, ProfileDeletionOutcome.deleted);
      expect(fs.deleted, contains(profile.home));
      expect(
        result.removed.any((s) => s.contains('was a file, not a directory')),
        isTrue,
        reason: 'the file case must be named honestly in the result',
      );
    });

    test('persists the registry removal to disk', () async {
      final profile = _profile();
      final fs = _FakeFs({profile.home: 10});
      final registry = _registry([profile]);
      await _deleter(
        registry: registry,
        lifecycle: _lifecycle(running: false),
        fs: fs,
      ).delete(profile);

      final reloaded = ProfileRegistry.load(makitRoot: _tempRoot.path);
      expect(reloaded.byId('work'), isNull);
    });
  });

  group('ProfileDeleter.diskUsage', () {
    test('returns the recursive byte sum of the profile home', () async {
      final profile = _profile();
      final fs = _FakeFs({profile.home: 123456});
      final usage = await _deleter(
        registry: _registry([profile]),
        lifecycle: _lifecycle(running: false),
        fs: fs,
      ).diskUsage(profile);

      expect(usage, 123456);
    });

    test(
      'refuses to measure a home outside ~/.makit* (corrupt registry)',
      () async {
        // A hand-edited `home: "/"` must never trigger a recursive walk of the
        // whole filesystem.
        final rogue = _profile(home: '/');
        final fs = _FakeFs({'/': 999999999});
        final usage = await _deleter(
          registry: _registry([rogue]),
          lifecycle: _lifecycle(running: false),
          fs: fs,
        ).diskUsage(rogue);

        expect(
          usage,
          0,
          reason: 'the disk root is not a measurable profile home',
        );
      },
    );

    test('still measures the protected legacy home (~/.makit)', () async {
      // The legacy home has no child segment so deletion refuses it, but its
      // size must still show in the list.
      final legacy = _profile(
        id: 'default',
        home: '$_homeDir/.makit',
        storage: ProfileStorage.legacy,
      );
      final fs = _FakeFs({legacy.home: 4242});
      final usage = await _deleter(
        registry: _registry([legacy]),
        lifecycle: _lifecycle(running: false),
        fs: fs,
      ).diskUsage(legacy);

      expect(usage, 4242);
    });
  });

  group('ProfileDeleter.delete is best-effort under filesystem failure', () {
    test('records a store failure and still returns a result', () async {
      // A filesystem error mid-delete must not throw out of the method (leaving
      // the caller with no outcome and a half-deleted profile): the failure is
      // recorded and the registry entry is still removed.
      final profile = _profile();
      final fs = _ThrowingFs({profile.home: 10}, throwOnDeleteDirectory: true);
      final registry = _registry([profile]);
      final result = await ProfileDeleter(
        registry: registry,
        lifecycle: _lifecycle(running: false),
        activeProfileId: 'other',
        homeDir: _homeDir,
        fs: fs,
        isMacOS: true,
      ).delete(profile);

      expect(result.outcome, ProfileDeletionOutcome.deleted);
      expect(
        result.skipped.any((s) => s.contains('MAKIT_HOME')),
        isTrue,
        reason: 'the home-delete failure must be reported, not swallowed',
      );
      // Step (4) still ran: the registry entry is gone.
      expect(registry.byId('work'), isNull);
    });
  });
}
