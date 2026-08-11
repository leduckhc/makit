// Unit tests for [ProfilesController] (SPEC-50 P3).
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/profile_registry.dart';
import 'package:makit/desktop/daemon/profiles_controller.dart';
import 'package:makit/desktop/daemon/server_profile.dart';

class _MemoryFs extends FileSystemAdapter {
  final Map<String, String> written = {};
  @override
  String? readOrNull(String path) => written[path];
  @override
  void writeAtomic(String path, String contents) => written[path] = contents;
}

Future<bool> _allFree(int port) async => true;

ServerProfile _p(
  String id, {
  ProfileKind kind = ProfileKind.user,
  String? origin,
  ProfileStorage storage = ProfileStorage.namespaced,
  int port = 7800,
}) => ServerProfile(
  id: id,
  name: id,
  kind: kind,
  home: '/h/$id',
  port: port,
  storage: storage,
  origin: origin,
);

void main() {
  group('ProfilesController', () {
    late _MemoryFs fs;
    setUp(() => fs = _MemoryFs());

    ProfilesController build({
      List<ServerProfile>? profiles,
      String active = 'default',
      RunningProbe? isRunning,
      DiskProbe? diskUsage,
      bool Function(String)? dirExists,
    }) => ProfilesController(
      registry: ProfileRegistry(
        makitRoot: '/h/.makit',
        probe: _allFree,
        fs: fs,
        profiles:
            profiles ??
            [
              _p('default', storage: ProfileStorage.legacy, port: 7777),
              _p('dev1', kind: ProfileKind.dev, origin: '/gone', port: 7801),
            ],
      ),
      activeProfileId: active,
      isRunning: isRunning,
      diskUsage: diskUsage,
      dirExists: dirExists,
    );

    test('the active profile sorts first', () {
      final c = build(active: 'dev1');
      expect(c.rows.first.profile.id, 'dev1');
      expect(c.active!.id, 'dev1');
    });

    test('user profiles sort before dev profiles', () {
      final c = build(
        profiles: [
          _p('zzz-dev', kind: ProfileKind.dev, port: 7801),
          _p('aaa-user', port: 7802),
          _p('default', storage: ProfileStorage.legacy, port: 7777),
        ],
        active: 'default',
      );
      final ids = c.rows.map((r) => r.profile.id).toList();
      expect(ids.first, 'default');
      expect(ids.indexOf('aaa-user'), lessThan(ids.indexOf('zzz-dev')));
    });

    test('active is null when the registry lost it', () {
      expect(build(active: 'nope').active, isNull);
    });

    test('a dev profile with a missing origin is stale; others are not', () {
      final c = build(dirExists: (_) => false);
      final stale = c.rows.where((r) => r.stale).toList();
      expect(stale.length, 1);
      expect(stale.single.profile.id, 'dev1');
      // The legacy/user profile has no origin, so it can never be stale.
      expect(
        c.rows.firstWhere((r) => r.profile.id == 'default').stale,
        isFalse,
      );
    });

    test('nothing is stale when origins still exist', () {
      expect(build(dirExists: (_) => true).rows.any((r) => r.stale), isFalse);
    });

    test('refresh records running state and disk usage', () async {
      final c = build(
        isRunning: (p) async => p.id == 'dev1',
        diskUsage: (p) async => p.id == 'dev1' ? 4096 : 128,
        dirExists: (_) => true,
      );
      await c.refresh();
      final dev = c.rows.firstWhere((r) => r.profile.id == 'dev1');
      expect(dev.running, isTrue);
      expect(dev.diskBytes, 4096);
      expect(
        c.rows.firstWhere((r) => r.profile.id == 'default').running,
        isFalse,
      );
    });

    test('diskBytes is null before measurement, not zero', () {
      // A profile shown as "0 B" would be a lie; null lets the UI say nothing.
      expect(build().rows.every((r) => r.diskBytes == null), isTrue);
    });

    test('staleSummary sums only the stale rows', () async {
      final c = build(
        diskUsage: (p) async => p.id == 'dev1' ? 1024 : 999999,
        dirExists: (p) => false,
      );
      await c.refresh();
      final s = c.staleSummary;
      expect(s.rows.length, 1);
      expect(s.bytes, 1024);
    });

    test('create persists and notifies', () async {
      final c = build();
      var notified = 0;
      c.addListener(() => notified++);
      final created = await c.create('Personal');
      expect(created, isNotNull);
      expect(created!.name, 'Personal');
      expect(c.registry.byId(created.id), isNotNull);
      expect(notified, 1);
      // Persisted, not just held in memory: a profile the user named must
      // survive a relaunch.
      expect(fs.written['/h/.makit/profiles.json'], contains('Personal'));
    });

    test('create refuses a blank name without throwing', () async {
      final c = build();
      expect(await c.create('   '), isNull);
    });

    test('rename updates and notifies; an unknown id does neither', () {
      final c = build();
      var notified = 0;
      c.addListener(() => notified++);
      expect(c.rename('dev1', 'Renamed'), isTrue);
      expect(c.registry.byId('dev1')!.name, 'Renamed');
      expect(notified, 1);

      expect(c.rename('nope', 'x'), isFalse);
      expect(notified, 1);
    });

    test('forget removes a dev profile but never the protected one', () {
      final c = build();
      expect(c.forget('default'), isFalse);
      expect(c.registry.byId('default'), isNotNull);

      expect(c.forget('dev1'), isTrue);
      expect(c.registry.byId('dev1'), isNull);
    });

    test('noteRunning flips one row without a full refresh', () {
      final c = build();
      c.noteRunning('dev1', running: true);
      expect(c.rows.firstWhere((r) => r.profile.id == 'dev1').running, isTrue);
    });
  });
}
