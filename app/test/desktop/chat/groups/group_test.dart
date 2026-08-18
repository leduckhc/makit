// SPEC-tab-groups Lane 1 — the Group model. Pure Dart: no widgets, no providers, no
// prefs, so these tests stay fast and deterministic.
import 'package:flutter/widgets.dart' show Axis;
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/groups/group.dart';
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/selected_worktree.dart';

WorkspaceState _tree({String? sessionId, SelectedWorktree? worktree}) {
  final tab = Tab(id: 'tab-1', sessionId: sessionId, worktree: worktree);
  return WorkspaceState(
    root: Split(id: 'split-1', tabs: [tab], activeTabId: tab.id),
    activeSplitId: 'split-1',
  );
}

WorkspaceState _nestedTree() {
  const a = Tab(id: 'tab-a', sessionId: 's1');
  const b = Tab(id: 'tab-b', sessionId: 's2');
  const c = Tab(id: 'tab-c', sessionId: 's3');
  return WorkspaceState(
    root: Splitter(
      id: 'splitter-1',
      axis: Axis.horizontal,
      ratio: 0.4,
      first: Split(id: 'split-1', tabs: const [a], activeTabId: a.id),
      second: Split(id: 'split-2', tabs: const [b, c], activeTabId: c.id),
    ),
    activeSplitId: 'split-2',
  );
}

void main() {
  group('Group.worktree', () {
    test('round-trips through JSON, scope and all', () {
      final g = Group.worktree(
        id: 'g1',
        projectId: 'p1',
        worktreePath: '/tmp/wt/feat-x',
        label: 'feat/x',
        tree: _nestedTree(),
      );

      final back = Group.fromJson(g.toJson())!;
      expect(back, g);
      expect(back.kind, GroupKind.worktree);
      expect(back.projectId, 'p1');
      expect(back.worktreePath, '/tmp/wt/feat-x');
      expect(back.tree, g.tree);
      expect(back.layoutOverride, isNull);
    });

    test('carries no members — membership is derived, never stored', () {
      final g = Group.worktree(
        id: 'g1',
        projectId: 'p1',
        worktreePath: '/tmp/wt',
        label: 'main',
        tree: _tree(),
      );
      expect(g.members, isEmpty);
      expect(g.toJson().containsKey('members'), isFalse);
    });
  });

  group('Group.board', () {
    test('round-trips members, label and layoutOverride', () {
      final g = Group.board(
        id: 'b1',
        label: 'Shipping 0.9',
        members: const ['s1', 's2'],
        layoutOverride: LayoutMode.tabs,
        tree: _tree(sessionId: 's1'),
      );

      final back = Group.fromJson(g.toJson())!;
      expect(back, g);
      expect(back.kind, GroupKind.board);
      expect(back.members, ['s1', 's2']);
      expect(back.layoutOverride, LayoutMode.tabs);
      expect(back.projectId, isNull);
      expect(back.worktreePath, isNull);
    });

    test('drops duplicate members, keeping first-seen order', () {
      final g = Group.board(
        id: 'b1',
        label: 'B',
        members: const ['s2', 's1', 's2', 's1'],
        tree: _tree(),
      );
      // Decision 3: a session appears at most once per group.
      expect(g.members, ['s2', 's1']);
    });

    test('an empty board is legal (it is created before it is filled)', () {
      final g = Group.board(id: 'b1', label: 'Board 1', tree: _tree());
      expect(g.members, isEmpty);
      expect(Group.fromJson(g.toJson()), g);
    });
  });

  group('Group.fromJson resilience', () {
    test('returns null instead of throwing on a corrupt entry', () {
      // Decision: a corrupt group is DROPPED, never fatal — one bad entry must
      // not cost the user every other group.
      expect(Group.fromJson(const {}), isNull);
      expect(Group.fromJson(const {'id': 'g1'}), isNull);
      expect(Group.fromJson(const {'id': 'g1', 'kind': 'wat'}), isNull);
      expect(
        Group.fromJson(const {'id': 'g1', 'kind': 'board', 'tree': 'nope'}),
        isNull,
      );
      expect(
        Group.fromJson(const {
          'id': 'g1',
          'kind': 'worktree',
          'label': 'x',
          'tree': {
            'root': {'k': 'bogus'},
            'activeSplitId': 'split-1',
          },
        }),
        isNull,
      );
    });

    test(
      'a worktree group without a scope is corrupt (it could not resolve)',
      () {
        expect(
          Group.fromJson({
            'id': 'g1',
            'kind': 'worktree',
            'label': 'main',
            'tree': _tree().toJson(),
          }),
          isNull,
        );
      },
    );

    test('an unknown layout override degrades to null, not to a throw', () {
      final json = Group.board(id: 'b1', label: 'B', tree: _tree()).toJson()
        ..['layoutOverride'] = 'diagonal';
      expect(Group.fromJson(json)?.layoutOverride, isNull);
    });
  });

  group('Group.copyWith', () {
    test('replaces only what is named', () {
      final g = Group.board(
        id: 'b1',
        label: 'B',
        members: const ['s1'],
        tree: _tree(),
      );
      final moved = g.copyWith(tree: _nestedTree());
      expect(moved.tree, _nestedTree());
      expect(moved.members, ['s1']);
      expect(moved.label, 'B');
      expect(moved.id, 'b1');
    });

    test('preserves the layout override; withLayout sets and clears it', () {
      // `copyWith` cannot express "clear this nullable" and "leave it alone"
      // with one argument, so the override has its own explicit setter.
      final g = Group.board(
        id: 'b1',
        label: 'B',
        layoutOverride: LayoutMode.split,
        tree: _tree(),
      );
      expect(g.copyWith(label: 'B2').layoutOverride, LayoutMode.split);
      expect(g.withLayout(null).layoutOverride, isNull);
      expect(g.withLayout(LayoutMode.tabs).layoutOverride, LayoutMode.tabs);
      expect(
        g.withLayout(null).members,
        g.members,
        reason: 'nothing else moves',
      );
    });

    test('de-duplicates members it is handed', () {
      final g = Group.board(id: 'b1', label: 'B', tree: _tree());
      expect(g.copyWith(members: const ['s1', 's1']).members, ['s1']);
    });
  });

  test('isScopedTo matches a worktree group to a session location', () {
    final g = Group.worktree(
      id: 'g1',
      projectId: 'p1',
      worktreePath: '/tmp/wt/feat-x',
      label: 'feat/x',
      tree: _tree(),
    );
    expect(
      g.isScopedTo(projectId: 'p1', worktreePath: '/tmp/wt/feat-x'),
      isTrue,
    );
    expect(
      g.isScopedTo(projectId: 'p2', worktreePath: '/tmp/wt/feat-x'),
      isFalse,
    );
    expect(
      g.isScopedTo(projectId: 'p1', worktreePath: '/tmp/wt/other'),
      isFalse,
    );
    expect(g.isScopedTo(projectId: 'p1', worktreePath: null), isFalse);

    final board = Group.board(id: 'b1', label: 'B', tree: _tree());
    expect(
      board.isScopedTo(projectId: 'p1', worktreePath: '/tmp/wt/feat-x'),
      isFalse,
      reason: 'a board has no scope, so it is scoped to nothing',
    );
  });
}
