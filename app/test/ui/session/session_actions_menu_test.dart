// The session ⋯ menu must only offer what the agent can actually do. The
// composer's selectors already hide themselves when a capability is absent; the
// menu used to offer Model and Thinking to every agent, so on an ACP agent
// (modes / config options, no model or thinking) "Thinking" opened a picker,
// sent an action nothing could honour, and reported success.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/composer_selectors.dart';
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

const _sessionId = 's1';

const _model = ModelInfo(provider: 'anthropic', id: 'claude', name: 'Claude');

Future<void> _pumpMenu(WidgetTester tester, SessionMeta? meta) async {
  final session = Session(
    id: _sessionId,
    projectId: 'p1',
    agent: 'pi',
    title: 'Session',
    status: SessionStatus.idle,
    policy: ApprovalPolicy.askOnRisky,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionControllerProvider.overrideWith(
          (ref) => ConnectionController(const _EmptyStorage()),
        ),
        projectsProvider.overrideWithValue(ProjectsState(const [])),
        reposProvider.overrideWithValue(ReposState(const [])),
        sessionsProvider.overrideWithValue(SessionsState([session])),
        chatItemsProvider(_sessionId).overrideWithValue(const []),
        sessionMetaProvider(_sessionId).overrideWithValue(meta),
        sessionActionErrorProvider(_sessionId).overrideWithValue(null),
        commandsProvider(_sessionId).overrideWithValue(const []),
      ],
      child: const MaterialApp(home: SessionScreen(sessionId: _sessionId)),
    ),
  );
  await tester.pump();
  await tester.tap(find.byTooltip('Session actions'));
  await tester.pumpAndSettle();
}

void main() {
  group('capability predicates', () {
    test('no meta means no model and no thinking', () {
      expect(sessionCanPickModel(null), isFalse);
      expect(sessionCanSetThinking(null), isFalse);
    });

    test('a native agent advertising both supports both', () {
      const meta = SessionMeta(
        model: _model,
        thinking: 'medium',
        models: [_model],
      );
      expect(sessionCanPickModel(meta), isTrue);
      expect(sessionCanSetThinking(meta), isTrue);
    });

    test('an ACP agent with only modes supports neither', () {
      const meta = SessionMeta(
        thinking: '',
        models: [],
        modes: SessionModes(
          current: 'code',
          available: [SessionMode(id: 'code', name: 'Code')],
        ),
      );
      expect(sessionCanPickModel(meta), isFalse);
      expect(sessionCanSetThinking(meta), isFalse);
    });

    test('config options supersede the legacy fields', () {
      // SPEC-26: when an agent sends configOptions the composer swaps its
      // footer to them, so the legacy pickers are the wrong mechanism.
      const meta = SessionMeta(
        model: _model,
        thinking: 'high',
        models: [_model],
        configOptions: [
          SessionConfigOption(
            id: 'reasoning',
            name: 'Reasoning',
            category: 'reasoning',
            type: ConfigOptionType.select,
            currentValue: 'high',
            options: [ConfigOptionValue(value: 'high', name: 'High')],
          ),
        ],
      );
      expect(sessionCanPickModel(meta), isFalse);
      expect(sessionCanSetThinking(meta), isFalse);
    });
  });

  group('session actions menu', () {
    testWidgets('always offers rename and close', (tester) async {
      await _pumpMenu(tester, null);

      expect(find.text('Rename session'), findsOneWidget);
      expect(find.text('Close session'), findsOneWidget);
    });

    testWidgets('hides model and thinking when the agent has neither', (
      tester,
    ) async {
      await _pumpMenu(tester, null);

      expect(find.text('Model'), findsNothing);
      expect(find.text('Thinking'), findsNothing);
    });

    testWidgets('offers them when the agent advertises them', (tester) async {
      await _pumpMenu(
        tester,
        const SessionMeta(model: _model, thinking: 'medium', models: [_model]),
      );

      expect(find.text('Model'), findsOneWidget);
      expect(find.text('Thinking'), findsOneWidget);
    });

    testWidgets('offers only the model picker when thinking is unsupported', (
      tester,
    ) async {
      await _pumpMenu(
        tester,
        const SessionMeta(thinking: '', models: [_model], model: _model),
      );

      expect(find.text('Model'), findsOneWidget);
      expect(find.text('Thinking'), findsNothing);
    });

    testWidgets('offers only thinking when the model list is empty', (
      tester,
    ) async {
      // The mirror of the case above: an agent can advertise a thinking level
      // without a selectable model list.
      await _pumpMenu(tester, const SessionMeta(thinking: 'high', models: []));

      expect(find.text('Thinking'), findsOneWidget);
      expect(find.text('Model'), findsNothing);
    });

    testWidgets('keeps the divider when there is configuration above it', (
      tester,
    ) async {
      await _pumpMenu(
        tester,
        const SessionMeta(model: _model, thinking: 'medium', models: [_model]),
      );

      expect(find.byType(PopupMenuDivider), findsOneWidget);
    });

    testWidgets('leaves no dangling divider when the middle group is gone', (
      tester,
    ) async {
      await _pumpMenu(tester, null);

      // The divider exists only to separate the config actions from Close;
      // with no config actions it would be a rule under nothing.
      expect(find.byType(PopupMenuDivider), findsNothing);
      expect(find.byIcon(PhosphorIconsLight.moon), findsOneWidget);
    });
  });
}
