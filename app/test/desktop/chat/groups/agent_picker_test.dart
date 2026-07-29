// SPEC-30 Lane 6 — the agent picker (decision 13 board half, decision 14).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/groups/agent_picker.dart';
import 'package:makit/desktop/chat/groups/group.dart';
import 'package:makit/desktop/chat/groups/groups_controller.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

Session _session(
  String id, {
  String? worktreePath,
  String projectId = 'p1',
  String? branch,
  SessionStatus status = SessionStatus.idle,
}) => Session(
  id: id,
  projectId: projectId,
  agent: 'pi',
  title: id,
  status: status,
  policy: ApprovalPolicy.askOnRisky,
  worktreePath: worktreePath,
  branch: branch,
);

Group _board(String id, List<String> members, {String? label}) => Group.board(
  id: id,
  label: label ?? id,
  members: members,
  tree: WorkspaceController.seedWorkspace(),
);

Group _wt(String id, String path, {String? label}) => Group.worktree(
  id: id,
  projectId: 'p1',
  worktreePath: path,
  label: label ?? path.split('/').last,
  tree: WorkspaceController.seedWorkspace(),
);

ProviderContainer _container({
  required List<Group> groups,
  required List<Session> sessions,
  String? activeGroupId,
}) {
  final container = ProviderContainer(
    overrides: [
      sessionsProvider.overrideWithValue(SessionsState(sessions)),
      reposProvider.overrideWithValue(ReposState(const [])),
      groupsControllerProvider.overrideWith(
        (ref) => GroupsController.ephemeral(
          GroupsState(
            groups: groups,
            activeGroupId: activeGroupId ?? groups.first.id,
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: AgentPicker())),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('groups live sessions by repo · branch with members pre-ticked', (
    tester,
  ) async {
    final c = _container(
      groups: [
        _board('b1', ['s1'], label: 'Shipping'),
      ],
      sessions: [
        _session('s1', branch: 'feat/x'),
        _session('s2', branch: 'main'),
      ],
    );
    await _pump(tester, c);

    expect(find.text('Add agents to “Shipping”'), findsOneWidget);
    // Grouped headers (repo falls back to project id p1 when repos empty).
    expect(find.text('P1 · FEAT/X'), findsOneWidget);
    expect(find.text('P1 · MAIN'), findsOneWidget);
    // A leading New session… row.
    expect(find.text('New session…'), findsOneWidget);
    // Footer counts the single member.
    expect(find.textContaining('1 on this board'), findsOneWidget);
  });

  testWidgets('ticking an unchecked row pins it exactly once (decision 3)', (
    tester,
  ) async {
    final c = _container(
      groups: [_board('b1', const [], label: 'Shipping')],
      sessions: [_session('s1', branch: 'feat/x')],
    );
    await _pump(tester, c);

    await tester.tap(find.text('s1'));
    await tester.pump();
    expect(c.read(groupsControllerProvider).active.members, ['s1']);

    // Ticking a member again (via the picker) unpins it, never duplicates.
    await tester.tap(find.text('s1'));
    await tester.pump();
    expect(c.read(groupsControllerProvider).active.members, isEmpty);
  });

  testWidgets('a pre-ticked member row unpins on tap', (tester) async {
    final c = _container(
      groups: [
        _board('b1', ['s1'], label: 'Shipping'),
      ],
      sessions: [_session('s1', branch: 'feat/x')],
    );
    await _pump(tester, c);

    await tester.tap(find.text('s1'));
    await tester.pump();
    expect(c.read(groupsControllerProvider).active.members, isEmpty);
  });

  testWidgets('the picker is empty for a worktree group (never crashes)', (
    tester,
  ) async {
    final c = _container(
      groups: [_wt('g1', '/tmp/wt/a', label: 'feat/x')],
      sessions: const [],
    );
    await _pump(tester, c);
    expect(find.byType(AgentPicker), findsOneWidget);
    expect(find.textContaining('Add agents'), findsNothing);
  });
}
