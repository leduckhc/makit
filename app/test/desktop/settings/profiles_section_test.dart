import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';
import 'package:makit/desktop/daemon/profile_deleter.dart';
import 'package:makit/desktop/daemon/profile_lifecycle.dart';
import 'package:makit/desktop/daemon/profile_registry.dart';
import 'package:makit/desktop/daemon/profiles_controller.dart';
import 'package:makit/desktop/daemon/server_profile.dart';
import 'package:makit/desktop/settings/sections/profiles_providers.dart';
import 'package:makit/desktop/settings/sections/profiles_section.dart';
import 'package:makit/status/status_center.dart';
import 'package:makit/status/status_event.dart';
import 'package:makit/status/status_providers.dart';

/// A registry [FileSystemAdapter] that persists nowhere, so `save()` in tests
/// touches no disk.
class _MemFs extends FileSystemAdapter {
  const _MemFs();
  @override
  String? readOrNull(String path) => null;
  @override
  void writeAtomic(String path, String contents) {}
}

/// An in-memory [ProfileFileSystem] for the deleter: only the paths seeded in
/// [sizes] exist, and deletes are recorded rather than performed.
class _FakeProfileFs implements ProfileFileSystem {
  _FakeProfileFs(this.sizes);
  final Map<String, int> sizes;
  final Set<String> deleted = {};

  @override
  bool exists(String path) =>
      sizes.containsKey(path) && !deleted.contains(path);
  @override
  Future<int> sizeOf(String path) async => sizes[path] ?? 0;
  @override
  Future<void> deleteDirectory(String path) async => deleted.add(path);
  @override
  Future<void> deleteFile(String path) async => deleted.add(path);
}

const _homeDir = '/Users/test';

ServerProfile _legacy({String id = 'work', String name = 'Work'}) =>
    ServerProfile(
      id: id,
      name: name,
      kind: ProfileKind.user,
      home: '$_homeDir/.makit',
      port: 7777,
      storage: ProfileStorage.legacy,
    );

ServerProfile _dev({
  String id = 'a1b2c3d4',
  String name = 'feat-profiles',
  String? origin = '/Users/test/.worktrees/makit/feat-profiles',
  String? home,
}) => ServerProfile(
  id: id,
  name: name,
  kind: ProfileKind.dev,
  home: home ?? '$_homeDir/.makit-dev/$id',
  port: 7813,
  storage: ProfileStorage.namespaced,
  origin: origin,
);

ProfileLifecycle _okLifecycle() => ProfileLifecycle(
  resolver: MakitCliResolver(
    candidatePaths: const ['/opt/homebrew/bin/makit'],
    exists: (path) => path == '/opt/homebrew/bin/makit',
    shellLookup: () async => null,
  ),
  run: (exe, args, {environment}) async => ProcessResult(0, 0, '', ''),
  socketExists: (path) => false,
  statusProbe: (profile) async => false,
  sleep: (d) async {},
);

ProfileLifecycle _failingLifecycle(String stdout) => ProfileLifecycle(
  resolver: MakitCliResolver(
    candidatePaths: const ['/opt/homebrew/bin/makit'],
    exists: (path) => path == '/opt/homebrew/bin/makit',
    shellLookup: () async => null,
  ),
  run: (exe, args, {environment}) async => ProcessResult(0, 1, stdout, ''),
  socketExists: (path) => false,
  sleep: (d) async {},
);

({
  ProfilesController controller,
  ProfileDeleter deleter,
  ProfileLifecycle lifecycle,
  ProfileRegistry registry,
})
_wiring({
  required List<ServerProfile> profiles,
  required String activeId,
  Map<String, bool> running = const {},
  Map<String, int> disk = const {},
  Set<String> existingOrigins = const {},
  Map<String, int>? fsSizes,
  ProfileLifecycle? lifecycle,
}) {
  final registry = ProfileRegistry(
    makitRoot: '$_homeDir/.makit',
    profiles: profiles,
    probe: (port) async => true,
    fs: const _MemFs(),
  );
  final controller = ProfilesController(
    registry: registry,
    activeProfileId: activeId,
    isRunning: (p) async => running[p.id] ?? false,
    diskUsage: (p) async => disk[p.id] ?? 0,
    dirExists: (path) => existingOrigins.contains(path),
  );
  final life = lifecycle ?? _okLifecycle();
  final deleter = ProfileDeleter(
    registry: registry,
    lifecycle: life,
    activeProfileId: activeId,
    homeDir: _homeDir,
    fs: _FakeProfileFs(fsSizes ?? const {}),
    isMacOS: false,
  );
  return (
    controller: controller,
    deleter: deleter,
    lifecycle: life,
    registry: registry,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required ProfilesController controller,
  required ProfileDeleter deleter,
  required ProfileLifecycle lifecycle,
  StatusCenter? statusCenter,
}) async {
  tester.view.physicalSize = const Size(1400, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profilesControllerProvider.overrideWithValue(controller),
        profileDeleterProvider.overrideWithValue(deleter),
        profileLifecycleProvider.overrideWithValue(lifecycle),
        if (statusCenter != null)
          statusCenterProvider.overrideWithValue(statusCenter),
      ],
      child: const MaterialApp(home: Scaffold(body: ProfilesSection())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists profiles with active and dev-build pills', (tester) async {
    final w = _wiring(
      profiles: [_legacy(), _dev()],
      activeId: 'work',
      running: const {'work': true},
      disk: const {'work': 128 * 1024 * 1024, 'a1b2c3d4': 4600000},
      existingOrigins: const {'/Users/test/.worktrees/makit/feat-profiles'},
    );
    await _pump(
      tester,
      controller: w.controller,
      deleter: w.deleter,
      lifecycle: w.lifecycle,
    );

    expect(find.text('Work'), findsOneWidget);
    expect(find.text('feat-profiles'), findsOneWidget);
    expect(find.text('active'), findsOneWidget);
    expect(find.text('dev build'), findsOneWidget);
    expect(find.text('Running'), findsWidgets);
  });

  testWidgets('stale group is hidden when nothing is stale', (tester) async {
    final w = _wiring(
      profiles: [_legacy(), _dev()],
      activeId: 'work',
      existingOrigins: const {'/Users/test/.worktrees/makit/feat-profiles'},
    );
    await _pump(
      tester,
      controller: w.controller,
      deleter: w.deleter,
      lifecycle: w.lifecycle,
    );

    expect(find.text('STALE — SOURCE FOLDER IS GONE'), findsNothing);
  });

  testWidgets('stale group appears only when a dev origin is gone', (
    tester,
  ) async {
    final w = _wiring(
      profiles: [_legacy(), _dev()],
      activeId: 'work',
      disk: const {'a1b2c3d4': 4600000},
      existingOrigins: const {}, // origin folder is gone → stale
    );
    await _pump(
      tester,
      controller: w.controller,
      deleter: w.deleter,
      lifecycle: w.lifecycle,
    );

    expect(find.text('STALE — SOURCE FOLDER IS GONE'), findsOneWidget);
    expect(find.text('1 orphaned dev profile'), findsOneWidget);
    expect(find.text('Review…'), findsOneWidget);
  });

  testWidgets('a protected profile offers no Delete in its menu', (
    tester,
  ) async {
    final w = _wiring(
      profiles: [_legacy()],
      activeId: 'work',
      existingOrigins: const {},
    );
    await _pump(
      tester,
      controller: w.controller,
      deleter: w.deleter,
      lifecycle: w.lifecycle,
    );

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();

    expect(find.text('Rename…'), findsOneWidget);
    expect(find.text('Delete…'), findsNothing);
    expect(find.text('Switch away & delete…'), findsNothing);
  });

  testWidgets('the active non-protected profile disables Delete with a note', (
    tester,
  ) async {
    // A namespaced active profile (not the legacy one): Delete is present but
    // disabled, phrased as "switch away & delete".
    final w = _wiring(
      profiles: [_dev(id: 'active-dev', origin: null)],
      activeId: 'active-dev',
    );
    await _pump(
      tester,
      controller: w.controller,
      deleter: w.deleter,
      lifecycle: w.lifecycle,
    );

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('Switch away & delete…'), findsOneWidget);
  });

  testWidgets('delete sheet names both what goes and what stays', (
    tester,
  ) async {
    final w = _wiring(
      profiles: [_legacy(), _dev()],
      activeId: 'work',
      disk: const {'a1b2c3d4': 4600000},
      existingOrigins: const {'/Users/test/.worktrees/makit/feat-profiles'},
      fsSizes: const {'/Users/test/.makit-dev/a1b2c3d4': 4600000},
    );
    await _pump(
      tester,
      controller: w.controller,
      deleter: w.deleter,
      lifecycle: w.lifecycle,
    );

    // The dev profile's menu is the second one (active work is first).
    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();

    expect(find.text('Delete “feat-profiles”?'), findsOneWidget);
    expect(find.text('WILL BE DELETED'), findsOneWidget);
    expect(find.text('WILL BE KEPT'), findsOneWidget);
    expect(find.text('worktrees and repos are never touched'), findsOneWidget);
    expect(find.text('every other profile is unaffected'), findsOneWidget);
  });

  testWidgets('a refusal surfaces its reason through the status center', (
    tester,
  ) async {
    final center = StatusCenter();
    addTearDown(center.dispose);
    // A non-active, non-protected profile whose home is OUTSIDE ~/.makit* — the
    // deleter refuses with refusedUnsafePath.
    final unsafe = _dev(id: 'bad', origin: null, home: '/tmp/outside');
    final w = _wiring(profiles: [_legacy(), unsafe], activeId: 'work');
    await _pump(
      tester,
      controller: w.controller,
      deleter: w.deleter,
      lifecycle: w.lifecycle,
      statusCenter: center,
    );

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete profile'));
    await tester.pumpAndSettle();

    final failures = center.events.where(
      (e) => e.severity == StatusSeverity.failure,
    );
    expect(failures, isNotEmpty);
    expect(failures.last.detail, contains('outside'));
  });

  testWidgets('a successful delete reports bytes freed and the skipped prefs', (
    tester,
  ) async {
    final center = StatusCenter();
    addTearDown(center.dispose);
    final w = _wiring(
      profiles: [_legacy(), _dev()],
      activeId: 'work',
      disk: const {'a1b2c3d4': 4600000},
      existingOrigins: const {'/Users/test/.worktrees/makit/feat-profiles'},
      fsSizes: const {'/Users/test/.makit-dev/a1b2c3d4': 4600000},
    );
    await _pump(
      tester,
      controller: w.controller,
      deleter: w.deleter,
      lifecycle: w.lifecycle,
      statusCenter: center,
    );

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete profile'));
    await tester.pumpAndSettle();

    final successes = center.events.where(
      (e) => e.severity == StatusSeverity.success,
    );
    expect(successes, isNotEmpty);
    expect(successes.last.title, contains('Deleted feat-profiles'));
    // The NSUserDefaults keys the deleter cannot purge are surfaced, not hidden.
    expect(successes.last.detail, contains('NSUserDefaults'));
    // The registry entry is gone, so the row disappears.
    expect(find.text('feat-profiles'), findsNothing);
  });

  testWidgets('New profile prompts for a name and creates it', (tester) async {
    final w = _wiring(profiles: [_legacy()], activeId: 'work');
    await _pump(
      tester,
      controller: w.controller,
      deleter: w.deleter,
      lifecycle: w.lifecycle,
    );

    await tester.tap(find.text('New profile'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Personal');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(w.registry.profiles.any((p) => p.name == 'Personal'), isTrue);
    expect(find.text('Personal'), findsOneWidget);
  });

  testWidgets('a failed Start is reported through the status center', (
    tester,
  ) async {
    final center = StatusCenter();
    addTearDown(center.dispose);
    final w = _wiring(
      profiles: [_legacy(), _dev()],
      activeId: 'work',
      existingOrigins: const {'/Users/test/.worktrees/makit/feat-profiles'},
      lifecycle: _failingLifecycle('makit: failed to start — port in use'),
    );
    await _pump(
      tester,
      controller: w.controller,
      deleter: w.deleter,
      lifecycle: w.lifecycle,
      statusCenter: center,
    );

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    final failures = center.events.where(
      (e) => e.severity == StatusSeverity.failure,
    );
    expect(failures, isNotEmpty);
    expect(failures.last.detail, contains('failed to start'));
  });
}
