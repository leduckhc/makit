// A standalone harness for design-reviewing the SPEC-profiles profile surfaces on a
// real macOS window, with no server, no daemon and no filesystem writes.
//
//   rm -rf .dart_tool/flutter_build build/macos/Build/Products/Profile
//   flutter run -d macos --profile -t tool/profiles_demo.dart
//
// The cache clear is not optional: `flutter run -t <alt>` silently reuses a
// cached bundle and renders lib/main.dart instead, omitting your edits.
//
// Everything is seeded from fakes: the registry is in memory, the lifecycle
// answers without spawning `makit`, and the deleter refuses everything, so a
// misclick during review cannot delete real data.
// ignore_for_file: depend_on_referenced_packages, invalid_use_of_visible_for_testing_member
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';
import 'package:makit/desktop/daemon/profile_deleter.dart';
import 'package:makit/desktop/daemon/profile_lifecycle.dart';
import 'package:makit/desktop/daemon/profile_registry.dart';
import 'package:makit/desktop/daemon/profiles_controller.dart';
import 'package:makit/desktop/daemon/server_profile.dart';
import 'package:makit/desktop/settings/sections/profiles_providers.dart';
import 'package:makit/desktop/settings/sections/profiles_section.dart';
import 'package:makit/desktop/settings/sections/server_devices_section.dart';
import 'package:makit/desktop/settings/server_config.dart';
import 'package:makit/store/prefs/profile_scoped_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A registry seeded to look like a real machine mid-development: the installed
/// profile, a hand-made one that is stopped, two live dev builds, and a pile of
/// stale ones whose worktrees are gone.
ProfileRegistry _seededRegistry() => ProfileRegistry(
  makitRoot: '/Users/dev/.makit',
  fs: _NoWriteFs(),
  profiles: [
    const ServerProfile(
      id: 'default',
      name: 'Work',
      kind: ProfileKind.user,
      home: '/Users/dev/.makit',
      port: 7777,
      storage: ProfileStorage.legacy,
    ),
    const ServerProfile(
      id: 'personal',
      name: 'Personal',
      kind: ProfileKind.user,
      home: '/Users/dev/.makit/profiles/personal',
      port: 7805,
      storage: ProfileStorage.namespaced,
    ),
    const ServerProfile(
      id: 'a1b2c3d4',
      name: 'feat-profiles',
      kind: ProfileKind.dev,
      home: '/Users/dev/.makit-dev/a1b2c3d4',
      port: 7813,
      storage: ProfileStorage.namespaced,
      origin: '/Users/dev/.worktrees/makit/feat-profiles',
    ),
    const ServerProfile(
      id: 'bb806071',
      name: 'feat-serving-html',
      kind: ProfileKind.dev,
      home: '/Users/dev/.makit-dev/bb806071',
      port: 7841,
      storage: ProfileStorage.namespaced,
      origin: '/Users/dev/.worktrees/makit/feat-serving-html',
    ),
    // Stale: their origins no longer exist.
    for (final (i, id) in const [
      '5600c573',
      '985570e6',
      'db91190d',
      '98e0d35f',
      '6cebda53',
    ].indexed)
      ServerProfile(
        id: id,
        name: 'gone-worktree-$i',
        kind: ProfileKind.dev,
        home: '/Users/dev/.makit-dev/$id',
        port: 7850 + i,
        storage: ProfileStorage.namespaced,
        origin: '/Users/dev/.worktrees/makit/deleted-$i',
      ),
  ],
);

/// Never touches the disk: a design review must not write `profiles.json`.
class _NoWriteFs extends FileSystemAdapter {
  @override
  String? readOrNull(String path) => null;
  @override
  void writeAtomic(String path, String contents) {}
  // Without this, the base withLock creates `<path>.lock` on disk, breaking the
  // no-write guarantee.
  @override
  T withLock<T>(String path, T Function() body) => body();
}

/// Sizes chosen to exercise the formatter: bytes, KB, MB and a big one.
const Map<String, int> _sizes = {
  'default': 122 * 1024 * 1024,
  'personal': 3 * 1024 * 1024 + 200 * 1024,
  'a1b2c3d4': 4 * 1024 * 1024 + 400 * 1024,
  'bb806071': 7 * 1024 * 1024 + 200 * 1024,
  '5600c573': 7 * 1024 * 1024 + 600 * 1024,
  '985570e6': 6 * 1024 * 1024 + 200 * 1024,
  'db91190d': 6 * 1024 * 1024 + 200 * 1024,
  '98e0d35f': 6 * 1024 * 1024 + 200 * 1024,
  '6cebda53': 5 * 1024 * 1024 + 100 * 1024,
};

const Set<String> _running = {'default', 'a1b2c3d4', 'bb806071'};

MakitCliResolver _resolver() => MakitCliResolver(
  candidatePaths: const [],
  exists: (_) => false,
  shellLookup: () async => '/usr/local/bin/makit',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final registry = _seededRegistry();

  final lifecycle = ProfileLifecycle(
    resolver: _resolver(),
    run: (exe, args, {environment}) async => ProcessResult(0, 0, '', ''),
    socketExists: (_) => true,
    statusProbe: (p) async => _running.contains(p.id),
    sleep: (_) async {},
  );
  final controller = ProfilesController(
    registry: registry,
    activeProfileId: 'default',
    isRunning: (p) async => _running.contains(p.id),
    diskUsage: (p) async => _sizes[p.id] ?? 0,
    dirExists: (path) => !path.contains('deleted-'),
  );
  await controller.refresh();

  runApp(
    ProviderScope(
      overrides: [
        profilesControllerProvider.overrideWithValue(controller),
        profileLifecycleProvider.overrideWithValue(lifecycle),
        profileDeleterProvider.overrideWithValue(
          ProfileDeleter(
            registry: registry,
            lifecycle: lifecycle,
            // Every delete is refused, so a misclick during a design review
            // cannot erase anything. The mechanism is `homeDir`, not the id:
            // `_unsafeHomeReason` requires a home under `<homeDir>/.makit/` or
            // `<homeDir>/.makit-dev/`, and no seeded profile lives under
            // `/nonexistent/`. (`activeProfileId` alone would NOT be enough --
            // it matches no profile, so a namespaced one like `personal` would
            // pass both that check and `isProtected`.)
            activeProfileId: 'ALL-REFUSED',
            homeDir: '/nonexistent',
          ),
        ),
        serverConfigProvider.overrideWith(
          (ref) => ServerConfigController(
            ProfileScopedPrefs.unscoped(prefs),
            const ServerConfig(),
          ),
        ),
      ],
      child: const _DemoApp(),
    ),
  );
}

class _DemoApp extends StatefulWidget {
  const _DemoApp();
  @override
  State<_DemoApp> createState() => _DemoAppState();
}

enum _Pane { profiles, server }

class _DemoAppState extends State<_DemoApp> {
  _Pane _pane = _Pane.profiles;
  bool _light = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: makitLightTheme,
      darkTheme: makitDarkTheme,
      themeMode: _light ? ThemeMode.light : ThemeMode.dark,
      home: Scaffold(
        body: Column(
          children: [
            // Harness chrome — not product UI, do not design-review this bar.
            Container(
              height: 34,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  for (final p in _Pane.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: TextButton(
                        onPressed: () => setState(() => _pane = p),
                        child: Text(
                          p.name,
                          style: TextStyle(
                            fontWeight: _pane == p
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() => _light = !_light),
                    child: Text(_light ? 'light' : 'dark'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: switch (_pane) {
                _Pane.profiles => const ProfilesSection(),
                _Pane.server => const ServerDevicesSection(),
              },
            ),
          ],
        ),
      ),
    );
  }
}
