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
      PaneLeaf leaf(String id) =>
          [
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
  });
}
