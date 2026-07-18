// Widget tests for WorktreeStartView's title-strip header removal: the
// branch-name row (fork icon + branch/path label) used to be baked into the
// view itself, but now lives on the window title strip (see
// pane_tree_view_test.dart for that), so WorktreeStartView must render only
// the harness-picker body below the plain unfold strip.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:makit/desktop/chat/harness_picker.dart';
import 'package:makit/desktop/chat/panes/pane_header.dart' show UnfoldStrip;
import 'package:makit/desktop/chat/selected_worktree.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

const _wt = SelectedWorktree(
  projectId: 'p1',
  path: '/tmp/wt-a',
  branch: 'feat/login',
);

Future<void> _pump(
  WidgetTester tester, {
  SelectedWorktree worktree = _wt,
  List<AgentDescriptor> agents = const [],
}) async {
  final container = ProviderContainer(
    overrides: [agentsProvider.overrideWith((ref) async => agents)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: WorktreeStartView(worktree: worktree)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'does not render a branch header row above the harness content',
    (tester) async {
      await _pump(tester);

      // The fork icon + branch label header was removed; the pane no longer
      // shows the branch anywhere in its own body (it now lives on the
      // window title strip, owned by PaneTreeView).
      expect(find.byIcon(Symbols.fork_right), findsNothing);
      expect(find.text('feat/login'), findsNothing);
    },
  );

  testWidgets('falls back to no path label either, for a detached worktree', (
    tester,
  ) async {
    await _pump(
      tester,
      worktree: const SelectedWorktree(
        projectId: 'p1',
        path: '/tmp/wt-detached',
        branch: null,
      ),
    );

    expect(find.text('/tmp/wt-detached'), findsNothing);
  });

  testWidgets('still renders the unfold strip at the top', (tester) async {
    await _pump(tester);
    expect(find.byType(UnfoldStrip), findsOneWidget);
  });

  testWidgets('still renders the harness cards below the (header-less) strip', (
    tester,
  ) async {
    await _pump(
      tester,
      agents: const [
        AgentDescriptor(
          id: 'codex',
          label: 'Codex',
          transport: 'stdio',
          available: true,
        ),
      ],
    );

    expect(find.text('Select your harness'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
  });
}