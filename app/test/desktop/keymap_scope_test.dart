import 'package:flutter/material.dart' hide Tab, Split;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/keymap_scope.dart';
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/shortcuts/key_chord.dart';
import 'package:makit/shortcuts/keymap_controller.dart';
import 'package:makit/shortcuts/shortcut_action.dart';
import 'package:makit/store/models.dart';
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

  testWidgets('Ctrl+D divides the active split into a splitter', (
    tester,
  ) async {
    final keymap = await controller();
    final container = ProviderContainer(
      overrides: [
        keymapProvider.overrideWith((_) => keymap),
        sessionsProvider.overrideWithValue(SessionsState(const [])),
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

    // The single split became a splitter with two splits; the new (active)
    // split holds an empty starter tab.
    expect(container.read(workspaceControllerProvider).root, isA<Splitter>());
    expect(container.read(selectedSessionProvider), isNull);
  });

  testWidgets('Ctrl+D carries the active session\'s worktree into the new split', (
    tester,
  ) async {
    // SPEC-30 decision 17: ⌘D must agree with the tab-strip +, which pre-fills
    // the worktree you are already working in.
    final keymap = await controller();
    final container = ProviderContainer(
      overrides: [
        keymapProvider.overrideWith((_) => keymap),
        sessionsProvider.overrideWithValue(SessionsState([session('s1')])),
      ],
    );
    addTearDown(container.dispose);
    workspace(container).revealSession('s1');

    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () {},
      container: container,
    );
    await pressCtrl(tester, LogicalKeyboardKey.keyD);

    final tab = activeTab(container.read(workspaceControllerProvider))!;
    expect(tab.sessionId, isNull, reason: 'a fresh starter tab');
    expect(tab.worktree?.path, '/tmp/wt-x');
    expect(tab.worktree?.branch, 'feature-x');
  });

  testWidgets('Ctrl+T opens the New session dialog', (tester) async {
    final keymap = await controller();
    final container = ProviderContainer(
      overrides: [
        keymapProvider.overrideWith((_) => keymap),
        sessionsProvider.overrideWithValue(SessionsState([session('s1')])),
        agentsProvider.overrideWith((ref) async => const <AgentDescriptor>[]),
      ],
    );
    addTearDown(container.dispose);
    workspace(container).revealSession('s1');

    await pumpScope(
      tester,
      keymap: keymap,
      onOpenSettings: () {},
      container: container,
    );

    await pressCtrl(tester, LogicalKeyboardKey.keyT);
    await tester.pumpAndSettle();

    // The dialog opened; the running session's tab is untouched.
    expect(find.text('New session'), findsOneWidget);
    expect(container.read(selectedSessionProvider), 's1');
  });

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
}
