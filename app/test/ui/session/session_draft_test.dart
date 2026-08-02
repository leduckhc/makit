// SPEC-27 on mobile: a half-typed message survives the session screen being
// disposed and remounted (a route pop and re-entry, which is how a draft used
// to vanish on the phone).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/composer_draft.dart';
import 'package:makit/ui/session/session_screen.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();

  @override
  Future<String?> read({required String key}) async => null;

  @override
  Future<void> write({required String key, required String? value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}

void main() {
  Session session(String id) => Session(
    id: id,
    projectId: 'p1',
    agent: 'pi',
    title: 'Session',
    status: SessionStatus.idle,
    policy: ApprovalPolicy.askOnRisky,
  );

  /// A container that outlives the widget tree, so tearing the screen down is a
  /// real dispose while the draft store stays put (as it does app-wide).
  ProviderContainer containerFor(List<String> sessionIds) => ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
      projectsProvider.overrideWithValue(ProjectsState(const [])),
      reposProvider.overrideWithValue(ReposState(const [])),
      sessionsProvider.overrideWithValue(
        SessionsState([for (final id in sessionIds) session(id)]),
      ),
      for (final id in sessionIds) ...[
        chatItemsProvider(id).overrideWithValue(const []),
        sessionMetaProvider(id).overrideWithValue(null),
        sessionActionErrorProvider(id).overrideWithValue(null),
        commandsProvider(id).overrideWithValue(const []),
      ],
    ],
  );

  Future<void> pumpScreen(
    WidgetTester tester,
    ProviderContainer container,
    String sessionId,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: SessionScreen(sessionId: sessionId)),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'a half-typed message survives leaving and reopening the session',
    (tester) async {
      final container = containerFor(['s1']);
      addTearDown(container.dispose);

      await pumpScreen(tester, container, 's1');
      await tester.enterText(find.byType(TextField), 'half typed');
      await tester.pumpAndSettle();
      expect(container.read(composerDraftsProvider)['s1'], 'half typed');

      // Leave the screen (route pop) …
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: SizedBox())),
        ),
      );
      await tester.pump();
      // … and come back.
      await pumpScreen(tester, container, 's1');

      expect(find.text('half typed'), findsOneWidget);
    },
  );

  testWidgets('drafts are kept per session', (tester) async {
    final container = containerFor(['s1', 's2']);
    addTearDown(container.dispose);

    await pumpScreen(tester, container, 's1');
    await tester.enterText(find.byType(TextField), 's1 draft');
    await tester.pumpAndSettle();

    await pumpScreen(tester, container, 's2');

    expect(find.text('s1 draft'), findsNothing);
    expect(container.read(composerDraftsProvider)['s2'], isNull);
  });

  testWidgets('sending prunes the stored draft', (tester) async {
    final container = containerFor(['s1']);
    addTearDown(container.dispose);

    await pumpScreen(tester, container, 's1');
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'send me');
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(PhosphorIconsLight.arrowUp));
    await tester.pumpAndSettle();

    expect(container.read(composerDraftsProvider)['s1'], isNull);
  });
}
