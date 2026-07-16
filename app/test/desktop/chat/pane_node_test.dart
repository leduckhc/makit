import 'package:flutter/widgets.dart' show Axis;
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/panes/pane_node.dart';

void main() {
  group('splitLeaf', () {
    test('replaces the target leaf with a split of the two leaves', () {
      const root = PaneLeaf(id: 'a', sessionId: 's1');
      final result = splitLeaf(
        root,
        'a',
        Axis.horizontal,
        const PaneLeaf(id: 'b', sessionId: 's2'),
        splitId: 'sp',
      );
      expect(result, isA<PaneSplit>());
      final split = result as PaneSplit;
      expect(split.id, 'sp');
      expect(split.axis, Axis.horizontal);
      expect(split.ratio, 0.5);
      expect(split.first, const PaneLeaf(id: 'a', sessionId: 's1'));
      expect(split.second, const PaneLeaf(id: 'b', sessionId: 's2'));
    });

    test('honours newAfter=false by placing the new leaf first', () {
      const root = PaneLeaf(id: 'a');
      final split =
          splitLeaf(
                root,
                'a',
                Axis.vertical,
                const PaneLeaf(id: 'b'),
                newAfter: false,
                splitId: 'sp',
              )
              as PaneSplit;
      expect(split.first, const PaneLeaf(id: 'b'));
      expect(split.second, const PaneLeaf(id: 'a'));
    });

    test('splits a nested leaf, leaving siblings untouched', () {
      const root = PaneSplit(
        id: 'sp',
        axis: Axis.horizontal,
        first: PaneLeaf(id: 'a'),
        second: PaneLeaf(id: 'b'),
      );
      final result =
          splitLeaf(
                root,
                'b',
                Axis.vertical,
                const PaneLeaf(id: 'c'),
                splitId: 'sp2',
              )
              as PaneSplit;
      expect(result.first, const PaneLeaf(id: 'a'));
      expect(result.second, isA<PaneSplit>());
      final inner = result.second as PaneSplit;
      expect(inner.first, const PaneLeaf(id: 'b'));
      expect(inner.second, const PaneLeaf(id: 'c'));
    });

    test('is a no-op for an unknown target leaf id', () {
      const root = PaneLeaf(id: 'a');
      expect(
        splitLeaf(root, 'z', Axis.horizontal, const PaneLeaf(id: 'b')),
        root,
      );
    });
  });

  group('closeLeaf', () {
    test('returns the sole leaf unchanged when it is the only pane', () {
      const root = PaneLeaf(id: 'a');
      expect(closeLeaf(root, 'a'), root);
    });

    test('collapses the parent split into the surviving sibling', () {
      const root = PaneSplit(
        id: 'sp',
        axis: Axis.horizontal,
        first: PaneLeaf(id: 'a'),
        second: PaneLeaf(id: 'b'),
      );
      expect(closeLeaf(root, 'a'), const PaneLeaf(id: 'b'));
    });

    test('collapses a nested split, keeping the rest of the tree', () {
      const root = PaneSplit(
        id: 'sp',
        axis: Axis.horizontal,
        first: PaneLeaf(id: 'a'),
        second: PaneSplit(
          id: 'sp2',
          axis: Axis.vertical,
          first: PaneLeaf(id: 'b'),
          second: PaneLeaf(id: 'c'),
        ),
      );
      final result = closeLeaf(root, 'b') as PaneSplit;
      expect(result.first, const PaneLeaf(id: 'a'));
      expect(result.second, const PaneLeaf(id: 'c'));
    });

    test('is a no-op for an unknown leaf id', () {
      const root = PaneSplit(
        id: 'sp',
        axis: Axis.horizontal,
        first: PaneLeaf(id: 'a'),
        second: PaneLeaf(id: 'b'),
      );
      expect(closeLeaf(root, 'z'), root);
    });
  });

  group('setRatio', () {
    test('updates the matching split and clamps to 0.1–0.9', () {
      const root = PaneSplit(
        id: 'sp',
        axis: Axis.horizontal,
        first: PaneLeaf(id: 'a'),
        second: PaneLeaf(id: 'b'),
      );
      expect((setRatio(root, 'sp', 0.7) as PaneSplit).ratio, 0.7);
      expect((setRatio(root, 'sp', 0.01) as PaneSplit).ratio, 0.1);
      expect((setRatio(root, 'sp', 0.99) as PaneSplit).ratio, 0.9);
    });
  });

  group('moveLeaf', () {
    test('is a no-op when source equals target', () {
      const root = PaneSplit(
        id: 'sp',
        axis: Axis.horizontal,
        first: PaneLeaf(id: 'a'),
        second: PaneLeaf(id: 'b'),
      );
      expect(moveLeaf(root, 'a', 'a', DropEdge.right, splitId: 'x'), root);
    });

    test('re-docks the source to the right of the target (horizontal)', () {
      const root = PaneSplit(
        id: 'sp',
        axis: Axis.vertical,
        first: PaneLeaf(id: 'a', sessionId: 's1'),
        second: PaneLeaf(id: 'b', sessionId: 's2'),
      );
      // Move a onto b's right edge. a is removed (root collapses to b), then
      // b is split horizontally with a after it.
      final result = moveLeaf(root, 'a', 'b', DropEdge.right, splitId: 'sp2');
      expect(result, isA<PaneSplit>());
      final split = result as PaneSplit;
      expect(split.axis, Axis.horizontal);
      expect(split.first, const PaneLeaf(id: 'b', sessionId: 's2'));
      expect(split.second, const PaneLeaf(id: 'a', sessionId: 's1'));
    });

    test('top edge stacks the source above the target (vertical)', () {
      const root = PaneSplit(
        id: 'sp',
        axis: Axis.horizontal,
        first: PaneLeaf(id: 'a'),
        second: PaneLeaf(id: 'b'),
      );
      final split =
          moveLeaf(root, 'a', 'b', DropEdge.top, splitId: 'sp2') as PaneSplit;
      expect(split.axis, Axis.vertical);
      expect(split.first, const PaneLeaf(id: 'a'));
      expect(split.second, const PaneLeaf(id: 'b'));
    });

    test('left edge docks the source before the target (horizontal)', () {
      const root = PaneSplit(
        id: 'sp',
        axis: Axis.vertical,
        first: PaneLeaf(id: 'a', sessionId: 's1'),
        second: PaneLeaf(id: 'b', sessionId: 's2'),
      );
      final split =
          moveLeaf(root, 'a', 'b', DropEdge.left, splitId: 'sp2') as PaneSplit;
      expect(split.axis, Axis.horizontal);
      // left → source comes first (newAfter=false).
      expect(split.first, const PaneLeaf(id: 'a', sessionId: 's1'));
      expect(split.second, const PaneLeaf(id: 'b', sessionId: 's2'));
    });

    test('bottom edge stacks the source below the target (vertical)', () {
      const root = PaneSplit(
        id: 'sp',
        axis: Axis.horizontal,
        first: PaneLeaf(id: 'a'),
        second: PaneLeaf(id: 'b'),
      );
      final split =
          moveLeaf(root, 'a', 'b', DropEdge.bottom, splitId: 'sp2')
              as PaneSplit;
      expect(split.axis, Axis.vertical);
      // bottom → source comes second (newAfter=true).
      expect(split.first, const PaneLeaf(id: 'b'));
      expect(split.second, const PaneLeaf(id: 'a'));
    });

    test('is a no-op when the source leaf does not exist', () {
      const root = PaneSplit(
        id: 'sp',
        axis: Axis.horizontal,
        first: PaneLeaf(id: 'a'),
        second: PaneLeaf(id: 'b'),
      );
      expect(moveLeaf(root, 'z', 'b', DropEdge.right), root);
    });

    test('is a no-op when the target leaf does not exist', () {
      const root = PaneSplit(
        id: 'sp',
        axis: Axis.horizontal,
        first: PaneLeaf(id: 'a'),
        second: PaneLeaf(id: 'b'),
      );
      expect(moveLeaf(root, 'a', 'z', DropEdge.right), root);
    });

    test('re-docks across a nested tree: prunes source then splits target', () {
      // a | (b / c): move a onto c's bottom edge. a is pruned (outer split
      // collapses to b/c), then c is split vertically with a below it.
      const root = PaneSplit(
        id: 'sp',
        axis: Axis.horizontal,
        first: PaneLeaf(id: 'a', sessionId: 's1'),
        second: PaneSplit(
          id: 'sp2',
          axis: Axis.vertical,
          first: PaneLeaf(id: 'b'),
          second: PaneLeaf(id: 'c'),
        ),
      );
      final result =
          moveLeaf(root, 'a', 'c', DropEdge.bottom, splitId: 'sp3')
              as PaneSplit;
      // Outer axis is now the inner split's vertical layout (a pruned).
      expect(result.axis, Axis.vertical);
      expect(result.first, const PaneLeaf(id: 'b'));
      final inner = result.second as PaneSplit;
      expect(inner.axis, Axis.vertical);
      expect(inner.first, const PaneLeaf(id: 'c'));
      expect(inner.second, const PaneLeaf(id: 'a', sessionId: 's1'));
    });
  });

  group('helpers', () {
    test('firstLeafId returns the left-most leaf id', () {
      const root = PaneSplit(
        id: 'sp',
        axis: Axis.horizontal,
        first: PaneSplit(
          id: 'sp2',
          axis: Axis.vertical,
          first: PaneLeaf(id: 'a'),
          second: PaneLeaf(id: 'b'),
        ),
        second: PaneLeaf(id: 'c'),
      );
      expect(firstLeafId(root), 'a');
    });

    test('containsLeaf finds nested leaves', () {
      const root = PaneSplit(
        id: 'sp',
        axis: Axis.horizontal,
        first: PaneLeaf(id: 'a'),
        second: PaneLeaf(id: 'b'),
      );
      expect(containsLeaf(root, 'b'), isTrue);
      expect(containsLeaf(root, 'z'), isFalse);
    });
  });

  group('nextPaneId', () {
    test('produces monotonically distinct ids', () {
      final first = nextPaneId();
      final second = nextPaneId();
      expect(first, isNot(second));
    });
  });
}
