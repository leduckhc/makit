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
    await tester.pumpWidget(
      _host(projects: [project], sessions: [session]),
    );
    await tester.pump();

    expect(find.byType(GlassSurface), findsWidgets);
    expect(find.textContaining('running'), findsWidgets);
  });
}
