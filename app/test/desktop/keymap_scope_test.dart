import 'package:flutter/material.dart' hide Tab, Split;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/keymap_scope.dart';
import 'package:makit/desktop/chat/groups/group.dart';
import 'package:makit/desktop/chat/groups/groups_controller.dart';
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/shortcuts/key_chord.dart';
import 'package:makit/shortcuts/keymap_controller.dart';
import 'package:makit/shortcuts/shortcut_action.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/ui/ports/ports_screen.dart';
import 'package:makit/store/store.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/transport/protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A connection that answers every request instantly — so the fire-and-forget
/// archive on tab close leaves no pending timeout Timer in widget tests.
class _FastConn extends ConnectionController {
  _FastConn() : super(const _NoStore());
  @override
  Future<Map<String, dynamic>> request(MsgType t, Map<String, dynamic> body) =>
      Future.value(const {});
}

class _NoStore implements SecureStore {
  const _NoStore();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

/// A store whose `createWorktree` returns a fixed path so the board-side
/// ⌘T/⌘D dialog can be confirmed and the result placed. Spawning must never
/// happen from the New-worktree flow.
class _WtStore extends StoreController {
  _WtStore(super.ref);

  int spawnCount = 0;

  @override
  Future<List<OpenPr>> listOpenPrs(String projectId) async => const [];

  @override
  Future<({String path, String? branch})> createWorktree(
    String projectId, {
    String? baseBranch,
    String? branchName,
  }) async => (path: '/tmp/wt/created', branch: 'auto/$baseBranch');

  @override
  Future<String> spawnSession(
    String projectId, {
    String? title,
    String? agent,
    String? worktreePath,
    String? branch,
    List<ConfigOptionPick>? configOptions,
  }) async {
    spawnCount++;
    return 's-should-not-happen';
  }
}

RepoInfo _repoWithBranches() => const RepoInfo(
  id: 'p1',
  name: 'makit',
  path: '/tmp/p1',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: [
    Worktree(
      id: 'main',
      path: '/tmp/wt/main',
      branch: 'main',
      isPrimary: true,
      insertions: 0,
      deletions: 0,
      filesChanged: 0,
      sessionIds: [],
    ),
  ],
);

/// A worktree group scoped to `(p1, path)`, active on its own single-split tree.
GroupsController _wtGroups(String path) => GroupsController.ephemeral(
  GroupsState(
    groups: [
      Group.worktree(
        id: 'wt1',
        projectId: 'p1',
        worktreePath: path,
        label: 'feature-x',
        tree: WorkspaceController.seedWorkspace(),
      ),
    ],
    activeGroupId: 'wt1',
  ),
);

/// Widget-level proof that [DesktopKeymapScope] turns a persisted [Keymap] into
/// live global shortcuts. Uses Ctrl-primary defaults (cmdIsPrimary: false) so
/// the combos are deterministic regardless of the test host platform.
void main() {
  setUp(() {
    resetNodeIds();
    SharedPreferences.setMockInitialValues({});
  });

  Future<KeymapController> controller() async {
    final prefs = await SharedPreferences.getInstance();
    return KeymapController.load(prefs, cmdIsPrimary: false);
  }

  Future<void> pumpScope(
    WidgetTester tester, {
    required KeymapController keymap,
    required VoidCallback onOpenSettings,
    required ProviderContainer container,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DesktopKeymapScope(
            onOpenSettings: onOpenSettings,
            child: const Scaffold(body: Text('shell')),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pressCtrl(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(key);
    await tester.sendKeyUpEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  Session session(String id) => Session(
    id: id,
    projectId: 'p1',
    agent: 'pi',
    title: id,
    status: SessionStatus.idle,
    policy: ApprovalPolicy.askOnRisky,
    branch: 'feature-x',
    worktreePath: '/tmp/wt-x',
  );

  WorkspaceController workspace(ProviderContainer c) =>
      c.read(workspaceControllerProvider.notifier);

  testWidgets('Ctrl+B toggles the sidebar', (tester) async {
    final keymap = await controller();
    final container = ProviderContainer(
      overrides: [keymapProvider.overrideWith((_) => keymap)],
    );
    addTearDown(container.dispose);
    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () {},
      container: container,
    );

    expect(container.read(sidebarCollapsedProvider), isFalse);
    await pressCtrl(tester, LogicalKeyboardKey.keyB);
    expect(container.read(sidebarCollapsedProvider), isTrue);
    await pressCtrl(tester, LogicalKeyboardKey.keyB);
    expect(container.read(sidebarCollapsedProvider), isFalse);
  });

  testWidgets('Ctrl+B toggles the sidebar when nothing holds focus', (
    tester,
  ) async {
    final keymap = await controller();
    final container = ProviderContainer(
      overrides: [keymapProvider.overrideWith((_) => keymap)],
    );
    addTearDown(container.dispose);
    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () {},
      container: container,
    );

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    expect(container.read(sidebarCollapsedProvider), isFalse);
    await pressCtrl(tester, LogicalKeyboardKey.keyB);
    expect(container.read(sidebarCollapsedProvider), isTrue);
  });

  testWidgets('a focused field inside the scope keeps focus (not reclaimed)', (
    tester,
  ) async {
    final keymap = await controller();
    final container = ProviderContainer(
      overrides: [keymapProvider.overrideWith((_) => keymap)],
    );
    addTearDown(container.dispose);
    final fieldFocus = FocusNode(debugLabel: 'testField');
    addTearDown(fieldFocus.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DesktopKeymapScope(
            onOpenSettings: () {},
            child: Scaffold(body: TextField(focusNode: fieldFocus)),
          ),
        ),
      ),
    );
    await tester.pump();

    fieldFocus.requestFocus();
    await tester.pump();
    expect(fieldFocus.hasPrimaryFocus, isTrue);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(find.text('hello'), findsOneWidget);
    expect(fieldFocus.hasPrimaryFocus, isTrue);
  });

  testWidgets('Ctrl+, invokes the open-settings callback', (tester) async {
    final keymap = await controller();
    var opened = 0;
    final container = ProviderContainer(
      overrides: [keymapProvider.overrideWith((_) => keymap)],
    );
    addTearDown(container.dispose);
    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () => opened++,
      container: container,
    );

    await pressCtrl(tester, LogicalKeyboardKey.comma);
    expect(opened, 1);
  });

  testWidgets(
    'Ctrl+D in a worktree group splits with the scope hint, no dialog',
    (tester) async {
      // Decision 13: a worktree group already answers "where does it run?", so
      // ⌘D seeds the new split with its scope and never shows a dialog.
      final keymap = await controller();
      final groups = _wtGroups('/tmp/wt-a');
      final container = ProviderContainer(
        overrides: [
          keymapProvider.overrideWith((_) => keymap),
          sessionsProvider.overrideWithValue(SessionsState(const [])),
          groupsControllerProvider.overrideWith((_) => groups),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(workspaceControllerProvider).root, isA<Split>());

      await pumpScope(
        tester,
        keymap: keymap,
        onOpenSettings: () {},
        container: container,
      );
      await pressCtrl(tester, LogicalKeyboardKey.keyD);
      await tester.pumpAndSettle();

      // The single split became a splitter; the new starter tab carries the
      // group's scope, and no dialog appeared.
      expect(container.read(workspaceControllerProvider).root, isA<Splitter>());
      expect(find.text('New worktree'), findsNothing);
      final tab = activeTab(container.read(workspaceControllerProvider))!;
      expect(tab.sessionId, isNull, reason: 'a fresh starter tab');
      expect(tab.worktree?.path, '/tmp/wt-a');
    },
  );

  testWidgets(
    'Ctrl+D on a board opens the dialog; a confirmed worktree becomes a split',
    (tester) async {
      final keymap = await controller();
      late _WtStore store;
      final container = ProviderContainer(
        overrides: [
          keymapProvider.overrideWith((_) => keymap),
          sessionsProvider.overrideWithValue(SessionsState(const [])),
          reposProvider.overrideWithValue(ReposState([_repoWithBranches()])),
          connectionControllerProvider.overrideWith((_) => _FastConn()),
          storeControllerProvider.overrideWith((ref) {
            store = _WtStore(ref);
            return store;
          }),
        ],
      );
      addTearDown(container.dispose);
      // A pristine board is the default fresh group.
      expect(container.read(workspaceControllerProvider).root, isA<Split>());

      await pumpScope(
        tester,
        keymap: keymap,
        onOpenSettings: () {},
        container: container,
      );
      await pressCtrl(tester, LogicalKeyboardKey.keyD);
      await tester.pumpAndSettle();

      // The dialog opened (a board owns no scope, so it must ask).
      expect(find.text('New worktree'), findsOneWidget);
      await tester.tap(find.text('Create worktree'));
      await tester.pumpAndSettle();

      expect(store.spawnCount, 0);
      // The confirmed worktree landed as a new split, hinted with its path.
      expect(container.read(workspaceControllerProvider).root, isA<Splitter>());
      final tab = activeTab(container.read(workspaceControllerProvider))!;
      expect(tab.worktree?.path, '/tmp/wt/created');
    },
  );

  testWidgets('Ctrl+T in a worktree group adds a hinted tab, no dialog', (
    tester,
  ) async {
    final keymap = await controller();
    final groups = _wtGroups('/tmp/wt-a');
    final container = ProviderContainer(
      overrides: [
        keymapProvider.overrideWith((_) => keymap),
        sessionsProvider.overrideWithValue(SessionsState(const [])),
        groupsControllerProvider.overrideWith((_) => groups),
      ],
    );
    addTearDown(container.dispose);

    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () {},
      container: container,
    );
    await pressCtrl(tester, LogicalKeyboardKey.keyT);
    await tester.pumpAndSettle();

    // No dialog; a fresh tab hinted with the group's scope was added.
    expect(find.text('New worktree'), findsNothing);
    final split = container.read(workspaceControllerProvider).root as Split;
    expect(split.tabs.length, 2);
    final tab = activeTab(container.read(workspaceControllerProvider))!;
    expect(tab.sessionId, isNull);
    expect(tab.worktree?.path, '/tmp/wt-a');
  });

  testWidgets(
    'Ctrl+T on a board opens the dialog; a confirmed worktree becomes a tab',
    (tester) async {
      final keymap = await controller();
      late _WtStore store;
      final container = ProviderContainer(
        overrides: [
          keymapProvider.overrideWith((_) => keymap),
          sessionsProvider.overrideWithValue(SessionsState(const [])),
          reposProvider.overrideWithValue(ReposState([_repoWithBranches()])),
          connectionControllerProvider.overrideWith((_) => _FastConn()),
          storeControllerProvider.overrideWith((ref) {
            store = _WtStore(ref);
            return store;
          }),
        ],
      );
      addTearDown(container.dispose);

      await pumpScope(
        tester,
        keymap: keymap,
        onOpenSettings: () {},
        container: container,
      );
      await pressCtrl(tester, LogicalKeyboardKey.keyT);
      await tester.pumpAndSettle();

      expect(find.text('New worktree'), findsOneWidget);
      await tester.tap(find.text('Create worktree'));
      await tester.pumpAndSettle();

      expect(store.spawnCount, 0);
      // The confirmed worktree landed as a new tab in the board's split.
      final split = container.read(workspaceControllerProvider).root as Split;
      expect(split.tabs.length, 2);
      final tab = activeTab(container.read(workspaceControllerProvider))!;
      expect(tab.worktree?.path, '/tmp/wt/created');
    },
  );

  testWidgets('Ctrl+W closes the active split but keeps the sessions', (
    tester,
  ) async {
    final keymap = await controller();
    final container = ProviderContainer(
      overrides: [
        keymapProvider.overrideWith((_) => keymap),
        sessionsProvider.overrideWithValue(SessionsState([session('s1')])),
      ],
    );
    addTearDown(container.dispose);
    // s1 in the first split, then divide so a fresh empty split is active.
    workspace(container).revealSession('s1');
    workspace(container).divideActive(Axis.horizontal);

    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () {},
      container: container,
    );

    await pressCtrl(tester, LogicalKeyboardKey.keyW);

    // The active (empty) split is gone; the sibling with s1 remains.
    final root = container.read(workspaceControllerProvider).root;
    expect(root, isA<Split>());
    expect(container.read(selectedSessionProvider), 's1');
    expect(container.read(sessionsProvider).byId('s1'), isNotNull);
  });

  testWidgets('Ctrl+Shift+] cycles to the next tab in the active split', (
    tester,
  ) async {
    final keymap = await controller();
    final container = ProviderContainer(
      overrides: [
        keymapProvider.overrideWith((_) => keymap),
        sessionsProvider.overrideWithValue(
          SessionsState([session('s1'), session('s2')]),
        ),
      ],
    );
    addTearDown(container.dispose);
    // Two tabs in one split: s1 then s2 (active).
    workspace(container).revealSession('s1');
    workspace(container).revealSession('s2');
    expect(container.read(selectedSessionProvider), 's2');

    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () {},
      container: container,
    );

    // From s2 → next wraps to s1.
    await pressCtrl(tester, LogicalKeyboardKey.bracketRight, shift: true);
    expect(container.read(selectedSessionProvider), 's1');
  });

  testWidgets('Ctrl+Shift+W closes the active tab', (tester) async {
    final keymap = await controller();
    final container = ProviderContainer(
      overrides: [
        keymapProvider.overrideWith((_) => keymap),
        connectionControllerProvider.overrideWith((_) => _FastConn()),
        sessionsProvider.overrideWithValue(
          SessionsState([session('s1'), session('s2')]),
        ),
      ],
    );
    addTearDown(container.dispose);
    workspace(container).revealSession('s1');
    workspace(container).revealSession('s2'); // active tab s2

    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () {},
      container: container,
    );

    await pressCtrl(tester, LogicalKeyboardKey.keyW, shift: true);

    // s2's tab closed; the split falls back to the remaining s1 tab.
    expect(container.read(selectedSessionProvider), 's1');
    expect(container.read(sessionsProvider).byId('s2'), isNotNull);
  });

  testWidgets('rebinding is reflected live in the scope', (tester) async {
    final keymap = await controller();
    var opened = 0;
    final container = ProviderContainer(
      overrides: [keymapProvider.overrideWith((_) => keymap)],
    );
    addTearDown(container.dispose);
    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () => opened++,
      container: container,
    );

    await keymap.rebind(
      ShortcutAction.openSettings,
      const KeyChord(LogicalKeyboardKey.keyP, control: true),
    );
    await tester.pump();
    await pressCtrl(tester, LogicalKeyboardKey.keyP);
    expect(opened, 1);
  });

  testWidgets('Ctrl+1 / Ctrl+2 switch to the 1st / 2nd group', (tester) async {
    final keymap = await controller();
    final groups = GroupsController.ephemeral(
      GroupsState(
        groups: [
          Group.board(
            id: 'g1',
            label: 'One',
            tree: WorkspaceController.seedWorkspace(),
          ),
          Group.board(
            id: 'g2',
            label: 'Two',
            tree: WorkspaceController.seedWorkspace(),
          ),
        ],
        activeGroupId: 'g1',
      ),
    );
    final container = ProviderContainer(
      overrides: [
        keymapProvider.overrideWith((_) => keymap),
        groupsControllerProvider.overrideWith((_) => groups),
      ],
    );
    addTearDown(container.dispose);
    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () {},
      container: container,
    );

    await pressCtrl(tester, LogicalKeyboardKey.digit2);
    expect(container.read(groupsControllerProvider).activeGroupId, 'g2');
    await pressCtrl(tester, LogicalKeyboardKey.digit1);
    expect(container.read(groupsControllerProvider).activeGroupId, 'g1');
  });

  testWidgets('a tenth group has no shortcut — Ctrl+... never reaches it', (
    tester,
  ) async {
    // There is no digit-0 binding and no wrap-around, so with two groups
    // Ctrl+3 (a group that does not exist) is inert (decision 16).
    final keymap = await controller();
    final groups = GroupsController.ephemeral(
      GroupsState(
        groups: [
          Group.board(
            id: 'g1',
            label: 'One',
            tree: WorkspaceController.seedWorkspace(),
          ),
          Group.board(
            id: 'g2',
            label: 'Two',
            tree: WorkspaceController.seedWorkspace(),
          ),
        ],
        activeGroupId: 'g1',
      ),
    );
    final container = ProviderContainer(
      overrides: [
        keymapProvider.overrideWith((_) => keymap),
        groupsControllerProvider.overrideWith((_) => groups),
      ],
    );
    addTearDown(container.dispose);
    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () {},
      container: container,
    );

    await pressCtrl(tester, LogicalKeyboardKey.digit3);
    expect(
      container.read(groupsControllerProvider).activeGroupId,
      'g1',
      reason: 'no group 3 exists, so focus does not move',
    );
  });

  // SPEC-42 P2a, corrected: the desktop shell is a plain `MaterialApp` (only
  // mobile uses `MaterialApp.router`), so this shortcut must not depend on a
  // GoRouter being in context — it pushes on the shell's own Navigator.
  testWidgets('Ctrl+Shift+P opens the Ports screen on this Navigator', (
    tester,
  ) async {
    final keymap = await controller();
    final container = ProviderContainer(
      overrides: [
        keymapProvider.overrideWith((_) => keymap),
        portsWatchProvider.overrideWithValue(PortsWatch((_) {})),
        portsProvider.overrideWithValue(
          const PortsSnapshot(ports: [], scannedAt: 0, scanOk: true),
        ),
        reposProvider.overrideWithValue(ReposState(const [])),
        sessionsProvider.overrideWithValue(SessionsState(const [])),
      ],
    );
    addTearDown(container.dispose);
    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () {},
      container: container,
    );

    await pressCtrl(tester, LogicalKeyboardKey.keyP, shift: true);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PortsScreen), findsOneWidget);

    // Pressing it again does not stack a second copy.
    await pressCtrl(tester, LogicalKeyboardKey.keyP, shift: true);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PortsScreen), findsOneWidget);
  });
}
