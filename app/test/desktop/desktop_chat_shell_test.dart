import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_chat_shell.dart';
import 'package:makit/desktop/chat/desktop_sidebar.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
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
    // The 8px handle sits immediately right of the sidebar.
    const handleX = kSidebarDefaultWidth + 4;
    final handleY = tester.getSize(find.byType(DesktopChatShell)).height / 2;

    await tester.dragFrom(Offset(handleX, handleY), const Offset(50, 0));
    await tester.pump();
    expect(container.read(sidebarWidthProvider), kSidebarDefaultWidth + 50);

    await tester.dragFrom(
      Offset(kSidebarDefaultWidth + 50 + 4, handleY),
      const Offset(-500, 0),
    );
    await tester.pump();
    expect(container.read(sidebarWidthProvider), kSidebarMinWidth);

    await tester.dragFrom(
      Offset(kSidebarMinWidth + 4, handleY),
      const Offset(500, 0),
    );
    await tester.pump();
    expect(container.read(sidebarWidthProvider), kSidebarMaxWidth);
  });
}
