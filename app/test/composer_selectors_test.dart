import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/composer.dart';
import 'package:makit/ui/composer/composer_selectors.dart';

void _noop(String _) {}

/// Uses an agent name that is NOT one of the bundled logos (pi/codex/claude)
/// so [AgentAvatar] renders a text initial instead of loading an SVG asset.
Session _session({String agent = 'zed'}) => Session(
  id: 's1',
  projectId: 'p1',
  agent: agent,
  title: 'Test',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  lastPreview: '',
  lastActivityAt: 0,
);

ProviderContainer _container({SessionMeta? meta, Session? session}) {
  final c = ProviderContainer(
    overrides: [
      sessionMetaProvider('s1').overrideWithValue(meta),
      sessionsProvider.overrideWithValue(
        SessionsState([session ?? _session()]),
      ),
    ],
  );
  return c;
}

Widget _wrap(ProviderContainer c, Widget child) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(home: Scaffold(body: child)),
);

void main() {
  const modelA = ModelInfo(provider: 'openai', id: 'gpt-5', name: 'GPT-5');

  group('ComposerModelSelector', () {
    testWidgets('hidden until session.meta arrives (meta null)', (
      tester,
    ) async {
      final c = _container(meta: null);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        _wrap(c, const ComposerModelSelector(sessionId: 's1')),
      );
      expect(find.text('GPT-5'), findsNothing);
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('hidden while the available-models list is empty', (
      tester,
    ) async {
      final c = _container(
        meta: const SessionMeta(model: modelA, thinking: '', models: []),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        _wrap(c, const ComposerModelSelector(sessionId: 's1')),
      );
      expect(find.text('GPT-5'), findsNothing);
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('shows the current model name once models are available', (
      tester,
    ) async {
      final c = _container(
        meta: const SessionMeta(model: modelA, thinking: '', models: [modelA]),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        _wrap(c, const ComposerModelSelector(sessionId: 's1')),
      );
      expect(find.text('GPT-5'), findsOneWidget);
      expect(find.byType(InkWell), findsOneWidget);
    });
  });

  group('ComposerThinkingSelector', () {
    testWidgets('hidden when the agent has no thinking support (empty)', (
      tester,
    ) async {
      final c = _container(
        meta: const SessionMeta(model: modelA, thinking: '', models: [modelA]),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        _wrap(c, const ComposerThinkingSelector(sessionId: 's1')),
      );
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('shows the current thinking level', (tester) async {
      final c = _container(
        meta: const SessionMeta(
          model: modelA,
          thinking: 'medium',
          models: [modelA],
        ),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        _wrap(c, const ComposerThinkingSelector(sessionId: 's1')),
      );
      expect(find.text('medium'), findsOneWidget);
      expect(find.byType(InkWell), findsOneWidget);
    });
  });

  testWidgets(
    'long model label ellipsizes in a narrow composer footer (no overflow)',
    (tester) async {
      const longModel = ModelInfo(
        provider: 'anthropic',
        id: 'claude-3-5-sonnet-20241022',
        name: 'claude-3-5-sonnet-20241022-very-long-model-name',
      );
      final c = _container(
        meta: const SessionMeta(
          model: longModel,
          thinking: 'medium',
          models: [longModel],
        ),
      );
      addTearDown(c.dispose);

      await tester.pumpWidget(
        _wrap(
          c,
          const SizedBox(
            width: 320, // narrow (phone) width
            child: Composer(
              onSend: _noop,
              alwaysExpanded: true,
              footerActions: [
                ComposerModelSelector(sessionId: 's1'),
                ComposerThinkingSelector(sessionId: 's1'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // A RenderFlex overflow would surface as a thrown exception during layout.
      expect(tester.takeException(), isNull);
      // The real selector renders its label and constrains it to a single
      // ellipsized line, so it shrinks under the footer's Flexible instead of
      // wrapping or overflowing.
      final label = tester.widget<Text>(
        find.text('claude-3-5-sonnet-20241022-very-long-model-name'),
      );
      expect(label.maxLines, 1);
      expect(label.overflow, TextOverflow.ellipsis);
    },
  );
}
