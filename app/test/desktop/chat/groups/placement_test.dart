// SPEC-30 Lane 3 — placement policy (decision 9) and membership reconciliation.
//
// These are pure-tree tests: no widgets, no providers. The load-bearing
// invariant under test is decision 9's "nothing already on the canvas ever
// moves" — placing a new session, or reconciling membership, must leave every
// pre-existing pane byte-identical.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/groups/group.dart';
import 'package:makit/desktop/chat/groups/placement.dart';
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/selected_worktree.dart';

/// The number of session-hosting tabs anywhere in [state].
int _boundCount(WorkspaceState state) => boundSessionIds(state).length;

/// The number of leaf splits in [state].
int _splitCount(WorkspaceState state) {
  var n = 0;
  void walk(SplitNode node) {
    switch (node) {
      case Split():
        n++;
      case Splitter():
        walk(node.first);
        walk(node.second);
    }
  }

  walk(state.root);
  return n;
}

void main() {
  setUp(resetNodeIds);

  group('place (decision 9)', () {
    test('the first session fills the empty starter split (one split)', () {
      final placed = place(
        WorkspaceController.seedWorkspace(),
        's1',
        mode: LayoutMode.split,
      );
      expect(_splitCount(placed), 1);
      expect(boundSessionIds(placed), ['s1']);
    });

    test('with threshold 3 the 3rd session opens a NEW split', () {
      // Two sessions already shown, one per split.
      var tree = place(
        WorkspaceController.seedWorkspace(),
        's1',
        mode: LayoutMode.split,
      );
      tree = place(tree, 's2', mode: LayoutMode.split);
      expect(_splitCount(tree), 2);

      // 2 shown < 3 → the 3rd lands as its own split.
      final s1Split = firstSplitWhere<Split>(
        tree.root,
        (s) => s.tabs.any((t) => t.sessionId == 's1') ? s : null,
      );
      final placed = place(tree, 's3', mode: LayoutMode.split);
      expect(_splitCount(placed), 3);
      expect(boundSessionIds(placed).toSet(), {'s1', 's2', 's3'});

      // Decision 9's invariant: the split that was already there is untouched —
      // byte-identical, in its existing position.
      final s1SplitAfter = firstSplitWhere<Split>(
        placed.root,
        (s) => s.tabs.any((t) => t.sessionId == 's1') ? s : null,
      );
      expect(s1SplitAfter, s1Split);
    });

    test(
      'with threshold 3 the 4th session opens a TAB in the active split',
      () {
        var tree = place(
          WorkspaceController.seedWorkspace(),
          's1',
          mode: LayoutMode.split,
        );
        tree = place(tree, 's2', mode: LayoutMode.split);
        tree = place(tree, 's3', mode: LayoutMode.split);
        final splitsBefore = _splitCount(tree);

        // 3 shown ≥ 3 → the 4th joins the active split as a tab (no new split).
        final placed = place(tree, 's4', mode: LayoutMode.tabs);
        expect(_splitCount(placed), splitsBefore);
        expect(_boundCount(placed), 4);
      },
    );

    test('an unrelated placement leaves an existing split byte-identical', () {
      var tree = place(
        WorkspaceController.seedWorkspace(),
        's1',
        mode: LayoutMode.split,
      );
      tree = place(tree, 's2', mode: LayoutMode.split);
      // Capture the split that hosts s1 before an unrelated placement.
      final s1Split = firstSplitWhere<Split>(
        tree.root,
        (s) => s.tabs.any((t) => t.sessionId == 's1') ? s : null,
      );

      final placed = place(tree, 's3', mode: LayoutMode.tabs);
      final s1SplitAfter = firstSplitWhere<Split>(
        placed.root,
        (s) => s.tabs.any((t) => t.sessionId == 's1') ? s : null,
      );
      expect(s1SplitAfter, s1Split);
    });

    test('placing an already-shown session is a no-op (decision 3)', () {
      final tree = place(
        WorkspaceController.seedWorkspace(),
        's1',
        mode: LayoutMode.split,
      );
      final again = place(tree, 's1', mode: LayoutMode.split);
      expect(again, tree);
    });
  });

  group('reconcile (membership → tree)', () {
    test('a new member appears', () {
      final tree = place(
        WorkspaceController.seedWorkspace(),
        's1',
        mode: LayoutMode.split,
      );
      final next = reconcile(tree, ['s1', 's2'], threshold: 3);
      expect(boundSessionIds(next).toSet(), {'s1', 's2'});
    });

    test('a removed member\'s tab goes; the survivor does not move', () {
      var tree = place(
        WorkspaceController.seedWorkspace(),
        's1',
        mode: LayoutMode.split,
      );
      tree = place(tree, 's2', mode: LayoutMode.split);
      final s1Split = firstSplitWhere<Split>(
        tree.root,
        (s) => s.tabs.any((t) => t.sessionId == 's1') ? s : null,
      );

      // s2 is no longer a member: its tab (and its now-empty split) go, and s1
      // stays exactly where it was.
      final next = reconcile(tree, ['s1'], threshold: 3);
      expect(boundSessionIds(next), ['s1']);
      final s1SplitAfter = firstSplitWhere<Split>(
        next.root,
        (s) => s.tabs.any((t) => t.sessionId == 's1') ? s : null,
      );
      expect(s1SplitAfter, s1Split);
    });

    test('an empty worktree group seeds its tab with the scope hint '
        '(decision 20)', () {
      const hint = SelectedWorktree(
        projectId: 'p1',
        path: '/tmp/wt/feat-x',
        branch: 'feat/x',
      );
      final next = reconcile(
        WorkspaceController.seedWorkspace(),
        const [],
        threshold: 3,
        emptyHint: hint,
      );
      final tab = firstSplitWhere<Tab>(
        next.root,
        (s) => s.tabs.firstWhere((t) => t.id == s.activeTabId),
      );
      expect(tab?.sessionId, isNull);
      expect(
        tab?.worktree,
        hint,
        reason:
            'DesktopChatPane renders WorktreeStarter only when a hint is set',
      );
    });

    test('nothing is placed for an empty board (no hint)', () {
      final seed = WorkspaceController.seedWorkspace();
      final next = reconcile(seed, const [], threshold: 3);
      expect(next, seed);
    });

    test('an unlocated session keeps its tab — it is pending, not foreign', () {
      // Regression: the New-session dialog spawns a session and reveals its tab
      // before the server reports which worktree it landed in. Since it matches
      // no scope, reconcile used to drop that tab on the very next snapshot —
      // the tab flickered away and took the composer's text with it.
      final controller = WorkspaceController(
        null,
        WorkspaceController.seedWorkspace(),
      );
      placeInto(controller, 'pending', mode: LayoutMode.split);
      final withTab = controller.state;

      reconcileInto(
        controller,
        const [], // membership does not include it (no worktree yet)
        threshold: 3,
        unlocated: const {'pending'},
      );
      expect(controller.state, withTab, reason: 'left exactly as it was');

      // Once the server locates it elsewhere, it is a foreign tab and goes.
      reconcileInto(controller, const [], threshold: 3);
      expect(boundSessionIds(controller.state), isEmpty);
    });
  });

  group('relayout (decision 9 — the one sanctioned rearrange)', () {
    WorkspaceState fourInTabs() {
      final c = WorkspaceController(null, WorkspaceController.seedWorkspace());
      for (final id in ['s1', 's2', 's3', 's4']) {
        placeInto(c, id, mode: LayoutMode.tabs);
      }
      return c.state;
    }

    int splitCount(WorkspaceState s) => _splitCount(s);

    test('to split: 4 tabbed members become 4 panes, order preserved', () {
      final laid = relayout(fourInTabs(), LayoutMode.split);
      expect(splitCount(laid), 4);
      expect(boundSessionIds(laid), ['s1', 's2', 's3', 's4']);
    });

    test('to tabs: 4 split members collapse into one pane, order preserved', () {
      final c = WorkspaceController(null, WorkspaceController.seedWorkspace());
      for (final id in ['s1', 's2', 's3', 's4']) {
        placeInto(c, id, mode: LayoutMode.split);
      }
      expect(splitCount(c.state), 4);

      final laid = relayout(c.state, LayoutMode.tabs);
      expect(splitCount(laid), 1);
      expect(boundSessionIds(laid), ['s1', 's2', 's3', 's4']);
    });

    test('an empty tree is left untouched', () {
      final seed = WorkspaceController.seedWorkspace();
      expect(relayout(seed, LayoutMode.split), seed);
      expect(relayout(seed, LayoutMode.tabs), seed);
    });
  });
}
