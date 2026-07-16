import 'package:flutter/widgets.dart' show Axis;
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/panes/pane_node.dart';
import 'package:makit/desktop/chat/panes/pane_tree_controller.dart';

void main() {
  group('PaneTreeController', () {
    test('seeds a single active leaf', () {
      final c = PaneTreeController();
      expect(c.state.root, isA<PaneLeaf>());
      expect(c.state.activeLeafId, (c.state.root as PaneLeaf).id);
    });

    test('splitActive splits the active pane and activates the new leaf', () {
      final c = PaneTreeController();
      final original = c.state.activeLeafId;
      c.splitActive(Axis.horizontal);
      expect(c.state.root, isA<PaneSplit>());
      final split = c.state.root as PaneSplit;
      expect(split.axis, Axis.horizontal);
      expect(c.state.activeLeafId, isNot(original));
      expect(containsLeaf(c.state.root, original), isTrue);
    });

    test('splitActive pins the current pane and adds a fresh empty pane', () {
      final c = PaneTreeController();
      final original = c.state.activeLeafId;
      c.splitActive(Axis.vertical, pinnedSessionId: 's-old');
      final split = c.state.root as PaneSplit;
      final byId = {
        for (final l in [split.first, split.second].cast<PaneLeaf>()) l.id: l,
      };
      // The original pane keeps (is pinned to) its session…
      expect(byId[original]!.sessionId, 's-old');
      // …and the new active pane is empty (tracks the global selection).
      expect(byId[c.state.activeLeafId]!.sessionId, isNull);
      expect(c.state.activeLeafId, isNot(original));
    });

    test('closeActive collapses back to a single leaf', () {
      final c = PaneTreeController();
      c.splitActive(Axis.horizontal);
      c.closeActive();
      expect(c.state.root, isA<PaneLeaf>());
    });

    test('closeActive is a no-op with a single pane', () {
      final c = PaneTreeController();
      final before = c.state;
      c.closeActive();
      expect(c.state, before);
    });

    test('closeActive after nested splits focuses the sibling pane', () {
      final c = PaneTreeController();
      c.splitActive(Axis.horizontal); // active = second pane
      final sibling = c.state.activeLeafId;
      c.splitActive(Axis.vertical); // active = third pane (nested under second)
      expect(c.state.root, isA<PaneSplit>());
      final activeBeforeClose = c.state.activeLeafId;
      c.closeActive();
      // The active (deepest) pane is gone …
      expect(containsLeaf(c.state.root, activeBeforeClose), isFalse);
      // … and its sibling (not the far-left leaf) becomes active.
      expect(c.state.activeLeafId, sibling);
    });

    test('setActive changes the focused leaf', () {
      final c = PaneTreeController();
      final first = c.state.activeLeafId;
      c.splitActive(Axis.horizontal);
      c.setActive(first);
      expect(c.state.activeLeafId, first);
    });

    test('bindActiveSession binds the id to the focused pane only', () {
      final c = PaneTreeController();
      final first = c.state.activeLeafId;
      c.splitActive(Axis.horizontal, pinnedSessionId: 's-old');
      final fresh = c.state.activeLeafId;
      c.bindActiveSession('s-new');
      PaneLeaf leaf(String id) => [
        (c.state.root as PaneSplit).first,
        (c.state.root as PaneSplit).second,
      ].cast<PaneLeaf>().firstWhere((l) => l.id == id);
      expect(leaf(fresh).sessionId, 's-new');
      expect(leaf(first).sessionId, 's-old');
    });

    test('clearActiveSession nulls the focused pane session', () {
      final c = PaneTreeController();
      c.bindActiveSession('s1');
      c.clearActiveSession();
      expect((c.state.root as PaneLeaf).sessionId, isNull);
    });

    test('closeActive focuses the sibling of a nested closed pane', () {
      final c = PaneTreeController();
      final a = c.state.activeLeafId;
      c.splitActive(Axis.horizontal); // A | N1  (active N1)
      final n1 = c.state.activeLeafId;
      c.splitActive(Axis.vertical); // A | (N1 | N2)  (active N2)
      final n2 = c.state.activeLeafId;
      expect(n2, isNot(n1));
      c.closeActive(); // closing N2 should focus its sibling N1, not A
      expect(c.state.activeLeafId, n1);
      expect(c.state.activeLeafId, isNot(a));
    });

    test('adjustRatio accumulates deltas against the live ratio', () {
      final c = PaneTreeController();
      c.splitActive(Axis.horizontal);
      final id = (c.state.root as PaneSplit).id;
      c.adjustRatio(id, -0.1);
      c.adjustRatio(id, -0.1);
      expect((c.state.root as PaneSplit).ratio, closeTo(0.3, 1e-9));
    });

    test(
      'adjustRatio clamps at the lower bound and is a no-op for unknown id',
      () {
        final c = PaneTreeController();
        c.splitActive(Axis.horizontal);
        final id = (c.state.root as PaneSplit).id;
        c.adjustRatio(id, -5);
        expect((c.state.root as PaneSplit).ratio, kMinPaneRatio);
        final before = c.state;
        c.adjustRatio('nope', -0.2);
        expect(c.state, before);
      },
    );

    test('unbindSession clears every pane pinned to that session', () {
      final c = PaneTreeController();
      final first = c.state.activeLeafId;
      c.bindActiveSession('dead');
      c.splitActive(Axis.horizontal, pinnedSessionId: 'dead');
      c.bindActiveSession('dead'); // now both leaves point at 'dead'
      c.unbindSession('dead');
      final split = c.state.root as PaneSplit;
      final leaves = [split.first, split.second].cast<PaneLeaf>();
      expect(leaves.every((l) => l.sessionId == null), isTrue);
      // Structure/focus preserved.
      expect(containsLeaf(c.state.root, first), isTrue);
    });

    test('setActive is a no-op for the current leaf and unknown ids', () {
      final c = PaneTreeController();
      final before = c.state;
      c.setActive(before.activeLeafId); // same id
      expect(c.state, before);
      c.setActive('does-not-exist'); // unknown id
      expect(c.state, before);
    });

    test('setRatio clamps the split ratio via the controller', () {
      final c = PaneTreeController();
      c.splitActive(Axis.horizontal);
      final splitId = (c.state.root as PaneSplit).id;
      c.setRatio(splitId, 5.0);
      expect((c.state.root as PaneSplit).ratio, kMaxPaneRatio);
      c.setRatio(splitId, -1.0);
      expect((c.state.root as PaneSplit).ratio, kMinPaneRatio);
    });

    test('moveLeaf keeps the moved pane active', () {
      final c = PaneTreeController();
      final first = c.state.activeLeafId;
      c.splitActive(Axis.horizontal); // second pane active
      final second = c.state.activeLeafId;
      // Re-dock the first pane onto the second's bottom edge.
      c.moveLeaf(first, second, DropEdge.bottom);
      expect(c.state.activeLeafId, first, reason: 'moved pane stays active');
      expect(containsLeaf(c.state.root, first), isTrue);
      expect(containsLeaf(c.state.root, second), isTrue);
    });

    test('moveLeaf is a no-op when the tree is unchanged', () {
      final c = PaneTreeController();
      final only = c.state.activeLeafId;
      final before = c.state;
      // source == target → pure moveLeaf returns the same tree.
      c.moveLeaf(only, only, DropEdge.right);
      expect(c.state, before);
    });

    test('unbindSession clears leaf by sessionId', () {
      final c = PaneTreeController();
      const sessionId = 's1';
      c.bindActiveSession(sessionId);
      expect((c.state.root as PaneLeaf).sessionId, sessionId);
      c.unbindSession(sessionId);
      expect((c.state.root as PaneLeaf).sessionId, isNull);
    });

    test('unbindSession is a no-op for non-matching ids', () {
      final c = PaneTreeController();
      c.bindActiveSession('s1');
      c.unbindSession('s2');
      expect((c.state.root as PaneLeaf).sessionId, 's1');
    });
  });
}
