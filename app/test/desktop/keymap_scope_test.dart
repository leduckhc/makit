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
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory secure storage so ConnectionController boots without platform
/// channels (mirrors new_session_dialog_test).
class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

/// A store whose [spawnLinkedSession] records the source id and returns a fixed
/// id, so the split path can be driven without a live server.
class _FakeStore extends StoreController {
  _FakeStore(super.ref);
  final List<String> linkedFrom = [];
  @override
  Future<String> spawnLinkedSession(String sourceSessionId) async {
    linkedFrom.add(sourceSessionId);
    return 'linked-1';
  }
}

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
    'Ctrl+D splits into the current session\'s worktree (no New worktree dialog)',
    (tester) async {
      final keymap = await controller();
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
      container.read(selectedSessionProvider.notifier).state = 's1';

      await pumpScope(
        tester,
        keymap: keymap,
        onOpenSettings: () {},
        container: container,
      );

      await pressCtrl(tester, LogicalKeyboardKey.keyD);

      // The split lands on the current session's worktree (its harness picker),
      // not the eager "New worktree" dialog.
      expect(find.text('New worktree'), findsNothing);
      final wt = container.read(selectedWorktreeProvider);
      expect(wt, isNotNull);
      expect(wt!.projectId, 'p1');
      expect(wt.path, '/tmp/wt-x');
      expect(wt.branch, 'feature-x');
      // Selecting the worktree clears the session selection so the fresh pane
      // shows the worktree-start view instead of the old transcript.
      expect(container.read(selectedSessionProvider), isNull);
      // The pane actually split, and the old leaf stays pinned to s1 while the
      // fresh active leaf tracks the new worktree draft.
      final tree = container.read(paneTreeControllerProvider);
      expect(tree.root, isA<PaneSplit>());
      final controllerN = container.read(paneTreeControllerProvider.notifier);
      expect(controllerN.activeLeafSessionId, isNull);
    },
  );

  testWidgets(
    'Ctrl+D from an un-started draft spawns a linked session sharing its worktree',
    (tester) async {
      final keymap = await controller();
      final draft = Session(
        id: 'd1',
        projectId: 'p1',
        agent: 'pi',
        title: '',
        status: SessionStatus.idle,
        policy: ApprovalPolicy.askOnRisky,
        pending: true, // un-started draft: only a virtual worktree exists.
      );
      final container = ProviderContainer(
        overrides: [
          keymapProvider.overrideWith((_) => keymap),
          connectionControllerProvider.overrideWith(
            (ref) => ConnectionController(const _EmptyStorage()),
          ),
          sessionsProvider.overrideWithValue(SessionsState([draft])),
          storeControllerProvider.overrideWith((ref) => _FakeStore(ref)),
        ],
      );
      addTearDown(container.dispose);
      container.read(selectedSessionProvider.notifier).state = 'd1';

      await pumpScope(
        tester,
        keymap: keymap,
        onOpenSettings: () {},
        container: container,
      );

      await pressCtrl(tester, LogicalKeyboardKey.keyD);
      await tester.pump(); // let spawnLinkedSession resolve.

      // No dialog; the split linked a sibling draft off the current one and
      // selected it, so the fresh pane shows its harness picker.
      expect(find.text('New worktree'), findsNothing);
      final store = container.read(storeControllerProvider.notifier) as _FakeStore;
      expect(store.linkedFrom, ['d1']);
      expect(container.read(selectedSessionProvider), 'linked-1');
      expect(container.read(paneTreeControllerProvider).root, isA<PaneSplit>());
    },
  );

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
