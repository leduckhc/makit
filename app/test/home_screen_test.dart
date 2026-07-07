import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pino/store/models.dart';
import 'package:pino/store/store.dart';
import 'package:pino/ui/home/home_screen.dart';
import 'package:pino/ui/widgets/glass.dart';

Widget _host({
  required List<Project> projects,
  required List<Session> sessions,
}) {
  return ProviderScope(
    overrides: [
      projectsProvider.overrideWithValue(ProjectsState(projects)),
      sessionsProvider.overrideWithValue(SessionsState(sessions)),
    ],
    child: const MaterialApp(home: HomeScreen()),
  );
}

void main() {
  testWidgets('empty state is a glass card with its CTA', (tester) async {
    await tester.pumpWidget(_host(projects: const [], sessions: const []));
    await tester.pump();

    expect(find.byType(GlassSurface), findsWidgets);
    expect(find.text('Add project'), findsOneWidget);
  });

  testWidgets('global running strip renders as glass', (tester) async {
    final project = Project(id: 'p1', name: 'demo', path: '/tmp/demo');
    final session = Session(
      id: 's1',
      projectId: 'p1',
      agent: 'pi',
      title: 'work',
      status: SessionStatus.running,
      policy: ApprovalPolicy.askOnRisky,
    );
    await tester.pumpWidget(_host(projects: [project], sessions: [session]));
    await tester.pump();

    expect(find.byType(GlassSurface), findsWidgets);
    expect(find.textContaining('running'), findsWidgets);
  });

  testWidgets('idle sessions render no status pill', (tester) async {
    final project = Project(id: 'p1', name: 'demo', path: '/tmp/demo');
    final session = Session(
      id: 's1',
      projectId: 'p1',
      agent: 'pi',
      title: 'quiet work',
      status: SessionStatus.idle,
      policy: ApprovalPolicy.askOnRisky,
    );
    await tester.pumpWidget(_host(projects: [project], sessions: [session]));
    await tester.pump();

    // The tile is there, but no explicit "idle" pill.
    expect(find.text('quiet work'), findsOneWidget);
    expect(find.text('idle'), findsNothing);
  });

  testWidgets('project menu holds New session, Resume session, Remove', (
    tester,
  ) async {
    final project = Project(id: 'p1', name: 'demo', path: '/tmp/demo');
    await tester.pumpWidget(_host(projects: [project], sessions: const []));
    await tester.pump();

    // Actions live behind the overflow menu, not as always-visible chrome.
    expect(find.text('Resume session'), findsNothing);
    expect(find.text('Remove from pino'), findsNothing);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    expect(find.text('New session'), findsOneWidget);
    expect(find.text('Resume session'), findsOneWidget);
    expect(find.text('Remove from pino'), findsOneWidget);
  });

  testWidgets('old standalone "Attach past session" button is gone', (
    tester,
  ) async {
    final project = Project(id: 'p1', name: 'demo', path: '/tmp/demo');
    await tester.pumpWidget(_host(projects: [project], sessions: const []));
    await tester.pump();

    // The retired label must not appear anywhere (menu closed or open).
    expect(find.text('Attach past session…'), findsNothing);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Attach past session…'), findsNothing);
  });
}
