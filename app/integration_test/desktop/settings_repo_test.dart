// SPEC-48 T6.2 — the per-repo Settings path, mounted for real.
//
// What this proves that the unit and widget tests cannot: the WHOLE path from the
// live repo snapshot through the dynamic registry to a rendered row, inside the
// real `SettingsWindow`, on a real macOS build.
//
//   reposProvider → sectionsFor() → the nav pane → tap → RepositorySettingsPage
//     → repoSettingsViewFor() → RepositorySettingsSection → the rows
//
// Every hop above is covered by a unit or widget test in isolation. None of them
// covers the composition, and this repo has already been bitten there once: the
// desktop shell mounts Settings *outside* a GoRouter, so a section that navigated
// with `context.go` threw at runtime while every test stayed green. A test that
// mounts the section directly cannot catch that class of fault; this one can.
//
// Deliberately NOT extended onto the daemon control socket (see the plan's T6.2):
// the daemon-side behaviour is proven by the server tests, and routing this through
// the socket would add infrastructure for no extra coverage. The repo snapshot is
// stubbed at `reposProvider`, which is exactly the seam `SettingsWindow` reads.
//
// Run: app/tool/e2e-desktop-settings.sh
//
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';
import 'package:makit/desktop/desktop_app.dart' show desktopControllerProvider;
import 'package:makit/desktop/desktop_controller.dart';
import 'package:makit/desktop/screens/fake_control_client.dart';
import 'package:makit/desktop/settings/sections/repository_section.dart';
import 'package:makit/desktop/settings/server_config.dart';
import 'package:makit/desktop/settings/settings_nav_pane.dart';
import 'package:makit/desktop/settings/settings_window.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/repo_monogram.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Two pinned repos and one unpinned, so the pinned filter is exercised by the
/// same fixture that exercises the rows.
///
/// `Diana` carries a worktree-root override and a chosen hue; `makit` inherits
/// everything. The difference is the point: the section has to report each repo's
/// own state, and a bug that reads the wrong repo's settings passes any fixture
/// where both repos look the same.
final _repos = <RepoInfo>[
  RepoInfo.fromJson({
    'id': 'p-diana',
    'name': 'Diana',
    'path': '/Users/le/Work/XDent/Diana',
    'pinned': true,
    'isGitRepo': true,
    'defaultBranch': 'main',
    'currentBranch': 'main',
    'worktrees': const <Map<String, dynamic>>[],
    'settings': {
      'worktreeRoot': {'value': '/Users/le/trees/diana', 'source': 'override'},
      'provider': {'value': 'forgejo', 'source': 'override'},
      'defaultBranch': {'value': 'trunk', 'source': 'override'},
      'logoHue': 2,
      'hasRemote': true,
      'forge': {'software': 'forgejo', 'host': 'forgejo.internal.test', 'authed': true},
    },
  })!,
  RepoInfo.fromJson({
    'id': 'p-makit',
    'name': 'makit',
    'path': '/Users/le/Work/makit',
    'pinned': true,
    'isGitRepo': true,
    'defaultBranch': 'main',
    'currentBranch': 'main',
    'worktrees': const <Map<String, dynamic>>[],
    'settings': {
      'worktreeRoot': {'value': '/Users/le/.worktrees', 'source': 'default'},
      'provider': {'value': 'auto', 'source': 'default'},
      'hasRemote': true,
    },
  })!,
  RepoInfo.fromJson({
    'id': 'p-noticed',
    'name': 'noticed',
    'path': '/tmp/noticed',
    'pinned': false,
    'isGitRepo': true,
    'worktrees': const <Map<String, dynamic>>[],
  })!,
];

late SharedPreferences _prefs;

Widget _app() => ProviderScope(
  overrides: [
    reposProvider.overrideWithValue(ReposState(_repos)),
    serverConfigProvider.overrideWith(
      (ref) => ServerConfigController(_prefs, const ServerConfig()),
    ),
    desktopControllerProvider.overrideWithValue(
      DesktopController(
        client: FakeControlClient(),
        lifecycle: DaemonLifecycle(resolver: MakitCliResolver(shellLookup: () async => null)),
      ),
    ),
    connectionProvider.overrideWithValue(MakitConnState()),
  ],
  child: MaterialApp(home: SettingsWindow(onClose: () {})),
);

Future<void> _openRepo(WidgetTester tester, String name) async {
  final row = find.descendant(
    of: find.byType(SettingsNavPane),
    matching: find.text(name),
  );
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('a pinned repo gets a reachable section in the real window', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // The sidebar lists the pinned repos and not the merely-noticed one.
    expect(find.text('Diana'), findsWidgets);
    expect(find.text('makit'), findsWidgets);
    expect(find.text('noticed'), findsNothing);

    await _openRepo(tester, 'Diana');

    // The section rendered — not an empty pane, and not the fallback section.
    // Group headers are upper-cased by `SettingsSectionHeader`, so these assert the
    // rendered string rather than the source one.
    expect(find.byType(RepositorySettingsSection), findsOneWidget);
    expect(find.text('IDENTITY'), findsOneWidget);
    expect(find.text('WORKTREES'), findsOneWidget);
    // And the rows themselves, so "the section mounted" is not mistaken for "the
    // section rendered its contents".
    expect(find.text('Logo'), findsOneWidget);
    expect(find.text('Git provider'), findsOneWidget);
    expect(find.text('Worktree root'), findsOneWidget);
  });

  testWidgets('the rows carry THIS repo\'s values, resolved from the snapshot', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await _openRepo(tester, 'Diana');

    // The override, home-abbreviated, and the badge that distinguishes it from an
    // inherited root — the one row where that distinction is the whole feature.
    expect(find.text('~/trees/diana'), findsOneWidget);
    expect(find.text('overridden'), findsOneWidget);
    // The provider override relabels the row rather than reporting detection.
    expect(find.textContaining('Set to Forgejo'), findsOneWidget);
    // The default-branch override wins over the DTO's git-derived `main`.
    expect(find.text('trunk'), findsOneWidget);
  });

  testWidgets('switching repos re-renders from the newly selected repo', (tester) async {
    // The bug this guards: a section built once and cached would keep showing the
    // first repo's values under the second repo's title, which reads as correct.
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _openRepo(tester, 'Diana');
    expect(find.text('overridden'), findsOneWidget);

    await _openRepo(tester, 'makit');
    expect(find.text('~/trees/diana'), findsNothing, reason: "Diana's root leaked into makit");
    expect(find.text('overridden'), findsNothing, reason: 'makit inherits, so nothing is overridden');
    expect(find.text('~/.worktrees'), findsOneWidget);
  });

  testWidgets('the sidebar draws each repo its own mark, with the chosen hue', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final marks = find.descendant(
      of: find.byType(SettingsNavPane),
      matching: find.byType(RepoMonogram),
    );
    expect(marks, findsNWidgets(2), reason: 'one mark per pinned repo');
    final diana = tester.widgetList<RepoMonogram>(marks).firstWhere((m) => m.name == 'Diana');
    expect(diana.hue, 2, reason: 'the stored hue must reach the sidebar');
  });

  testWidgets('search reaches a repo row and lands on that repo', (tester) async {
    // The nav pane searches the DYNAMIC sections; on the static list "worktree root"
    // found nothing and the result title would have been a raw `repo:<id>`.
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'worktree root');
    await tester.pumpAndSettle();

    final result = find.text('Worktrees').first;
    await tester.tap(result);
    await tester.pumpAndSettle();

    expect(find.byType(RepositorySettingsSection), findsOneWidget);
  });
}
