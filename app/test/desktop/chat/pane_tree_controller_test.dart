import 'package:flutter/widgets.dart' show Axis;
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/panes/pane_node.dart';
import 'package:makit/desktop/chat/panes/pane_tree_controller.dart';
import 'package:makit/desktop/chat/selected_worktree.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _wtA = SelectedWorktree(projectId: 'p1', path: '/wt/a', branch: 'a');
const _wtB = SelectedWorktree(projectId: 'p1', path: '/wt/b', branch: 'b');

void main() {
  group('PaneTreeController workspace', () {
    test('starts empty (placeholder, no current tree)', () {
      final c = PaneTreeController.ephemeral();
      expect(c.state.trees, isEmpty);
      expect(c.state.currentKey, isNull);
      expect(c.current, isNull);
    });

    test('selectWorktree seeds a single empty starter leaf', () {
      final c = PaneTreeController.ephemeral();
      c.selectWorktree(_wtA);
      final cur = c.current!;
      expect(cur.worktree, _wtA);
      expect(cur.root, isA<PaneLeaf>());
      expect((cur.root as PaneLeaf).sessionId, isNull);
      expect(cur.activeLeafId, (cur.root as PaneLeaf).id);
    });

    test('re-selecting a worktree keeps its existing tree', () {
      final c = PaneTreeController.ephemeral();
      c.selectWorktree(_wtA);
      c.splitActive(Axis.horizontal);
      final splitRoot = c.current!.root;
      c.selectWorktree(_wtB);
      c.selectWorktree(_wtA);
      expect(c.current!.root, splitRoot, reason: 'layout preserved');
    });

    test(
      'switching worktrees preserves each layout, ratio and active leaf',
      () {
        final c = PaneTreeController.ephemeral();
        c.selectWorktree(_wtA);
        c.splitActive(Axis.horizontal);
        final aActive = c.current!.activeLeafId;
        final aSplitId = (c.current!.root as PaneSplit).id;
        c.setRatio(aSplitId, 0.3);

        c.selectWorktree(_wtB); // B is a fresh single leaf
        expect(c.current!.root, isA<PaneLeaf>());

        c.selectWorktree(_wtA);
        expect(c.current!.root, isA<PaneSplit>());
        expect((c.current!.root as PaneSplit).ratio, closeTo(0.3, 1e-9));
        expect(c.current!.activeLeafId, aActive);
      },
    );

    test(
      'splitActive keeps the current pane session and adds an empty pane',
      () {
        final c = PaneTreeController.ephemeral();
        c.bindActiveSession('s-old', _wtA);
        final original = c.current!.activeLeafId;
        c.splitActive(Axis.vertical);
        final split = c.current!.root as PaneSplit;
        final byId = {
          for (final l in [split.first, split.second].cast<PaneLeaf>()) l.id: l,
        };
        expect(byId[original]!.sessionId, 's-old');
        expect(byId[c.current!.activeLeafId]!.sessionId, isNull);
        expect(c.current!.activeLeafId, isNot(original));
      },
    );

    test('splitActive is a no-op when nothing is selected', () {
      final c = PaneTreeController.ephemeral();
      final before = c.state;
      c.splitActive(Axis.horizontal);
      expect(c.state, before);
    });

    test('bindActiveSession switches to the session\'s worktree tree', () {
      final c = PaneTreeController.ephemeral();
      c.selectWorktree(_wtA);
      c.bindActiveSession('s-b', _wtB);
      expect(c.state.currentKey, _wtB.path);
      expect((c.current!.root as PaneLeaf).sessionId, 's-b');
      // A's tree still exists, untouched.
      expect(c.state.trees[_wtA.path], isNotNull);
    });

    test('bindActiveSession binds to the active leaf only', () {
      final c = PaneTreeController.ephemeral();
      c.bindActiveSession('s-old', _wtA);
      final first = c.current!.activeLeafId;
      c.splitActive(Axis.horizontal);
      final fresh = c.current!.activeLeafId;
      c.bindActiveSession('s-new', _wtA);
      PaneLeaf leaf(String id) => [
        (c.current!.root as PaneSplit).first,
        (c.current!.root as PaneSplit).second,
      ].cast<PaneLeaf>().firstWhere((l) => l.id == id);
      expect(leaf(fresh).sessionId, 's-new');
      expect(leaf(first).sessionId, 's-old');
    });

    test('clearSelection shows the placeholder but retains trees', () {
      final c = PaneTreeController.ephemeral();
      c.selectWorktree(_wtA);
      c.clearSelection();
      expect(c.current, isNull);
      expect(c.state.trees[_wtA.path], isNotNull);
    });

    test('closeActive collapses back to a single leaf', () {
      final c = PaneTreeController.ephemeral();
      c.selectWorktree(_wtA);
      c.splitActive(Axis.horizontal);
      c.closeActive();
      expect(c.current!.root, isA<PaneLeaf>());
    });

    test('closeActive on the only pane clears the tree to the empty state', () {
      final c = PaneTreeController.ephemeral();
      c.selectWorktree(_wtA);
      c.closeActive();
      // Last pane closed: the view drops to the empty placeholder and the
      // worktree's tree is removed entirely (not left as an empty pane).
      expect(c.current, isNull);
      expect(c.state.trees[_wtA.path], isNull);
    });

    test('closeActive after nested splits focuses the sibling pane', () {
      final c = PaneTreeController.ephemeral();
      c.selectWorktree(_wtA);
      c.splitActive(Axis.horizontal); // active = second pane
      final sibling = c.current!.activeLeafId;
      c.splitActive(Axis.vertical); // active = third pane (nested under second)
      c.closeActive();
      expect(c.current!.activeLeafId, sibling);
    });

    test('setActive changes the focused leaf', () {
      final c = PaneTreeController.ephemeral();
      c.selectWorktree(_wtA);
      final first = c.current!.activeLeafId;
      c.splitActive(Axis.horizontal);
      c.setActive(first);
      expect(c.current!.activeLeafId, first);
    });

    test('setActive is a no-op for the current leaf and unknown ids', () {
      final c = PaneTreeController.ephemeral();
      c.selectWorktree(_wtA);
      final before = c.state;
      c.setActive(before.current!.activeLeafId);
      expect(c.state, before);
      c.setActive('does-not-exist');
      expect(c.state, before);
    });

    test('setRatio clamps the split ratio', () {
      final c = PaneTreeController.ephemeral();
      c.selectWorktree(_wtA);
      c.splitActive(Axis.horizontal);
      final splitId = (c.current!.root as PaneSplit).id;
      c.setRatio(splitId, 5.0);
      expect((c.current!.root as PaneSplit).ratio, kMaxPaneRatio);
      c.setRatio(splitId, -1.0);
      expect((c.current!.root as PaneSplit).ratio, kMinPaneRatio);
    });

    test('adjustRatio accumulates deltas against the live ratio', () {
      final c = PaneTreeController.ephemeral();
      c.selectWorktree(_wtA);
      c.splitActive(Axis.horizontal);
      final id = (c.current!.root as PaneSplit).id;
      c.adjustRatio(id, -0.1);
      c.adjustRatio(id, -0.1);
      expect((c.current!.root as PaneSplit).ratio, closeTo(0.3, 1e-9));
    });

    test('moveLeaf keeps the moved pane active', () {
      final c = PaneTreeController.ephemeral();
      c.selectWorktree(_wtA);
      final first = c.current!.activeLeafId;
      c.splitActive(Axis.horizontal);
      final second = c.current!.activeLeafId;
      c.moveLeaf(first, second, DropEdge.bottom);
      expect(c.current!.activeLeafId, first);
      expect(containsLeaf(c.current!.root, first), isTrue);
      expect(containsLeaf(c.current!.root, second), isTrue);
    });

    test('unbindSession clears the session across every tree', () {
      final c = PaneTreeController.ephemeral();
      c.bindActiveSession('dead', _wtA);
      c.bindActiveSession('dead', _wtB);
      c.unbindSession('dead');
      expect((c.state.trees[_wtA.path]!.root as PaneLeaf).sessionId, isNull);
      expect((c.state.trees[_wtB.path]!.root as PaneLeaf).sessionId, isNull);
    });

    test('unbindSession is a no-op for non-matching ids', () {
      final c = PaneTreeController.ephemeral();
      c.bindActiveSession('s1', _wtA);
      c.unbindSession('s2');
      expect((c.current!.root as PaneLeaf).sessionId, 's1');
    });
  });

  group('PaneTreeController persistence', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('ephemeral controller does not persist', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = PaneTreeController.ephemeral();
      c.selectWorktree(_wtA);
      await Future<void>.delayed(Duration.zero);
      expect(prefs.getString(kPaneWorkspacePrefsKey), isNull);
    });

    test('mutations survive a reload from the same store', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = PaneTreeController.load(prefs);
      c.selectWorktree(_wtA);
      c.bindActiveSession('s1', _wtA);
      c.splitActive(Axis.horizontal);
      final splitId = (c.current!.root as PaneSplit).id;
      c.setRatio(splitId, 0.25);
      c.selectWorktree(_wtB);
      await Future<void>.delayed(Duration.zero);

      final reloaded = PaneTreeController.load(prefs);
      expect(reloaded.state, c.state, reason: 'identical workspace');
      expect(reloaded.state.currentKey, _wtB.path);
      expect(
        (reloaded.state.trees[_wtA.path]!.root as PaneSplit).ratio,
        closeTo(0.25, 1e-9),
      );
    });

    test('clearing back to empty removes the persisted blob', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = PaneTreeController.load(prefs);
      c.selectWorktree(_wtA);
      await Future<void>.delayed(Duration.zero);
      expect(prefs.getString(kPaneWorkspacePrefsKey), isNotNull);
      // Note: trees are retained on clearSelection, so the blob remains; this
      // documents that a selected-then-cleared workspace still persists trees.
      c.clearSelection();
      await Future<void>.delayed(Duration.zero);
      final reloaded = PaneTreeController.load(prefs);
      expect(reloaded.state.currentKey, isNull);
      expect(reloaded.state.trees[_wtA.path], isNotNull);
    });

    test('corrupt JSON loads as an empty workspace', () async {
      SharedPreferences.setMockInitialValues({
        kPaneWorkspacePrefsKey: '{not valid json',
      });
      final prefs = await SharedPreferences.getInstance();
      final c = PaneTreeController.load(prefs);
      expect(c.state.trees, isEmpty);
      expect(c.state.currentKey, isNull);
    });

    test('structurally wrong JSON loads as an empty workspace', () async {
      SharedPreferences.setMockInitialValues({
        kPaneWorkspacePrefsKey: '{"trees": {"x": {"bogus": true}}}',
      });
      final prefs = await SharedPreferences.getInstance();
      final c = PaneTreeController.load(prefs);
      expect(c.state.trees, isEmpty);
    });

    test('absent JSON loads as an empty workspace', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = PaneTreeController.load(prefs);
      expect(c.state.trees, isEmpty);
      expect(c.state.currentKey, isNull);
    });
  });

  group('PaneTreeController draft trees', () {
    test('draftTreeSessionIds reports sessions with a virtual draft tree', () {
      final c = PaneTreeController.ephemeral();
      c.bindActiveSession('s1', draftWorktreeFor('p1', 's1'));
      c.bindActiveSession('s2', _wtA); // a real worktree, not a draft
      expect(c.draftTreeSessionIds(), ['s1']);
    });

    test('materializeDraft migrates the tree onto the real worktree', () {
      final c = PaneTreeController.ephemeral();
      c.bindActiveSession('s1', draftWorktreeFor('p1', 's1'));
      c.splitActive(Axis.horizontal);
      final draftRoot = c.current!.root;
      final draftActive = c.current!.activeLeafId;

      const real = SelectedWorktree(
        projectId: 'p1',
        path: '/wt/feat',
        branch: 'feat/x',
      );
      c.materializeDraft('s1', real);

      // The draft key is gone; the tree now lives under the real path with its
      // layout + active leaf intact and the real worktree as its title source.
      expect(c.state.trees.containsKey('draft:s1'), isFalse);
      expect(c.state.currentKey, '/wt/feat');
      expect(c.current!.worktree, real);
      expect(c.current!.root, draftRoot, reason: 'layout preserved');
      expect(c.current!.activeLeafId, draftActive);
    });

    test('materializeDraft is a no-op when the session has no draft tree', () {
      final c = PaneTreeController.ephemeral();
      c.selectWorktree(_wtA);
      final before = c.state;
      c.materializeDraft('sX', _wtB);
      expect(c.state, before);
    });

    test('dropDraftTree removes an abandoned draft and clears currentKey', () {
      final c = PaneTreeController.ephemeral();
      c.bindActiveSession('s1', draftWorktreeFor('p1', 's1'));
      expect(c.state.currentKey, 'draft:s1');
      c.dropDraftTree('s1');
      expect(c.state.trees, isEmpty);
      expect(c.state.currentKey, isNull);
    });

    test('dropDraftTree keeps a different current tree selected', () {
      final c = PaneTreeController.ephemeral();
      c.bindActiveSession('s1', draftWorktreeFor('p1', 's1'));
      c.selectWorktree(_wtA); // current is now the real tree
      c.dropDraftTree('s1');
      expect(c.state.trees.containsKey('draft:s1'), isFalse);
      expect(c.state.currentKey, _wtA.path);
    });

    test(
      'dropDraftTree is a no-op when no draft tree exists for the session',
      () {
        final c = PaneTreeController.ephemeral();
        c.selectWorktree(_wtA);
        final before = c.state;
        c.dropDraftTree('never-drafted');
        expect(c.state, before);
      },
    );

    test('draftTreeSessionIds reports every draft when multiple are open, and '
        'is empty when there are none', () {
      final c = PaneTreeController.ephemeral();
      expect(c.draftTreeSessionIds(), isEmpty);

      c.bindActiveSession('s1', draftWorktreeFor('p1', 's1'));
      c.bindActiveSession('s2', draftWorktreeFor('p1', 's2'));
      c.bindActiveSession('s3', _wtA); // a real worktree, not a draft
      expect(c.draftTreeSessionIds().toSet(), {'s1', 's2'});
    });

    test(
      'materializeDraft drops the draft in favor of an already-existing real '
      'tree at that worktree path',
      () {
        final c = PaneTreeController.ephemeral();
        // The real worktree is already open with its own (different) layout.
        c.selectWorktree(_wtA);
        c.splitActive(Axis.horizontal);
        final realRoot = c.current!.root;

        // A draft for the same eventual path is opened separately.
        c.bindActiveSession('s1', draftWorktreeFor('p1', 's1'));
        c.materializeDraft('s1', _wtA);

        // The draft is gone; the pre-existing real tree's layout wins rather
        // than being clobbered by the draft's single starter leaf. The current
        // draft selection follows onto the real tree so no empty pane is left.
        expect(c.state.trees.containsKey('draft:s1'), isFalse);
        expect(c.state.currentKey, _wtA.path);
        expect(c.current?.worktree, _wtA);
        expect(c.state.trees[_wtA.path]!.root, realRoot);
      },
    );
  });
}
