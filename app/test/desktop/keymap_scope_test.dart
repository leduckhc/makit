import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/keymap_scope.dart';
import 'package:makit/desktop/chat/panes/pane_node.dart';
import 'package:makit/desktop/chat/panes/pane_tree_controller.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/shortcuts/key_chord.dart';
import 'package:makit/shortcuts/keymap_controller.dart';
import 'package:makit/shortcuts/shortcut_action.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Widget-level proof that [DesktopKeymapScope] turns a persisted [Keymap] into
/// live global shortcuts. Uses Ctrl-primary defaults (cmdIsPrimary: false) so
/// the combos are deterministic regardless of the test host platform.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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

  Future<void> pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(key);
    await tester.sendKeyUpEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

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

    // Simulate the user clicking an empty/non-focusable region: focus falls
    // back to the framework root scope, which sits above the keymap scope.
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

    // Clicking into the composer-like field must focus it and keep focus: the
    // idle-focus reclaim only pulls back empty scopes, never a real leaf.
    fieldFocus.requestFocus();
    await tester.pump();
    expect(fieldFocus.hasPrimaryFocus, isTrue);

    // Typing must reach the field (regression: focus was stolen on tap).
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
    "Ctrl+D splits the current worktree's tree into a fresh harness-picker pane",
    (tester) async {
      final keymap = await controller();
      const wt = SelectedWorktree(
        projectId: 'p1',
        path: '/tmp/wt-x',
        branch: 'feature-x',
      );
      final session = Session(
        id: 's1',
        projectId: 'p1',
        agent: 'pi',
        title: 'Wire up pairing',
        status: SessionStatus.idle,
        policy: ApprovalPolicy.askOnRisky,
        branch: 'feature-x',
        worktreePath: '/tmp/wt-x',
      );
      final container = ProviderContainer(
        overrides: [
          keymapProvider.overrideWith((_) => keymap),
          sessionsProvider.overrideWithValue(SessionsState([session])),
        ],
      );
      addTearDown(container.dispose);
      // Selecting the session binds it into its worktree's tree (current).
      container
          .read(paneTreeControllerProvider.notifier)
          .bindActiveSession('s1', wt);

      await pumpScope(
        tester,
        keymap: keymap,
        onOpenSettings: () {},
        container: container,
      );

      await pressCtrl(tester, LogicalKeyboardKey.keyD);

      // No eager "New worktree" dialog: each tree already owns its worktree.
      expect(find.text('New worktree'), findsNothing);
      final cur = container.read(paneTreeControllerProvider).current!;
      // The pane split within the SAME worktree, and the fresh active leaf is
      // empty (a null-session leaf → that worktree's harness picker).
      expect(cur.root, isA<PaneSplit>());
      expect(cur.worktree, wt);
      final controllerN = container.read(paneTreeControllerProvider.notifier);
      expect(controllerN.activeLeafSessionId, isNull);
    },
  );

  testWidgets('Ctrl+T resets the active pane to an empty harness-picker pane', (
    tester,
  ) async {
    final keymap = await controller();
    const wt = SelectedWorktree(
      projectId: 'p1',
      path: '/tmp/wt-t',
      branch: 'feature-t',
    );
    final session = Session(
      id: 's1',
      projectId: 'p1',
      agent: 'pi',
      title: 'Wire up pairing',
      status: SessionStatus.idle,
      policy: ApprovalPolicy.askOnRisky,
      branch: 'feature-t',
      worktreePath: '/tmp/wt-t',
    );
    final container = ProviderContainer(
      overrides: [
        keymapProvider.overrideWith((_) => keymap),
        sessionsProvider.overrideWithValue(SessionsState([session])),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(paneTreeControllerProvider.notifier)
        .bindActiveSession('s1', wt);
    container.read(selectedSessionProvider.notifier).state = 's1';

    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () {},
      container: container,
    );

    await pressCtrl(tester, LogicalKeyboardKey.keyT);

    final cur = container.read(paneTreeControllerProvider).current!;
    // No split: still a single leaf, now empty (harness picker), same
    // worktree. The session keeps running but the sidebar highlight clears.
    expect(cur.root, isA<PaneLeaf>());
    expect(cur.worktree, wt);
    expect(
      container.read(paneTreeControllerProvider.notifier).activeLeafSessionId,
      isNull,
    );
    expect(container.read(selectedSessionProvider), isNull);
  });

  testWidgets('Ctrl+W closes the active pane but keeps the session', (
    tester,
  ) async {
    final keymap = await controller();
    const wt = SelectedWorktree(
      projectId: 'p1',
      path: '/tmp/wt-w',
      branch: 'feature-w',
    );
    final session = Session(
      id: 's1',
      projectId: 'p1',
      agent: 'pi',
      title: 'Wire up pairing',
      status: SessionStatus.idle,
      policy: ApprovalPolicy.askOnRisky,
      branch: 'feature-w',
      worktreePath: '/tmp/wt-w',
    );
    final container = ProviderContainer(
      overrides: [
        keymapProvider.overrideWith((_) => keymap),
        sessionsProvider.overrideWithValue(SessionsState([session])),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(paneTreeControllerProvider.notifier);
    notifier.bindActiveSession('s1', wt);
    container.read(selectedSessionProvider.notifier).state = 's1';
    // Split so there are two panes; closing one leaves the sibling.
    notifier.splitActive(Axis.horizontal);

    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () {},
      container: container,
    );

    await pressCtrl(tester, LogicalKeyboardKey.keyW);

    // The active (empty) pane is gone; the sibling with the session remains.
    final cur = container.read(paneTreeControllerProvider).current!;
    expect(cur.root, isA<PaneLeaf>());
    expect((cur.root as PaneLeaf).sessionId, 's1');
    // The session was never deleted from the store.
    expect(container.read(sessionsProvider).byId('s1'), isNotNull);
  });

  testWidgets('Ctrl+D is a no-op when nothing is selected', (tester) async {
    final keymap = await controller();
    final container = ProviderContainer(
      overrides: [
        keymapProvider.overrideWith((_) => keymap),
        sessionsProvider.overrideWithValue(SessionsState(const [])),
      ],
    );
    addTearDown(container.dispose);
    final before = container.read(paneTreeControllerProvider);

    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () {},
      container: container,
    );
    await pressCtrl(tester, LogicalKeyboardKey.keyD);

    // No current tree → nothing to split, and no dialog.
    expect(find.text('New worktree'), findsNothing);
    expect(container.read(paneTreeControllerProvider), before);
    expect(container.read(paneTreeControllerProvider).current, isNull);
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

    // Rebind open-settings to Ctrl+P, then that combo should fire it.
    await keymap.rebind(
      ShortcutAction.openSettings,
      const KeyChord(LogicalKeyboardKey.keyP, control: true),
    );
    await tester.pump();
    await pressCtrl(tester, LogicalKeyboardKey.keyP);
    expect(opened, 1);
  });
}
