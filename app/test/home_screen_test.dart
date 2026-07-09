import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/home_screen.dart';
import 'package:makit/ui/widgets/glass.dart';

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

  testWidgets('running session surfaces a status chip, no global strip', (
    tester,
  ) async {
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

    // The retired "N running · <agents>" pill is gone.
    expect(find.textContaining('running · '), findsNothing);
    // Per-tile status chip still surfaces the running state.
    expect(find.text('running'), findsOneWidget);
  });

  testWidgets('known agent renders its logo, not a letter avatar', (
    tester,
  ) async {
    final project = Project(id: 'p1', name: 'demo', path: '/tmp/demo');
    final session = Session(
      id: 's1',
      projectId: 'p1',
      agent: 'pi',
      title: 'work',
      status: SessionStatus.idle,
      policy: ApprovalPolicy.askOnRisky,
    );
    await tester.pumpWidget(_host(projects: [project], sessions: [session]));
    await tester.pumpAndSettle();

    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.byType(CircleAvatar), findsNothing);
  });

  testWidgets('unknown agent falls back to the initial letter', (tester) async {
    final project = Project(id: 'p1', name: 'demo', path: '/tmp/demo');
    final session = Session(
      id: 's1',
      projectId: 'p1',
      agent: 'grok',
      title: 'work',
      status: SessionStatus.idle,
      policy: ApprovalPolicy.askOnRisky,
    );
    await tester.pumpWidget(_host(projects: [project], sessions: [session]));
    await tester.pump();

    expect(find.byType(CircleAvatar), findsOneWidget);
    expect(find.text('G'), findsOneWidget);
    expect(find.byType(SvgPicture), findsNothing);
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
    expect(find.text('Remove from makit'), findsNothing);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    expect(find.text('New session'), findsOneWidget);
    expect(find.text('Resume session'), findsOneWidget);
    expect(find.text('Remove from makit'), findsOneWidget);
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
