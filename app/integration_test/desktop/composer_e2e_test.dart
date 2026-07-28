// macOS e2e for the desktop chat composer (the "chat input"). Runs the REAL
// DesktopChatPane on the macOS engine to verify, end-to-end, that:
//   1. a selected session renders the docked composer (the input),
//   2. the input is hit-testable — tapping it focuses + accepts text,
//   3. the model / thinking selectors render once session.meta arrives,
//   4. the no-selection state deliberately shows NO composer.
//
// Run: flutter test integration_test/desktop/composer_e2e_test.dart -d macos
//
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:makit/desktop/chat/desktop_chat_pane.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

Session _session() => Session(
  id: 's1',
  projectId: 'p1',
  agent: 'pi',
  title: 'Wire up pairing',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  lastPreview: '',
  lastActivityAt: 0,
);

const _model = ModelInfo(provider: 'openai', id: 'gpt-5', name: 'GPT-5');

Widget _app(ProviderContainer c) => UncontrolledProviderScope(
  container: c,
  child: const MaterialApp(
    home: Scaffold(body: DesktopChatPane(sessionId: 's1')),
  ),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'selected session: composer is visible, focuses on tap, accepts text',
    (tester) async {
      final c = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState([_session()])),
          eventsProvider.overrideWithValue(EventsState(const {}, const {})),
          sessionMetaProvider('s1').overrideWithValue(
            const SessionMeta(
              model: _model,
              thinking: 'medium',
              models: [_model],
            ),
          ),
        ],
      );
      addTearDown(c.dispose);

      await tester.pumpWidget(_app(c));
      await tester.pumpAndSettle();

      // 1. The input exists and is on-screen.
      final field = find.byType(TextField);
      expect(
        field,
        findsOneWidget,
        reason: 'composer TextField must render for a selected session',
      );
      expect(tester.getSize(field).height, greaterThan(0));

      // 3. The model + thinking selectors render (meta present).
      expect(
        find.text('GPT-5'),
        findsOneWidget,
        reason: 'model selector should show',
      );
      expect(
        find.text('medium'),
        findsOneWidget,
        reason: 'thinking selector should show',
      );

      // 2. Tapping focuses it; typing accepts text and reveals the send button.
      await tester.tap(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'hello desktop');
      await tester.pumpAndSettle();
      expect(
        find.text('hello desktop'),
        findsOneWidget,
        reason: 'input must accept text on tap',
      );
      expect(
        find.byKey(const ValueKey('send')),
        findsOneWidget,
        reason: 'send appears once text is entered',
      );
    },
  );

  testWidgets('unresolvable session: pane shows placeholder and NO composer', (
    tester,
  ) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c));
    await tester.pumpAndSettle();

    // Assert on the placeholder widget, not its copy — wording churn (SPEC-27)
    // is what silently rotted this test before.
    expect(find.byType(EmptyPaneStarter), findsOneWidget);
    expect(
      find.byType(TextField),
      findsNothing,
      reason: 'no composer without a session — this is the empty state',
    );
  });
}
