import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_sidebar.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

Project _project(String id, String name) =>
    Project(id: id, name: name, path: '/tmp/$id');

Session _session(String id, String projectId, String title, String agent) =>
    Session(
      id: id,
      projectId: projectId,
      agent: agent,
      title: title,
      status: SessionStatus.idle,
      policy: ApprovalPolicy.askOnRisky,
    );

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required List<Project> projects,
  required List<Session> sessions,
}) async {
  final container = ProviderContainer(
    overrides: [
      projectsProvider.overrideWithValue(ProjectsState(projects)),
      sessionsProvider.overrideWithValue(SessionsState(sessions)),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: SizedBox(width: 280, child: DesktopSidebar())),
      ),
    ),
  );
  return container;
}

void main() {
  testWidgets('sidebar lists sessions grouped by project', (tester) async {
    await _pump(
      tester,
      projects: [_project('p1', 'alpha')],
      sessions: [
        _session('s1', 'p1', 'Fix login bug', 'codex'),
        _session('s2', 'p1', 'Add tests', 'pi'),
      ],
    );

    expect(find.text('ALPHA'), findsOneWidget);
    expect(find.text('Fix login bug'), findsOneWidget);
    expect(find.text('Add tests'), findsOneWidget);
    expect(find.text('codex'), findsOneWidget);
  });

  testWidgets('tapping a session selects it', (tester) async {
    final container = await _pump(
      tester,
      projects: [_project('p1', 'alpha')],
      sessions: [_session('s1', 'p1', 'Fix login bug', 'codex')],
    );

    expect(container.read(selectedSessionProvider), isNull);

    await tester.tap(find.text('Fix login bug'));
    await tester.pump();

    expect(container.read(selectedSessionProvider), 's1');
  });

  testWidgets('empty state prompts to start a session', (tester) async {
    await _pump(tester, projects: const [], sessions: const []);
    expect(find.textContaining('No sessions yet'), findsOneWidget);
  });
}
