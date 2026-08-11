// Tests for the profile switcher UI (SPEC-50 D10).
//
// The switch itself lives in `_ProfileHostState.switchTo` in desktop_app.dart,
// which owns the ProviderScope and cannot be built in a widget test. What IS
// testable — and what actually protects the user — is the contract around it:
// the badge must confirm first, must not switch when the user declines, and must
// report a failure instead of pretending it worked.
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/desktop/chat/server_profile_badge.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';
import 'package:makit/desktop/daemon/profile_lifecycle.dart';
import 'package:makit/desktop/daemon/profile_registry.dart';
import 'package:makit/desktop/daemon/profiles_controller.dart';
import 'package:makit/desktop/daemon/server_profile.dart';
import 'package:makit/desktop/desktop_app.dart' show serverProfileProvider;
import 'package:makit/desktop/settings/sections/profiles_providers.dart';
import 'package:makit/status/status_center.dart';
import 'package:makit/status/status_event.dart';
import 'package:makit/status/status_providers.dart';

const ServerProfile _work = ServerProfile(
  id: 'work',
  name: 'Work',
  kind: ProfileKind.user,
  home: '/h/.makit',
  port: 7777,
  storage: ProfileStorage.legacy,
);

const ServerProfile _personal = ServerProfile(
  id: 'personal',
  name: 'Personal',
  kind: ProfileKind.user,
  home: '/h/.makit/profiles/personal',
  port: 7805,
  storage: ProfileStorage.namespaced,
);

class _NoWriteFs extends FileSystemAdapter {
  @override
  String? readOrNull(String path) => null;
  @override
  void writeAtomic(String path, String contents) {}
}

ProfileLifecycle _lifecycle({required bool targetRunning}) => ProfileLifecycle(
  resolver: MakitCliResolver(
    candidatePaths: const [],
    exists: (_) => false,
    shellLookup: () async => '/usr/local/bin/makit',
  ),
  socketExists: (_) => targetRunning,
  statusProbe: (_) async => targetRunning,
  sleep: (_) async {},
);

Future<({List<String> switched, StatusCenter center})> _pump(
  WidgetTester tester, {
  required Future<String?> Function(ServerProfile) switcher,
  bool targetRunning = true,
}) async {
  final switched = <String>[];
  final center = StatusCenter();
  addTearDown(center.dispose);

  final registry = ProfileRegistry(
    makitRoot: '/h/.makit',
    fs: _NoWriteFs(),
    profiles: const [_work, _personal],
  );
  final controller = ProfilesController(
    registry: registry,
    activeProfileId: 'work',
    isRunning: (p) async => true,
    dirExists: (_) => true,
  );
  await controller.refresh();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        serverProfileProvider.overrideWithValue(_work),
        profilesControllerProvider.overrideWithValue(controller),
        switcherProfilesProvider.overrideWithValue(controller),
        profileLifecycleProvider.overrideWithValue(
          _lifecycle(targetRunning: targetRunning),
        ),
        statusCenterProvider.overrideWithValue(center),
        profileSwitcherProvider.overrideWithValue((target) async {
          switched.add(target.id);
          return switcher(target);
        }),
      ],
      child: MaterialApp(
        theme: makitDarkTheme,
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: ServerProfileBadge(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (switched: switched, center: center);
}

void main() {
  testWidgets('the pill names the active profile', (tester) async {
    await _pump(tester, switcher: (_) async => null);
    expect(find.text('Work'), findsOneWidget);
  });

  testWidgets('choosing another profile confirms before switching', (
    tester,
  ) async {
    final r = await _pump(tester, switcher: (_) async => null);

    await tester.tap(find.byType(ServerProfileBadge));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Personal').last);
    await tester.pumpAndSettle();

    // The sheet is up and nothing has switched yet.
    expect(find.text('Switch to “Personal”?'), findsOneWidget);
    expect(r.switched, isEmpty);

    // It states what survives — the half that makes the button usable.
    expect(find.text('WHAT KEEPS RUNNING'), findsOneWidget);
    expect(find.textContaining('Work’s server stays up'), findsOneWidget);
    expect(
      find.textContaining('Work’s agents are not interrupted'),
      findsOneWidget,
    );
  });

  testWidgets('declining the sheet switches nothing', (tester) async {
    final r = await _pump(tester, switcher: (_) async => null);

    await tester.tap(find.byType(ServerProfileBadge));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Personal').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(r.switched, isEmpty);
    expect(r.center.events, isEmpty);
  });

  testWidgets('confirming switches and reports success', (tester) async {
    final r = await _pump(tester, switcher: (_) async => null);

    await tester.tap(find.byType(ServerProfileBadge));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Personal').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch to Personal'));
    await tester.pumpAndSettle();

    expect(r.switched, ['personal']);
    expect(r.center.events.last.severity, StatusSeverity.success);
  });

  // A switch that fails must say so. Reporting nothing would leave the user
  // believing they had moved profile when the window had not.
  testWidgets('a failed switch is reported with its reason', (tester) async {
    final r = await _pump(
      tester,
      switcher: (_) async => 'Personal started but is not answering',
    );

    await tester.tap(find.byType(ServerProfileBadge));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Personal').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch to Personal'));
    await tester.pumpAndSettle();

    final event = r.center.events.last;
    expect(event.severity, StatusSeverity.failure);
    expect(event.title, contains('Could not switch to Personal'));
    expect(event.detail, contains('not answering'));
  });

  testWidgets('a stopped target is offered, and the sheet says it will start', (
    tester,
  ) async {
    await _pump(tester, switcher: (_) async => null, targetRunning: false);

    await tester.tap(find.byType(ServerProfileBadge));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Personal').last);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Personal’s server starts'),
      findsOneWidget,
      reason: 'the sheet must say the target will be started',
    );
  });
}
