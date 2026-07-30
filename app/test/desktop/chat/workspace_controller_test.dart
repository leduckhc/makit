import 'dart:convert';

import 'package:flutter/widgets.dart' show Axis;
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/selected_worktree.dart';

/// The single active [Split] of a workspace.
Split activeSplit(WorkspaceController c) => firstSplitWhere(
  c.state.root,
  (s) => s.id == c.state.activeSplitId ? s : null,
)!;

/// The [Split] with [id], or null.
Split? splitById(WorkspaceController c, String id) =>
    firstSplitWhere(c.state.root, (s) => s.id == id ? s : null);

/// Every split id in the tree, left-to-right depth-first.
List<String> splitIds(SplitNode root) {
  final ids = <String>[];
  void walk(SplitNode n) {
    switch (n) {
      case Split():
        ids.add(n.id);
      case Splitter():
        walk(n.first);
        walk(n.second);
    }
  }

  walk(root);
  return ids;
}

/// Asserts the workspace invariant: [WorkspaceState.activeSplitId] references a
/// real [Split] and every live [Split] has at least one tab.
void expectIntegrity(WorkspaceController c) {
  expect(
    containsSplit(c.state.root, c.state.activeSplitId),
    isTrue,
    reason: 'activeSplitId must reference an existing split',
  );
  for (final id in splitIds(c.state.root)) {
    expect(
      splitById(c, id)!.tabs,
      isNotEmpty,
      reason: 'a live split has >=1 tab',
    );
  }
}

void main() {
  setUp(resetNodeIds);

  group('WorkspaceController fresh state', () {
    test('ephemeral starts as a single empty starter split + tab', () {
      final c = WorkspaceController.ephemeral();
      final root = c.state.root;
      expect(root, isA<Split>());
      final split = root as Split;
      expect(split.tabs, hasLength(1));
      expect(split.tabs.single.sessionId, isNull);
      expect(split.activeTabId, split.tabs.single.id);
      expect(c.state.activeSplitId, split.id);
      expectIntegrity(c);
    });
  });

  group('WorkspaceController splits', () {
    test('divideActive seeds a starter tab and activates the new split', () {
      final c = WorkspaceController.ephemeral();
      final original = c.state.activeSplitId;
      c.divideActive(Axis.horizontal);

      final root = c.state.root as Splitter;
      expect(root.axis, Axis.horizontal);
      final ids = splitIds(root);
      expect(ids, hasLength(2));
      // The new (active) split is fresh, holds one empty starter tab.
      final active = activeSplit(c);
      expect(active.id, isNot(original));
      expect(active.tabs, hasLength(1));
      expect(active.tabs.single.sessionId, isNull);
      expect(active.activeTabId, active.tabs.single.id);
      expectIntegrity(c);
    });

    test('divideActive carries a worktree hint onto the new starter tab', () {
      // SPEC-30 decision 17: splitting a pane must not lose where you were, so
      // the caller (which knows the active tab's session/worktree) hands the
      // hint down and the new tab lands on the in-pane starter for that branch
      // instead of the no-worktree placeholder.
      const wt = SelectedWorktree(
        projectId: 'p1',
        path: '/tmp/wt/feat-x',
        branch: 'feat/x',
      );
      final c = WorkspaceController.ephemeral();
      c.divideActive(Axis.horizontal, worktree: wt);

      final tab = activeSplit(c).tabs.single;
      expect(tab.sessionId, isNull);
      expect(tab.worktree, wt);
      expectIntegrity(c);
    });

    test('divideActive without a hint still seeds a bare tab', () {
      final c = WorkspaceController.ephemeral();
      c.divideActive(Axis.vertical);
      expect(activeSplit(c).tabs.single.worktree, isNull);
    });

    test('closeActiveSplit collapses back to the surviving sibling', () {
      final c = WorkspaceController.ephemeral();
      final original = c.state.activeSplitId;
      c.divideActive(Axis.vertical);
      c.closeActiveSplit();
      expect(c.state.root, isA<Split>());
      expect(c.state.activeSplitId, original, reason: 'sibling becomes active');
      expectIntegrity(c);
    });

    test('closeActiveSplit is a no-op on the sole split', () {
      final c = WorkspaceController.ephemeral();
      final before = c.state;
      c.closeActiveSplit();
      expect(c.state, before);
      expectIntegrity(c);
    });

    test('closeActiveSplit after nested splits focuses the sibling', () {
      final c = WorkspaceController.ephemeral();
      c.divideActive(Axis.horizontal); // active = second split
      final sibling = c.state.activeSplitId;
      c.divideActive(Axis.vertical); // active = third split, nested in second
      c.closeActiveSplit();
      expect(c.state.activeSplitId, sibling);
      expectIntegrity(c);
    });

    test('setActiveSplit focuses another split; no-op for same/unknown', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.divideActive(Axis.horizontal);
      c.setActiveSplit(first);
      expect(c.state.activeSplitId, first);
      final before = c.state;
      c.setActiveSplit(first);
      expect(c.state, before);
      c.setActiveSplit('does-not-exist');
      expect(c.state, before);
      expectIntegrity(c);
    });

    test('setRatio clamps and adjustRatio accumulates', () {
      final c = WorkspaceController.ephemeral();
      c.divideActive(Axis.horizontal);
      final splitterId = (c.state.root as Splitter).id;
      c.setRatio(splitterId, 5.0);
      expect((c.state.root as Splitter).ratio, kMaxPaneRatio);
      c.setRatio(splitterId, -1.0);
      expect((c.state.root as Splitter).ratio, kMinPaneRatio);
      c.setRatio(splitterId, 0.5);
      c.adjustRatio(splitterId, -0.1);
      c.adjustRatio(splitterId, -0.1);
      expect((c.state.root as Splitter).ratio, closeTo(0.3, 1e-9));
      expectIntegrity(c);
    });

    test('moveSplit re-docks a split and keeps it active', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.divideActive(Axis.horizontal);
      final second = c.state.activeSplitId;
      c.moveSplit(first, second, DropEdge.bottom);
      expect(containsSplit(c.state.root, first), isTrue);
      expect(containsSplit(c.state.root, second), isTrue);
      expect(c.state.activeSplitId, first, reason: 'moved split stays active');
      expectIntegrity(c);
    });
  });

  group('WorkspaceController tabs', () {
    test('openTab appends and activates a tab', () {
      final c = WorkspaceController.ephemeral();
      final splitId = c.state.activeSplitId;
      c.openTab(splitId, const Tab(id: 't-x', sessionId: 's-1'));
      final split = splitById(c, splitId)!;
      expect(split.tabs, hasLength(2));
      expect(split.activeTabId, 't-x');
      expectIntegrity(c);
    });

    test('openTab dedupes a session already hosted elsewhere (decision 5)', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.openTab(first, const Tab(id: 't-1', sessionId: 's-1'));
      c.divideActive(Axis.horizontal); // active = second split
      final second = c.state.activeSplitId;
      // Attempt to open the same session in the second split.
      c.openTab(second, const Tab(id: 't-dup', sessionId: 's-1'));
      // It is not duplicated; instead its existing tab is revealed.
      expect(findTab(c.state.root, 's-1'), (first, 't-1'));
      expect(
        splitById(c, second)!.tabs.any((t) => t.sessionId == 's-1'),
        isFalse,
      );
      expect(c.state.activeSplitId, first, reason: 'existing tab is revealed');
      expectIntegrity(c);
    });

    test('setActiveTab switches the active tab', () {
      final c = WorkspaceController.ephemeral();
      final splitId = c.state.activeSplitId;
      final starter = activeSplit(c).activeTabId;
      c.openTab(splitId, const Tab(id: 't-x', sessionId: 's-1'));
      c.setActiveTab(splitId, starter);
      expect(splitById(c, splitId)!.activeTabId, starter);
      expectIntegrity(c);
    });

    test('closeTab removes a tab but keeps a non-empty split', () {
      final c = WorkspaceController.ephemeral();
      final splitId = c.state.activeSplitId;
      c.openTab(splitId, const Tab(id: 't-x', sessionId: 's-1'));
      c.closeTab(splitId, 't-x');
      final split = splitById(c, splitId)!;
      expect(split.tabs, hasLength(1));
      expect(split.tabs.any((t) => t.id == 't-x'), isFalse);
      expectIntegrity(c);
    });

    test(
      'closeTab on the last tab of the sole split resets to a starter tab',
      () {
        final c = WorkspaceController.ephemeral();
        final splitId = c.state.activeSplitId;
        final onlyTab = activeSplit(c).activeTabId;
        c.closeTab(splitId, onlyTab);
        // The sole split can never fully close: it resets to one empty tab.
        expect(c.state.root, isA<Split>());
        final split = c.state.root as Split;
        expect(split.tabs, hasLength(1));
        expect(split.tabs.single.sessionId, isNull);
        expect(
          split.tabs.single.id,
          isNot(onlyTab),
          reason: 'fresh starter tab',
        );
        expect(c.state.activeSplitId, split.id);
        expectIntegrity(c);
      },
    );

    test('closeTab on the last tab of a non-sole split collapses it', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.divideActive(Axis.horizontal); // active = second split
      final second = c.state.activeSplitId;
      final secondTab = activeSplit(c).activeTabId;
      c.closeTab(second, secondTab);
      expect(c.state.root, isA<Split>(), reason: 'collapsed to sibling');
      expect(containsSplit(c.state.root, second), isFalse);
      expect(c.state.activeSplitId, first);
      expectIntegrity(c);
    });

    test('closeTab in a non-active split keeps the active split focused', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.openTab(first, const Tab(id: 't-a', sessionId: 's-a'));
      c.divideActive(Axis.horizontal); // active = second split
      final second = c.state.activeSplitId;
      c.closeTab(first, 't-a'); // first stays alive (still has its starter tab)
      expect(c.state.activeSplitId, second, reason: 'active split unchanged');
      expectIntegrity(c);
    });
  });

  group('WorkspaceController moveTab', () {
    test('moveTab between splits moves the tab and activates the target', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.openTab(first, const Tab(id: 't-a', sessionId: 's-a'));
      c.divideActive(Axis.horizontal);
      final second = c.state.activeSplitId;
      c.moveTab(first, 't-a', second, 0);
      expect(splitById(c, first)!.tabs.any((t) => t.id == 't-a'), isFalse);
      expect(splitById(c, second)!.tabs.first.id, 't-a');
      expect(splitById(c, second)!.activeTabId, 't-a');
      expect(c.state.activeSplitId, second);
      expectIntegrity(c);
    });

    test('moveTab reorders within the same split', () {
      final c = WorkspaceController.ephemeral();
      final splitId = c.state.activeSplitId;
      c.openTab(splitId, const Tab(id: 't-a', sessionId: 's-a'));
      c.openTab(splitId, const Tab(id: 't-b', sessionId: 's-b'));
      // starter, t-a, t-b → move t-b to front.
      c.moveTab(splitId, 't-b', splitId, 0);
      expect(splitById(c, splitId)!.tabs.first.id, 't-b');
      expectIntegrity(c);
    });

    test('moveTab that empties the source split collapses it', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.divideActive(Axis.horizontal); // active = second, holds a starter tab
      final second = c.state.activeSplitId;
      final secondTab = activeSplit(c).activeTabId;
      c.moveTab(second, secondTab, first, 0);
      // The emptied second split collapses; the tree is a single split again.
      expect(c.state.root, isA<Split>());
      expect(containsSplit(c.state.root, second), isFalse);
      expect(splitById(c, first)!.tabs.any((t) => t.id == secondTab), isTrue);
      expect(c.state.activeSplitId, first);
      expectIntegrity(c);
    });
  });

  group('WorkspaceController moveTabToEdge', () {
    test('detaches a tab into a new split docked at the target edge', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.openTab(first, const Tab(id: 't-a', sessionId: 's-a'));
      c.divideActive(Axis.horizontal);
      final second = c.state.activeSplitId;
      c.moveTabToEdge(first, 't-a', second, DropEdge.right);
      final newId = c.state.activeSplitId;
      expect(newId, isNot(first));
      expect(newId, isNot(second));
      expect(splitById(c, newId)!.tabs.single.id, 't-a');
      expect(splitById(c, first)!.tabs.any((t) => t.id == 't-a'), isFalse);
      expect(containsSplit(c.state.root, second), isTrue);
      expect(c.state.root, isA<Splitter>());
      expectIntegrity(c);
    });

    test('collapses the source split when the moved tab empties it', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.divideActive(Axis.horizontal);
      final second = c.state.activeSplitId;
      final secondTab = activeSplit(c).activeTabId;
      c.moveTabToEdge(second, secondTab, first, DropEdge.bottom);
      expect(containsSplit(c.state.root, second), isFalse);
      final newId = c.state.activeSplitId;
      expect(splitById(c, newId)!.tabs.single.id, secondTab);
      expect(containsSplit(c.state.root, first), isTrue);
      expectIntegrity(c);
    });

    test('detaches a tab onto its own split edge into a sibling', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.openTab(first, const Tab(id: 't-a', sessionId: 's-a'));
      c.moveTabToEdge(first, 't-a', first, DropEdge.right);
      expect(splitById(c, first)!.tabs.any((t) => t.id == 't-a'), isFalse);
      final newId = c.state.activeSplitId;
      expect(newId, isNot(first));
      expect(splitById(c, newId)!.tabs.single.id, 't-a');
      expect(c.state.root, isA<Splitter>());
      expectIntegrity(c);
    });

    test('is a no-op moving the sole tab onto its own split edge', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      final tab = activeSplit(c).activeTabId;
      final before = c.state.root;
      c.moveTabToEdge(first, tab, first, DropEdge.left);
      expect(c.state.root, before);
      expect(splitIds(c.state.root), [first]);
      expectIntegrity(c);
    });
  });

  group('WorkspaceController openSession* (sidebar drop)', () {
    test('openSessionInSplit opens a new tab for an unopened session', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.openSessionInSplit(first, 's-1');
      expect(findTab(c.state.root, 's-1')?.$1, first);
      expect(activeSplit(c).tabs.any((t) => t.sessionId == 's-1'), isTrue);
      expectIntegrity(c);
    });

    test(
      'openSessionInSplit moves an already-open session into the target',
      () {
        final c = WorkspaceController.ephemeral();
        final first = c.state.activeSplitId;
        c.openTab(first, const Tab(id: 't-1', sessionId: 's-1'));
        c.divideActive(Axis.horizontal);
        final second = c.state.activeSplitId;
        c.openSessionInSplit(second, 's-1');
        expect(findTab(c.state.root, 's-1')?.$1, second);
        // Not duplicated: it exists in exactly one split.
        expect(
          splitById(c, first)!.tabs.any((t) => t.sessionId == 's-1'),
          isFalse,
        );
        expectIntegrity(c);
      },
    );

    test('openSessionInSplit just activates when already in the target', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.openTab(first, const Tab(id: 't-1', sessionId: 's-1'));
      c.openTab(first, const Tab(id: 't-2', sessionId: 's-2'));
      c.openSessionInSplit(first, 's-1');
      expect(splitById(c, first)!.activeTabId, 't-1');
      expect(
        splitById(c, first)!.tabs.where((t) => t.sessionId == 's-1').length,
        1,
      );
      expectIntegrity(c);
    });

    test('openSessionInSplit focuses the target split when already there', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.openTab(first, const Tab(id: 't-1', sessionId: 's-1'));
      c.divideActive(Axis.horizontal); // second split becomes active
      final second = c.state.activeSplitId;
      // s-1 lives in `first`; dropping it onto `first` must refocus `first`,
      // not leave `second` active.
      c.openSessionInSplit(first, 's-1');
      expect(c.state.activeSplitId, first);
      expect(c.state.activeSplitId, isNot(second));
      expect(splitById(c, first)!.activeTabId, 't-1');
      expectIntegrity(c);
    });

    test('openSessionAtEdge opens an unopened session in a new split', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.openSessionAtEdge(first, 's-1', DropEdge.right);
      final newId = c.state.activeSplitId;
      expect(newId, isNot(first));
      expect(splitById(c, newId)!.tabs.single.sessionId, 's-1');
      expect(c.state.root, isA<Splitter>());
      expectIntegrity(c);
    });

    test(
      'openSessionAtEdge relocates an already-open session to a new split',
      () {
        final c = WorkspaceController.ephemeral();
        final first = c.state.activeSplitId;
        c.openTab(first, const Tab(id: 't-1', sessionId: 's-1'));
        c.openSessionAtEdge(first, 's-1', DropEdge.bottom);
        final newId = c.state.activeSplitId;
        expect(newId, isNot(first));
        expect(findTab(c.state.root, 's-1')?.$1, newId);
        expect(
          splitById(c, first)!.tabs.any((t) => t.sessionId == 's-1'),
          isFalse,
        );
        expectIntegrity(c);
      },
    );
  });

  group('WorkspaceController revealSession', () {
    test('revealSession focuses an existing tab without duplicating', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.openTab(first, const Tab(id: 't-1', sessionId: 's-1'));
      c.divideActive(Axis.horizontal); // active = second split
      c.revealSession('s-1');
      expect(c.state.activeSplitId, first);
      expect(splitById(c, first)!.activeTabId, 't-1');
      // No duplicate anywhere.
      expect(findTab(c.state.root, 's-1'), (first, 't-1'));
      expectIntegrity(c);
    });

    test('revealSession opens a new tab in the active split when unhosted', () {
      final c = WorkspaceController.ephemeral();
      c.divideActive(Axis.horizontal);
      final active = c.state.activeSplitId;
      c.revealSession('s-new');
      final located = findTab(c.state.root, 's-new');
      expect(located, isNotNull);
      expect(located!.$1, active, reason: 'opened in the active split');
      expect(splitById(c, active)!.activeTabId, located.$2);
      expectIntegrity(c);
    });
  });

  group('WorkspaceController revealWorktree', () {
    const wt = SelectedWorktree(
      projectId: 'p1',
      path: '/tmp/wt-a',
      branch: 'feat/a',
    );

    test('reuses the active empty placeholder instead of stacking tabs', () {
      final c = WorkspaceController.ephemeral();
      final split = c.state.activeSplitId;
      final starter = activeSplit(c).activeTabId;
      c.revealWorktree(wt);
      c.revealWorktree(wt); // second click must not add another placeholder
      final tabs = splitById(c, split)!.tabs;
      expect(tabs, hasLength(1), reason: 'no stacked "New" tabs');
      expect(tabs.single.id, starter, reason: 'reused the starter tab');
      expect(tabs.single.worktree?.path, '/tmp/wt-a');
      expect(tabs.single.sessionId, isNull);
      expectIntegrity(c);
    });

    test('opens a new hinted tab when the active tab hosts a session', () {
      final c = WorkspaceController.ephemeral();
      final split = c.state.activeSplitId;
      c.revealSession('s-1'); // fills the placeholder with a session
      c.revealWorktree(wt); // active tab now hosts s-1 → append a hinted tab
      final tabs = splitById(c, split)!.tabs;
      expect(tabs, hasLength(2));
      expect(tabs.last.worktree?.path, '/tmp/wt-a');
      expect(tabs.last.sessionId, isNull);
      expectIntegrity(c);
    });
  });

  group('WorkspaceController unbindSession', () {
    test('unbindSession removes a session tab wherever it lives', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.openTab(first, const Tab(id: 't-1', sessionId: 's-1'));
      c.unbindSession('s-1');
      expect(findTab(c.state.root, 's-1'), isNull);
      expectIntegrity(c);
    });

    test('unbindSession collapses a split it empties', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      c.divideActive(Axis.horizontal); // active = second split
      final second = c.state.activeSplitId;
      // Bind the whole second split's only tab to a session, then unbind it.
      final secondTab = activeSplit(c).activeTabId;
      c.openTab(second, const Tab(id: 't-s', sessionId: 's-x'));
      c.closeTab(second, secondTab); // now second hosts only s-x
      c.unbindSession('s-x');
      expect(containsSplit(c.state.root, second), isFalse);
      expect(c.state.activeSplitId, first);
      expectIntegrity(c);
    });

    test('unbindSession is a no-op for an unknown session', () {
      final c = WorkspaceController.ephemeral();
      final before = c.state;
      c.unbindSession('nope');
      expect(c.state, before);
      expectIntegrity(c);
    });
  });

  group('WorkspaceController cross-worktree coexistence', () {
    test('tabs bound to sessions from different worktrees share one tree', () {
      final c = WorkspaceController.ephemeral();
      final first = c.state.activeSplitId;
      // Two sessions that (conceptually) belong to different worktrees.
      c.openTab(first, const Tab(id: 't-wa', sessionId: 's-worktree-a'));
      c.divideActive(Axis.vertical);
      final second = c.state.activeSplitId;
      c.openTab(second, const Tab(id: 't-wb', sessionId: 's-worktree-b'));
      // Both coexist in a single workspace tree; no worktree is stored on tabs.
      expect(findTab(c.state.root, 's-worktree-a'), (first, 't-wa'));
      expect(findTab(c.state.root, 's-worktree-b'), (second, 't-wb'));
      expectIntegrity(c);
    });
  });

  // SPEC-30 Lane 2: this controller no longer owns storage — it reports every
  // mutation through a commit sink and the groups layer writes it. What used to
  // be the "persistence" group therefore splits in two: the sink contract, and
  // the decoder that the groups migration reuses to read a legacy blob.
  group('WorkspaceController commit sink', () {
    test('a null sink makes the controller ephemeral', () {
      final c = WorkspaceController.ephemeral();
      c.divideActive(Axis.horizontal); // must not throw
      expect(c.state.root, isA<Splitter>());
    });

    test('every mutation is reported, with the whole workspace', () {
      final seen = <WorkspaceState>[];
      final c = WorkspaceController(
        seen.add,
        WorkspaceController.seedWorkspace(),
      );
      final first = c.state.activeSplitId;
      c.openTab(first, const Tab(id: 't-1', sessionId: 's-1'));
      c.divideActive(Axis.horizontal);
      c.setRatio((c.state.root as Splitter).id, 0.25);

      expect(seen, hasLength(3));
      expect(seen.last, c.state, reason: 'the sink sees the committed state');
      expect((seen.last.root as Splitter).ratio, closeTo(0.25, 1e-9));
    });

    test('a throwing sink cannot take the mutation (or the app) down', () {
      // The old _persist swallowed write failures; that guarantee is part of
      // the sink contract now.
      final c = WorkspaceController(
        (_) => throw StateError('disk full'),
        WorkspaceController.seedWorkspace(),
      );
      c.divideActive(Axis.horizontal);
      expect(c.state.root, isA<Splitter>(), reason: 'the tree still mutated');
    });

    test('reads (not mutations) never touch the sink', () {
      var calls = 0;
      final c = WorkspaceController(
        (_) => calls++,
        WorkspaceController.seedWorkspace(),
      );
      c.setActiveSplit(c.state.activeSplitId); // already active → no-op
      expect(calls, 0);
    });
  });

  group('WorkspaceController.decodeWorkspace', () {
    test('corrupt JSON falls back to the starter workspace', () {
      final state = WorkspaceController.decodeWorkspace('{not valid json');
      expect(state.root, isA<Split>());
      expect((state.root as Split).tabs.single.sessionId, isNull);
    });

    test('structurally wrong JSON falls back to the starter workspace', () {
      final state = WorkspaceController.decodeWorkspace(
        '{"root": {"k": "bogus"}}',
      );
      expect(state.root, isA<Split>());
    });

    test('absent JSON yields the starter workspace', () {
      expect(WorkspaceController.decodeWorkspace(null).root, isA<Split>());
      expect(WorkspaceController.decodeWorkspace('').root, isA<Split>());
    });

    test('a round-trip restores the exact workspace', () {
      final c = WorkspaceController.ephemeral();
      c.openTab(c.state.activeSplitId, const Tab(id: 't-1', sessionId: 's-1'));
      c.divideActive(Axis.horizontal);
      c.setRatio((c.state.root as Splitter).id, 0.25);

      final back = WorkspaceController.decodeWorkspace(
        jsonEncode(c.state.toJson()),
      );
      expect(back, c.state);
    });

    test('ids minted after a decode never collide with restored ids', () {
      final c1 = WorkspaceController.ephemeral();
      c1.divideActive(Axis.horizontal);
      final blob = jsonEncode(c1.state.toJson());

      // Simulate a fresh process: counters restart while the blob still holds
      // split-0/tab-0/…
      resetNodeIds();
      final c2 = WorkspaceController(
        null,
        WorkspaceController.decodeWorkspace(blob),
      );
      c2.divideActive(Axis.horizontal);
      c2.divideActive(Axis.vertical);

      final ids = <String>[];
      void walk(SplitNode n) {
        switch (n) {
          case Split():
            ids
              ..add(n.id)
              ..addAll(n.tabs.map((t) => t.id));
          case Splitter():
            ids.add(n.id);
            walk(n.first);
            walk(n.second);
        }
      }

      walk(c2.state.root);
      expect(ids.toSet().length, ids.length, reason: 'all node ids are unique');
      expectIntegrity(c2);
    });

    test('a stale activeSplitId decodes to the first split', () {
      const tree = Split(
        id: 'split-0',
        tabs: [Tab(id: 'tab-0')],
        activeTabId: 'tab-0',
      );
      final state = WorkspaceController.decodeWorkspace(
        jsonEncode({
          'root': tree.toJson(),
          'activeSplitId': 'ghost-split', // references a non-existent split
        }),
      );
      expect(state.activeSplitId, 'split-0');
    });
  });
}
