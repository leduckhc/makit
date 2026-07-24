import 'package:flutter/widgets.dart' show Axis;
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/selected_worktree.dart';

/// A Split holding a single tab bound to [sessionId].
Split _leaf(String id, String tabId, {String? sessionId}) => Split(
  id: id,
  tabs: [Tab(id: tabId, sessionId: sessionId)],
  activeTabId: tabId,
);

void main() {
  group('divideSplit', () {
    test('replaces the target split with a splitter of both splits', () {
      final root = _leaf('a', 't1', sessionId: 's1');
      final newSplit = _leaf('b', 't2', sessionId: 's2');
      final result = divideSplit(
        root,
        'a',
        Axis.horizontal,
        newSplit,
        splitterId: 'sp',
      );
      expect(result, isA<Splitter>());
      final sp = result as Splitter;
      expect(sp.id, 'sp');
      expect(sp.axis, Axis.horizontal);
      expect(sp.ratio, 0.5);
      expect(identical(sp.first, root), isTrue);
      expect(identical(sp.second, newSplit), isTrue);
    });

    test('honours newAfter=false by placing the new split first', () {
      final root = _leaf('a', 't1');
      final newSplit = _leaf('b', 't2');
      final sp =
          divideSplit(
                root,
                'a',
                Axis.vertical,
                newSplit,
                newAfter: false,
                splitterId: 'sp',
              )
              as Splitter;
      expect(identical(sp.first, newSplit), isTrue);
      expect(identical(sp.second, root), isTrue);
    });

    test('divides a nested split, leaving siblings untouched (identity)', () {
      final a = _leaf('a', 'ta');
      final b = _leaf('b', 'tb');
      final root = Splitter(id: 'sp', axis: Axis.horizontal, first: a, second: b);
      final c = _leaf('c', 'tc');
      final result =
          divideSplit(root, 'b', Axis.vertical, c, splitterId: 'sp2')
              as Splitter;
      expect(identical(result.first, a), isTrue);
      final inner = result.second as Splitter;
      expect(identical(inner.first, b), isTrue);
      expect(identical(inner.second, c), isTrue);
    });

    test('is a no-op (same identity) for an unknown target', () {
      final root = _leaf('a', 't1');
      expect(
        identical(divideSplit(root, 'z', Axis.horizontal, _leaf('b', 't2')), root),
        isTrue,
      );
    });
  });

  group('removeSplit', () {
    test('returns the sole split unchanged when it is the only one', () {
      final root = _leaf('a', 't1');
      expect(identical(removeSplit(root, 'a'), root), isTrue);
    });

    test('collapses the parent splitter into the surviving sibling', () {
      final b = _leaf('b', 'tb');
      final root = Splitter(
        id: 'sp',
        axis: Axis.horizontal,
        first: _leaf('a', 'ta'),
        second: b,
      );
      expect(identical(removeSplit(root, 'a'), b), isTrue);
    });

    test('collapses a nested splitter, keeping the rest of the tree', () {
      final a = _leaf('a', 'ta');
      final c = _leaf('c', 'tc');
      final root = Splitter(
        id: 'sp',
        axis: Axis.horizontal,
        first: a,
        second: Splitter(
          id: 'sp2',
          axis: Axis.vertical,
          first: _leaf('b', 'tb'),
          second: c,
        ),
      );
      final result = removeSplit(root, 'b') as Splitter;
      expect(identical(result.first, a), isTrue);
      expect(identical(result.second, c), isTrue);
    });

    test('is a no-op for an unknown split id', () {
      final root = Splitter(
        id: 'sp',
        axis: Axis.horizontal,
        first: _leaf('a', 'ta'),
        second: _leaf('b', 'tb'),
      );
      expect(identical(removeSplit(root, 'z'), root), isTrue);
    });
  });

  group('setRatio', () {
    test('updates the matching splitter and clamps to 0.1-0.9', () {
      final root = Splitter(
        id: 'sp',
        axis: Axis.horizontal,
        first: _leaf('a', 'ta'),
        second: _leaf('b', 'tb'),
      );
      expect((setRatio(root, 'sp', 0.7) as Splitter).ratio, 0.7);
      expect((setRatio(root, 'sp', 0.01) as Splitter).ratio, kMinPaneRatio);
      expect((setRatio(root, 'sp', 0.99) as Splitter).ratio, kMaxPaneRatio);
    });

    test('updates a nested splitter without rebuilding the sibling', () {
      final untouched = Splitter(
        id: 'left',
        axis: Axis.vertical,
        first: _leaf('a', 'ta'),
        second: _leaf('b', 'tb'),
      );
      final root = Splitter(
        id: 'root',
        axis: Axis.horizontal,
        first: untouched,
        second: Splitter(
          id: 'right',
          axis: Axis.vertical,
          first: _leaf('c', 'tc'),
          second: _leaf('d', 'td'),
        ),
      );
      final result = setRatio(root, 'right', 0.8) as Splitter;
      expect((result.second as Splitter).ratio, 0.8);
      expect(identical(result.first, untouched), isTrue);
    });

    test('is a no-op (same identity) for an unknown splitter id', () {
      final root = Splitter(
        id: 'sp',
        axis: Axis.horizontal,
        first: _leaf('a', 'ta'),
        second: _leaf('b', 'tb'),
      );
      expect(identical(setRatio(root, 'nope', 0.7), root), isTrue);
    });
  });

  group('moveSplit', () {
    test('is a no-op when source equals target', () {
      final root = Splitter(
        id: 'sp',
        axis: Axis.horizontal,
        first: _leaf('a', 'ta'),
        second: _leaf('b', 'tb'),
      );
      expect(
        identical(moveSplit(root, 'a', 'a', DropEdge.right, splitterId: 'x'), root),
        isTrue,
      );
    });

    test('re-docks the source to the right of the target (horizontal)', () {
      final a = _leaf('a', 'ta', sessionId: 's1');
      final b = _leaf('b', 'tb', sessionId: 's2');
      final root = Splitter(id: 'sp', axis: Axis.vertical, first: a, second: b);
      final result =
          moveSplit(root, 'a', 'b', DropEdge.right, splitterId: 'sp2')
              as Splitter;
      expect(result.axis, Axis.horizontal);
      expect(identical(result.first, b), isTrue);
      expect(identical(result.second, a), isTrue);
    });

    test('top edge stacks the source above the target (vertical)', () {
      final a = _leaf('a', 'ta');
      final b = _leaf('b', 'tb');
      final root = Splitter(id: 'sp', axis: Axis.horizontal, first: a, second: b);
      final sp =
          moveSplit(root, 'a', 'b', DropEdge.top, splitterId: 'sp2') as Splitter;
      expect(sp.axis, Axis.vertical);
      expect(identical(sp.first, a), isTrue);
      expect(identical(sp.second, b), isTrue);
    });

    test('left edge docks the source before the target (horizontal)', () {
      final a = _leaf('a', 'ta');
      final b = _leaf('b', 'tb');
      final root = Splitter(id: 'sp', axis: Axis.vertical, first: a, second: b);
      final sp =
          moveSplit(root, 'a', 'b', DropEdge.left, splitterId: 'sp2') as Splitter;
      expect(sp.axis, Axis.horizontal);
      expect(identical(sp.first, a), isTrue);
      expect(identical(sp.second, b), isTrue);
    });

    test('is a no-op when the source does not exist', () {
      final root = Splitter(
        id: 'sp',
        axis: Axis.horizontal,
        first: _leaf('a', 'ta'),
        second: _leaf('b', 'tb'),
      );
      expect(identical(moveSplit(root, 'z', 'b', DropEdge.right), root), isTrue);
    });

    test('is a no-op when the target does not exist', () {
      final root = Splitter(
        id: 'sp',
        axis: Axis.horizontal,
        first: _leaf('a', 'ta'),
        second: _leaf('b', 'tb'),
      );
      expect(identical(moveSplit(root, 'a', 'z', DropEdge.right), root), isTrue);
    });

    test('re-docks across a nested tree: prunes source then divides target', () {
      final a = _leaf('a', 'ta', sessionId: 's1');
      final b = _leaf('b', 'tb');
      final c = _leaf('c', 'tc');
      final root = Splitter(
        id: 'sp',
        axis: Axis.horizontal,
        first: a,
        second: Splitter(id: 'sp2', axis: Axis.vertical, first: b, second: c),
      );
      final result =
          moveSplit(root, 'a', 'c', DropEdge.bottom, splitterId: 'sp3')
              as Splitter;
      expect(result.axis, Axis.vertical);
      expect(identical(result.first, b), isTrue);
      final inner = result.second as Splitter;
      expect(inner.axis, Axis.vertical);
      expect(identical(inner.first, c), isTrue);
      expect(identical(inner.second, a), isTrue);
    });
  });

  group('helpers', () {
    test('firstSplitId returns the left-most split id', () {
      final root = Splitter(
        id: 'sp',
        axis: Axis.horizontal,
        first: Splitter(
          id: 'sp2',
          axis: Axis.vertical,
          first: _leaf('a', 'ta'),
          second: _leaf('b', 'tb'),
        ),
        second: _leaf('c', 'tc'),
      );
      expect(firstSplitId(root), 'a');
    });

    test('containsSplit finds nested splits', () {
      final root = Splitter(
        id: 'sp',
        axis: Axis.horizontal,
        first: _leaf('a', 'ta'),
        second: _leaf('b', 'tb'),
      );
      expect(containsSplit(root, 'b'), isTrue);
      expect(containsSplit(root, 'z'), isFalse);
    });

    test('mapSplits rebuilds every split, preserving splitter structure', () {
      final root = Splitter(
        id: 'sp',
        axis: Axis.horizontal,
        ratio: 0.3,
        first: _leaf('a', 'ta'),
        second: Splitter(
          id: 'sp2',
          axis: Axis.vertical,
          first: _leaf('b', 'tb'),
          second: _leaf('c', 'tc'),
        ),
      );
      final result =
          mapSplits(
                root,
                (s) => addTab(s, Tab(id: 'x-${s.id}', sessionId: 'sess')),
              )
              as Splitter;
      expect(result.id, 'sp');
      expect(result.ratio, 0.3);
      expect((result.first as Split).tabs.length, 2);
      final inner = result.second as Splitter;
      expect(inner.id, 'sp2');
      expect((inner.first as Split).tabs.length, 2);
    });

    test('firstSplitWhere returns the first matching value, or null', () {
      final root = Splitter(
        id: 'sp',
        axis: Axis.horizontal,
        first: Splitter(
          id: 'sp2',
          axis: Axis.vertical,
          first: _leaf('a', 'ta', sessionId: 's1'),
          second: _leaf('b', 'tb'),
        ),
        second: _leaf('c', 'tc', sessionId: 's3'),
      );
      expect(
        firstSplitWhere(
          root,
          (s) => s.tabs.first.sessionId != null ? s.id : null,
        ),
        'a',
      );
      expect(firstSplitWhere(root, (s) => s.id == 'z' ? s : null), isNull);
    });
  });

  group('findTab', () {
    final root = Splitter(
      id: 'sp',
      axis: Axis.horizontal,
      first: const Split(
        id: 'a',
        activeTabId: 't1',
        tabs: [
          Tab(id: 't1', sessionId: 's1'),
          Tab(id: 't2', sessionId: 's2'),
        ],
      ),
      second: _leaf('b', 't3', sessionId: 's3'),
    );

    test('locates the split + tab hosting a session', () {
      expect(findTab(root, 's2'), ('a', 't2'));
      expect(findTab(root, 's3'), ('b', 't3'));
    });

    test('returns null when no tab hosts the session', () {
      expect(findTab(root, 'nope'), isNull);
    });
  });

  group('tab helpers', () {
    test('addTab appends and activates the new tab', () {
      final split = _leaf('a', 't1', sessionId: 's1');
      final result = addTab(split, const Tab(id: 't2', sessionId: 's2'));
      expect(result.tabs.map((t) => t.id), ['t1', 't2']);
      expect(result.activeTabId, 't2');
      expect(result.id, 'a');
    });

    test('removeTab drops the tab and re-activates a neighbour', () {
      const split = Split(
        id: 'a',
        activeTabId: 't2',
        tabs: [
          Tab(id: 't1', sessionId: 's1'),
          Tab(id: 't2', sessionId: 's2'),
          Tab(id: 't3', sessionId: 's3'),
        ],
      );
      final result = removeTab(split, 't2')!;
      expect(result.tabs.map((t) => t.id), ['t1', 't3']);
      expect(result.activeTabId, 't3');
    });

    test('removeTab keeps the active tab when a non-active tab is removed', () {
      const split = Split(
        id: 'a',
        activeTabId: 't1',
        tabs: [
          Tab(id: 't1', sessionId: 's1'),
          Tab(id: 't2', sessionId: 's2'),
        ],
      );
      expect(removeTab(split, 't2')!.activeTabId, 't1');
    });

    test('removeTab of the last tab returns null', () {
      final split = _leaf('a', 't1', sessionId: 's1');
      expect(removeTab(split, 't1'), isNull);
    });

    test('removeTab is a no-op (same identity) for an unknown tab', () {
      final split = _leaf('a', 't1', sessionId: 's1');
      expect(identical(removeTab(split, 'z'), split), isTrue);
    });

    test('activateTab switches the active tab', () {
      const split = Split(
        id: 'a',
        activeTabId: 't1',
        tabs: [Tab(id: 't1'), Tab(id: 't2')],
      );
      expect(activateTab(split, 't2').activeTabId, 't2');
    });

    test('activateTab is a no-op (same identity) for an unknown tab', () {
      const split = Split(
        id: 'a',
        activeTabId: 't1',
        tabs: [Tab(id: 't1'), Tab(id: 't2')],
      );
      expect(identical(activateTab(split, 'z'), split), isTrue);
    });

    test('reorderTab moves a tab and preserves the active tab', () {
      const split = Split(
        id: 'a',
        activeTabId: 't1',
        tabs: [Tab(id: 't1'), Tab(id: 't2'), Tab(id: 't3')],
      );
      final result = reorderTab(split, 't1', 2);
      expect(result.tabs.map((t) => t.id), ['t2', 't3', 't1']);
      expect(result.activeTabId, 't1');
    });
  });

  group('nextNodeId', () {
    test('produces deterministic per-kind incremental ids', () {
      resetNodeIds();
      expect(nextNodeId(SplitNodeKind.split), 'split-0');
      expect(nextNodeId(SplitNodeKind.split), 'split-1');
      expect(nextNodeId(SplitNodeKind.splitter), 'splitter-0');
      expect(nextNodeId(SplitNodeKind.tab), 'tab-0');
      resetNodeIds();
      expect(nextNodeId(SplitNodeKind.split), 'split-0');
    });
  });

  group('toJson/fromJson', () {
    test('round-trips a split with a bound session tab', () {
      final split = _leaf('a', 't1', sessionId: 's1');
      expect(SplitNode.fromJson(split.toJson()), split);
    });

    test('serialises worktree only on an empty (sessionless) tab', () {
      const worktree = SelectedWorktree(
        projectId: 'p1',
        path: '/wt',
        branch: 'main',
      );
      const emptyTab = Tab(id: 't1', worktree: worktree);
      expect(emptyTab.toJson()['worktree'], isNotNull);

      // A bound tab never persists its worktree hint.
      const boundTab = Tab(id: 't2', sessionId: 's1', worktree: worktree);
      expect(boundTab.toJson().containsKey('worktree'), isFalse);

      const split = Split(
        id: 'a',
        activeTabId: 't1',
        tabs: [emptyTab],
      );
      final decoded = SplitNode.fromJson(split.toJson()) as Split;
      expect(decoded.tabs.single.worktree, worktree);
      expect(decoded.tabs.single.sessionId, isNull);
    });

    test('round-trips a nested tree with multi-tab splits', () {
      final root = Splitter(
        id: 'sp',
        axis: Axis.horizontal,
        ratio: 0.3,
        first: const Split(
          id: 'a',
          activeTabId: 't2',
          tabs: [
            Tab(id: 't1', sessionId: 's1'),
            Tab(id: 't2', sessionId: 's2'),
          ],
        ),
        second: Splitter(
          id: 'sp2',
          axis: Axis.vertical,
          ratio: 0.7,
          first: _leaf('b', 't3'),
          second: _leaf('c', 't4', sessionId: 's4'),
        ),
      );
      expect(SplitNode.fromJson(root.toJson()), root);
    });

    test('encodes the axis as h/v', () {
      final horizontal = Splitter(
        id: 'sp',
        axis: Axis.horizontal,
        first: _leaf('a', 'ta'),
        second: _leaf('b', 'tb'),
      );
      expect(horizontal.toJson()['axis'], 'h');
      final vertical = Splitter(
        id: 'sp',
        axis: Axis.vertical,
        first: _leaf('a', 'ta'),
        second: _leaf('b', 'tb'),
      );
      expect(vertical.toJson()['axis'], 'v');
    });

    test('tags a split with kind "split" and a splitter with "splitter"', () {
      expect(_leaf('a', 't1').toJson()['k'], 'split');
      expect(
        Splitter(
          id: 'sp',
          axis: Axis.horizontal,
          first: _leaf('a', 'ta'),
          second: _leaf('b', 'tb'),
        ).toJson()['k'],
        'splitter',
      );
    });

    test('throws on an unknown kind tag', () {
      expect(
        () => SplitNode.fromJson(const {'k': 'bogus'}),
        throwsFormatException,
      );
    });
  });
}
