// SPEC-30 Lane 2 — GroupsController: the collection of groups, which one is
// active, the recently-closed boards, and the single persisted payload.
//
// Pure state container: it takes data (a session's location, the set of live
// session ids) rather than reading providers, so every rule below is testable
// without a widget tree.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/groups/group.dart';
import 'package:makit/desktop/chat/groups/groups_controller.dart';
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/selected_worktree.dart';
import 'package:shared_preferences/shared_preferences.dart';

WorkspaceState _treeWith(List<String?> sessionIds) {
  // A split always has at least one tab, so an "empty" tree is one empty tab.
  final ids = sessionIds.isEmpty ? const <String?>[null] : sessionIds;
  final tabs = [
    for (var i = 0; i < ids.length; i++) Tab(id: 'tab-$i', sessionId: ids[i]),
  ];
  return WorkspaceState(
    root: Split(id: 'split-0', tabs: tabs, activeTabId: tabs.first.id),
    activeSplitId: 'split-0',
  );
}

/// A controller seeded with [groups], first one active.
GroupsController _with(List<Group> groups) => GroupsController.ephemeral(
  GroupsState(groups: groups, activeGroupId: groups.first.id),
);

Group _wt(String id, String branch, {List<String?> tabs = const [null]}) =>
    Group.worktree(
      id: id,
      projectId: 'p1',
      worktreePath: '/tmp/wt/$branch',
      label: branch,
      tree: _treeWith(tabs),
    );

Group _board(String id, String label, List<String> members) => Group.board(
  id: id,
  label: label,
  members: members,
  tree: _treeWith(members),
);

void main() {
  setUp(() {
    resetNodeIds();
    SharedPreferences.setMockInitialValues({});
  });

  group('activate + openWorktreeGroup', () {
    test('activate focuses an existing group; unknown ids are ignored', () {
      final c = _with([_wt('g1', 'feat/x'), _wt('g2', 'main')]);
      c.activate('g2');
      expect(c.state.activeGroupId, 'g2');
      c.activate('nope');
      expect(c.state.activeGroupId, 'g2', reason: 'no phantom active group');
    });

    test('openWorktreeGroup activates an existing scope without minting', () {
      final c = _with([_wt('g1', 'feat/x'), _wt('g2', 'main')]);
      final id = c.openWorktreeGroup(
        projectId: 'p1',
        worktreePath: '/tmp/wt/main',
        label: 'main',
      );
      expect(id, 'g2');
      expect(c.state.groups, hasLength(2));
      expect(c.state.activeGroupId, 'g2');
    });

    test('openWorktreeGroup mints a group for an unopened scope', () {
      final c = _with([_wt('g1', 'feat/x')]);
      final id = c.openWorktreeGroup(
        projectId: 'p1',
        worktreePath: '/tmp/wt/fix-y',
        label: 'fix/y',
      );
      expect(c.state.groups, hasLength(2));
      final minted = c.groupById(id)!;
      expect(minted.kind, GroupKind.worktree);
      expect(minted.label, 'fix/y');
      expect(minted.worktreePath, '/tmp/wt/fix-y');
      expect(c.state.activeGroupId, id);
    });
  });

  group('closeGroup (decision 7)', () {
    test('a worktree group leaves no residue — nothing to restore it from', () {
      final c = _with([_wt('g1', 'feat/x'), _wt('g2', 'main')]);
      c.closeGroup('g1');
      expect(c.state.groups.map((g) => g.id), ['g2']);
      expect(c.state.recentlyClosed, isEmpty);
      expect(c.state.activeGroupId, 'g2');
    });

    test('a board is kept in recentlyClosed with its slot', () {
      final c = _with([
        _wt('g1', 'feat/x'),
        _board('b1', 'Shipping 0.9', ['s1', 's2']),
        _wt('g2', 'main'),
      ]);
      c.closeGroup('b1');

      expect(c.state.groups.map((g) => g.id), ['g1', 'g2']);
      expect(c.state.recentlyClosed, hasLength(1));
      expect(c.state.recentlyClosed.single.group.id, 'b1');
      expect(c.state.recentlyClosed.single.slot, 1);
    });

    test('closing the last group is refused (there is always a canvas)', () {
      final c = _with([_wt('g1', 'feat/x')]);
      c.closeGroup('g1');
      expect(c.state.groups, hasLength(1));
    });

    test('recentlyClosed is capped at 10, oldest dropped first', () {
      final c = _with([
        _wt('g1', 'feat/x'),
        for (var i = 0; i < 12; i++) _board('b$i', 'Board $i', const []),
      ]);
      for (var i = 0; i < 12; i++) {
        c.closeGroup('b$i');
      }
      expect(c.state.recentlyClosed, hasLength(10));
      expect(c.state.recentlyClosed.first.group.id, 'b2');
      expect(c.state.recentlyClosed.last.group.id, 'b11');
    });
  });

  group('reopenBoard (decision 8)', () {
    test('restores members and the original slot', () {
      final c = _with([
        _wt('g1', 'feat/x'),
        _board('b1', 'Shipping', ['s1', 's2']),
        _wt('g2', 'main'),
      ]);
      c.closeGroup('b1');
      c.reopenBoard('b1', liveSessionIds: const {'s1', 's2'});

      expect(c.state.groups.map((g) => g.id), ['g1', 'b1', 'g2']);
      expect(c.groupById('b1')!.members, ['s1', 's2']);
      expect(c.state.activeGroupId, 'b1');
      expect(c.state.recentlyClosed, isEmpty, reason: 'consumed on reopen');
    });

    test('filters members archived while the board was closed', () {
      // A closed board is not live, so decision 6's unpin cannot reach it.
      final c = _with([
        _wt('g1', 'feat/x'),
        _board('b1', 'Ship', ['s1', 's2']),
      ]);
      c.closeGroup('b1');
      c.reopenBoard('b1', liveSessionIds: const {'s2'});

      final board = c.groupById('b1')!;
      expect(board.members, ['s2']);
      expect(_boundIds(board.tree), ['s2'], reason: 'its tree drops them too');
    });

    test('a board whose every member died still returns, empty', () {
      final c = _with([
        _wt('g1', 'feat/x'),
        _board('b1', 'Ship', ['s1']),
      ]);
      c.closeGroup('b1');
      c.reopenBoard('b1', liveSessionIds: const {});

      expect(c.groupById('b1'), isNotNull);
      expect(c.groupById('b1')!.members, isEmpty);
    });

    test('undoClose puts the most recent one back', () {
      final c = _with([
        _wt('g1', 'feat/x'),
        _board('b1', 'Ship', ['s1']),
      ]);
      c.closeGroup('b1');
      c.undoClose(liveSessionIds: const {'s1'});
      expect(c.groupById('b1')!.members, ['s1']);
      expect(c.state.recentlyClosed, isEmpty);
    });
  });

  group('addMember (decisions 3, 4)', () {
    test('a board appends, and never twice', () {
      final c = _with([
        _board('b1', 'Ship', ['s1']),
      ]);
      c.addMember('b1', 's2', location: _loc('/tmp/wt/main'));
      c.addMember('b1', 's2', location: _loc('/tmp/wt/main'));
      expect(c.groupById('b1')!.members, ['s1', 's2']);
    });

    test(
      'an in-scope session is already a member: no conversion, no churn',
      () {
        final c = _with([
          _wt('g1', 'feat/x', tabs: ['s1']),
        ]);
        final before = c.state;
        c.addMember('g1', 's2', location: _loc('/tmp/wt/feat/x'));
        expect(c.state.groups, hasLength(1));
        expect(
          c.state,
          before,
          reason: 'membership is derived — nothing to store',
        );
      },
    );

    test('an out-of-scope session converts the group into a board', () {
      final c = _with([
        _wt('g1', 'feat/x', tabs: ['s1', 's2']),
        _wt('g2', 'main', tabs: ['s3']),
      ]);
      c.addMember('g1', 's3', location: _loc('/tmp/wt/main'));

      // The original is untouched and still a worktree group...
      final original = c.groupById('g1')!;
      expect(original.kind, GroupKind.worktree);
      expect(original.tree, _treeWith(['s1', 's2']));

      // ...and a board was inserted directly after it, holding what was on
      // screen plus the newcomer, and is now active.
      final board = c.state.groups[1];
      expect(board.kind, GroupKind.board);
      expect(board.label, 'feat/x +1');
      expect(board.members, ['s1', 's2', 's3']);
      expect(c.state.activeGroupId, board.id);
      expect(c.state.groups.map((g) => g.id).toList(), ['g1', board.id, 'g2']);
    });

    test('removeMember unpins without touching other groups', () {
      final c = _with([
        _board('b1', 'Ship', ['s1', 's2']),
        _board('b2', 'Other', ['s1']),
      ]);
      c.removeMember('b1', 's1');
      expect(c.groupById('b1')!.members, ['s2']);
      expect(c.groupById('b2')!.members, ['s1']);
    });
  });

  group('commitTree + setLayoutOverride', () {
    test('commitTree replaces only the target group\'s tree', () {
      final c = _with([_wt('g1', 'feat/x'), _wt('g2', 'main')]);
      final before = c.groupById('g2')!.tree;
      c.commitTree('g1', _treeWith(['s9']));

      expect(c.groupById('g1')!.tree, _treeWith(['s9']));
      expect(c.groupById('g2')!.tree, before);
    });

    test('commitTree for an unknown group is a no-op, not a crash', () {
      final c = _with([_wt('g1', 'feat/x')]);
      final before = c.state;
      c.commitTree('ghost', _treeWith(['s9']));
      expect(c.state, before);
    });

    test('setLayoutOverride pins and clears', () {
      final c = _with([_wt('g1', 'feat/x')]);
      c.setLayoutOverride('g1', LayoutMode.tabs);
      expect(c.groupById('g1')!.layoutOverride, LayoutMode.tabs);
      c.setLayoutOverride('g1', null);
      expect(c.groupById('g1')!.layoutOverride, isNull);
    });
  });

  group('persistence', () {
    test('an ephemeral controller writes nothing', () async {
      final prefs = await SharedPreferences.getInstance();
      _with([_wt('g1', 'feat/x')]).newBoard();
      expect(prefs.getString(kGroupsPrefsKey), isNull);
    });

    test('mutations survive a reload, versioned', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = GroupsController.load(prefs);
      final id = c.newBoard(label: 'Review');
      c.addMember(id, 's1', location: _loc('/tmp/wt/main'));

      final raw = jsonDecode(prefs.getString(kGroupsPrefsKey)!) as Map;
      expect(raw['v'], 1, reason: 'the payload is versioned from day one');

      final reloaded = GroupsController.load(prefs);
      expect(reloaded.state, c.state);
      expect(reloaded.groupById(id)!.members, ['s1']);
    });

    test('corrupt JSON falls back to the fresh-launch state', () async {
      SharedPreferences.setMockInitialValues({kGroupsPrefsKey: '{not json'});
      final prefs = await SharedPreferences.getInstance();
      final c = GroupsController.load(prefs);
      expect(c.state.groups, hasLength(1));
      expect(c.state.groups.single.kind, GroupKind.board);
      expect(c.state.groups.single.label, 'Board 1');
    });

    test(
      'an unknown payload version falls back rather than guessing',
      () async {
        SharedPreferences.setMockInitialValues({
          kGroupsPrefsKey: jsonEncode({
            'v': 99,
            'groups': <Object?>[],
            'activeGroupId': 'x',
          }),
        });
        final prefs = await SharedPreferences.getInstance();
        expect(
          GroupsController.load(prefs).state.groups.single.label,
          'Board 1',
        );
      },
    );

    test('one corrupt group is dropped, the rest survive', () async {
      final good = _board('b1', 'Ship', const ['s1']);
      SharedPreferences.setMockInitialValues({
        kGroupsPrefsKey: jsonEncode({
          'v': 1,
          'groups': [
            good.toJson(),
            {'id': 'x', 'kind': 'bogus'},
          ],
          'activeGroupId': 'b1',
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      final c = GroupsController.load(prefs);
      expect(c.state.groups.map((g) => g.id), ['b1']);
    });

    test('a stale activeGroupId falls back to the first group', () async {
      final good = _board('b1', 'Ship', const []);
      SharedPreferences.setMockInitialValues({
        kGroupsPrefsKey: jsonEncode({
          'v': 1,
          'groups': <Object?>[good.toJson()],
          'activeGroupId': 'gone',
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      expect(GroupsController.load(prefs).state.activeGroupId, 'b1');
    });
  });

  group('migration from the SPEC-28 single workspace', () {
    test(
      'the old blob becomes Board 1, empty tabs preserved verbatim',
      () async {
        // The legacy tree: one bound tab plus an empty tab carrying a worktree
        // hint. Decision 21 says the empty tab survives.
        const legacy = WorkspaceState(
          root: Split(
            id: 'split-0',
            tabs: [
              Tab(id: 'tab-0', sessionId: 's1'),
              Tab(
                id: 'tab-1',
                worktree: SelectedWorktree(
                  projectId: 'p1',
                  path: '/tmp/wt/feat-x',
                  branch: 'feat/x',
                ),
              ),
            ],
            activeTabId: 'tab-0',
          ),
          activeSplitId: 'split-0',
        );
        SharedPreferences.setMockInitialValues({
          kWorkspacePrefsKey: jsonEncode(legacy.toJson()),
        });
        final prefs = await SharedPreferences.getInstance();
        final c = GroupsController.load(prefs);

        expect(c.state.groups, hasLength(1));
        final board = c.state.groups.single;
        expect(board.kind, GroupKind.board);
        expect(board.label, 'Board 1');
        expect(board.tree, legacy, reason: 'the arrangement is carried over');
        expect(board.members, ['s1'], reason: 'bound tabs become membership');
        expect(c.state.activeGroupId, board.id);
      },
    );

    test('a corrupt legacy blob still yields a usable fresh state', () async {
      SharedPreferences.setMockInitialValues({kWorkspacePrefsKey: '{not json'});
      final prefs = await SharedPreferences.getInstance();
      final c = GroupsController.load(prefs);
      expect(c.state.groups.single.label, 'Board 1');
      expect(c.state.groups.single.members, isEmpty);
    });
  });

  group('seedFromSessions (decision 19)', () {
    test(
      'replaces an untouched empty Board 1 with the newest worktree group',
      () {
        final c = GroupsController.ephemeral(GroupsState.fresh());
        c.seedFromSessions(
          projectId: 'p1',
          worktreePath: '/tmp/wt/feat-x',
          label: 'feat/x',
        );
        final only = c.state.groups.single;
        expect(only.kind, GroupKind.worktree);
        expect(only.label, 'feat/x');
        expect(c.state.activeGroupId, only.id);
      },
    );

    test('never disturbs a workspace the user already shaped', () {
      final c = _with([
        _board('b1', 'Ship', ['s1']),
      ]);
      final before = c.state;
      c.seedFromSessions(
        projectId: 'p1',
        worktreePath: '/tmp/wt/feat-x',
        label: 'feat/x',
      );
      expect(c.state, before);
    });
  });
}

SessionLocation _loc(String worktreePath) =>
    SessionLocation(projectId: 'p1', worktreePath: worktreePath);

List<String> _boundIds(WorkspaceState tree) {
  final ids = <String>[];
  firstSplitWhere<bool>(tree.root, (split) {
    ids.addAll(split.tabs.map((t) => t.sessionId).nonNulls);
    return null;
  });
  return ids;
}
