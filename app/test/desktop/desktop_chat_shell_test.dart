import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:makit/desktop/chat/desktop_chat_shell.dart';
import 'package:makit/desktop/chat/desktop_sidebar.dart';
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/desktop/chat/split_tree_view.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

/// Shell-level regression guard for SPEC-12: the sidebar folds away fully and
/// resizes within [kSidebarMinWidth]–[kSidebarMaxWidth] via the drag handle.
void main() {
  setUp(() {
    // DragToMoveArea (window_manager) issues platform-channel calls that have
    // no host in widget tests — stub them out.
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => null,
        );
  });

  Future<ProviderContainer> pumpShell(
    WidgetTester tester, {
    bool collapsed = false,
  }) async {
    final container = ProviderContainer(
      overrides: [
        reposProvider.overrideWithValue(
          ReposState([
            const RepoInfo(
              id: 'p1',
              name: 'alpha',
              path: '/tmp/p1',
              pinned: false,
              lastActivityAt: 0,
              isGitRepo: true,
              defaultBranch: 'main',
              currentBranch: 'main',
              worktrees: [],
            ),
          ]),
        ),
        sessionsProvider.overrideWithValue(SessionsState(const [])),
        sidebarCollapsedProvider.overrideWith((ref) => collapsed),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DesktopChatShell()),
      ),
    );
    return container;
  }

  testWidgets('renders sidebar at the default width', (tester) async {
    await pumpShell(tester);
    expect(find.byType(DesktopSidebar), findsOneWidget);
    expect(
      tester.getSize(find.byType(DesktopSidebar)).width,
      kSidebarDefaultWidth,
    );
  });

  testWidgets('collapsed shell hides the sidebar entirely', (tester) async {
    await pumpShell(tester, collapsed: true);
    expect(find.byType(DesktopSidebar), findsNothing);
  });

  testWidgets('exactly one fold control and one bell, in either state', (
    tester,
  ) async {
    // Activity is paired with the fold button at every site it appears, so this
    // pins the invariant that pairing relies on: the real shell never shows two
    // fold controls at once, in either state. If it ever does, the user sees two
    // bells and this fails first.
    await pumpShell(tester);
    expect(find.byTooltip('Hide sidebar'), findsOneWidget);
    expect(find.byTooltip('Show sidebar'), findsNothing);
    expect(find.byIcon(PhosphorIconsLight.bell), findsOneWidget);

    await pumpShell(tester, collapsed: true);
    expect(find.byTooltip('Hide sidebar'), findsNothing);
    expect(find.byTooltip('Show sidebar'), findsOneWidget);
    expect(find.byIcon(PhosphorIconsLight.bell), findsOneWidget);
  });

  testWidgets('fold and unfold roundtrip via the header buttons', (
    tester,
  ) async {
    await pumpShell(tester);

    await tester.tap(find.byTooltip('Hide sidebar'));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopSidebar), findsNothing);

    await tester.tap(find.byTooltip('Show sidebar'));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopSidebar), findsOneWidget);
  });

  testWidgets('drag handle resizes the sidebar and clamps to bounds', (
    tester,
  ) async {
    final container = await pumpShell(tester);
    // The 8px handle straddles the sidebar|pane seam, centred on the current
    // width.
    const handleX = kSidebarDefaultWidth;
    final handleY = tester.getSize(find.byType(DesktopChatShell)).height / 2;

    await tester.dragFrom(Offset(handleX, handleY), const Offset(50, 0));
    await tester.pump();
    expect(container.read(sidebarWidthProvider), kSidebarDefaultWidth + 50);

    await tester.dragFrom(
      Offset(kSidebarDefaultWidth + 50, handleY),
      const Offset(-500, 0),
    );
    await tester.pump();
    expect(container.read(sidebarWidthProvider), kSidebarMinWidth);

    await tester.dragFrom(
      Offset(kSidebarMinWidth, handleY),
      const Offset(500, 0),
    );
    await tester.pump();
    expect(container.read(sidebarWidthProvider), kSidebarMaxWidth);
  });

  testWidgets('drag handle resizes incrementally within bounds', (
    tester,
  ) async {
    final container = await pumpShell(tester);
    const handleX = kSidebarDefaultWidth;
    final handleY = tester.getSize(find.byType(DesktopChatShell)).height / 2;

    // Two small, in-bounds drags should accumulate additively rather than
    // overwrite each other.
    await tester.dragFrom(Offset(handleX, handleY), const Offset(20, 0));
    await tester.pump();
    expect(container.read(sidebarWidthProvider), kSidebarDefaultWidth + 20);

    await tester.dragFrom(
      Offset(kSidebarDefaultWidth + 20, handleY),
      const Offset(15, 0),
    );
    await tester.pump();
    expect(container.read(sidebarWidthProvider), kSidebarDefaultWidth + 35);
  });

  testWidgets('collapsed shell has no resize handle to drag', (tester) async {
    final container = await pumpShell(tester, collapsed: true);
    final size = tester.getSize(find.byType(DesktopChatShell));

    // With the sidebar gone, the pane occupies the full width; dragging near
    // where the handle used to sit must not touch the width provider.
    await tester.dragFrom(
      Offset(kSidebarDefaultWidth + 4, size.height / 2),
      const Offset(50, 0),
    );
    await tester.pump();

    expect(container.read(sidebarWidthProvider), kSidebarDefaultWidth);
  });

  testWidgets('dragging a sidebar session onto a pane opens it there', (
    tester,
  ) async {
    const model = ModelInfo(provider: 'openai', id: 'gpt-5', name: 'GPT-5');
    final session = Session(
      id: 's1',
      projectId: 'p1',
      agent: 'pi',
      title: 'Alpha',
      status: SessionStatus.idle,
      policy: ApprovalPolicy.askOnRisky,
      lastPreview: '',
      lastActivityAt: 0,
      worktreePath: '/tmp/wt-a',
      branch: 'wt-a',
    );
    final container = ProviderContainer(
      overrides: [
        reposProvider.overrideWithValue(
          ReposState([
            const RepoInfo(
              id: 'p1',
              name: 'proj',
              path: '/tmp/p1',
              pinned: false,
              lastActivityAt: 0,
              isGitRepo: true,
              defaultBranch: 'main',
              currentBranch: 'main',
              worktrees: [
                Worktree(
                  id: 'wt-a',
                  path: '/tmp/wt/wt-a',
                  branch: 'feat/x',
                  isPrimary: false,
                  insertions: 0,
                  deletions: 0,
                  filesChanged: 0,
                  sessionIds: ['s1'],
                ),
              ],
            ),
          ]),
        ),
        sessionsProvider.overrideWithValue(SessionsState([session])),
        eventsProvider.overrideWithValue(EventsState(const {}, const {})),
        sessionMetaProvider('s1').overrideWithValue(
          const SessionMeta(model: model, thinking: 'medium', models: [model]),
        ),
        sidebarCollapsedProvider.overrideWith((ref) => false),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DesktopChatShell()),
      ),
    );
    await tester.pumpAndSettle();

    // The session shows as a sidebar tile and is not yet open in any pane.
    expect(find.text('Alpha'), findsOneWidget);
    expect(
      findTab(container.read(workspaceControllerProvider).root, 's1'),
      isNull,
    );

    // Drag it rightward into the pane's body (horizontal affinity starts it).
    final start = tester.getCenter(find.text('Alpha'));
    final paneRect = tester.getRect(find.byType(WorkspaceView));
    final to = paneRect.center;
    final g = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 30));
    await g.moveTo(Offset((start.dx + to.dx) / 2, (start.dy + to.dy) / 2));
    await tester.pump(const Duration(milliseconds: 30));
    await g.moveTo(to);
    await tester.pump(const Duration(milliseconds: 30));
    await g.moveTo(to);
    await tester.pump(const Duration(milliseconds: 30));
    await g.up();
    await tester.pumpAndSettle();

    // The session is now hosted in the workspace (opened by the drop).
    expect(
      findTab(container.read(workspaceControllerProvider).root, 's1'),
      isNotNull,
    );
  });
}
