import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/recent_models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/composer_selectors.dart';

/// In-memory secure storage so ConnectionController boots without platform
/// channels (StoreController subscribes to it in its constructor).
class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

/// Records the session actions the composer issues so tests can assert the
/// unified renderer sends `configOption {id, value}` (and never merges locally).
class _FakeStore extends StoreController {
  _FakeStore(super.ref);

  final List<({String action, Map<String, dynamic>? args})> actions = [];

  @override
  void sendSessionAction(
    String sessionId,
    String action, {
    Map<String, dynamic>? args,
  }) {
    actions.add((action: action, args: args));
  }
}

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

/// Boots a container with a recording [_FakeStore] and an overridable
/// [sessionMetaProvider], mounting [child] under a MaterialApp.
Future<_FakeStore> _pump(
  WidgetTester tester, {
  required SessionMeta? meta,
  required Widget child,
  Session? session,
}) async {
  late _FakeStore store;
  final container = ProviderContainer(
    overrides: [
      sessionMetaProvider('s1').overrideWithValue(meta),
      sessionsProvider.overrideWithValue(
        SessionsState([session ?? _session()]),
      ),
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
      storeControllerProvider.overrideWith((ref) {
        store = _FakeStore(ref);
        return store;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  container.read(storeControllerProvider.notifier);
  return store;
}

SessionConfigOption _select({
  required String id,
  required String name,
  String? category,
  required String currentValue,
  List<ConfigOptionValue> options = const [],
  List<ConfigOptionGroup> groups = const [],
}) => SessionConfigOption(
  id: id,
  name: name,
  category: category,
  type: ConfigOptionType.select,
  currentValue: currentValue,
  options: options,
  groups: groups,
);

void main() {
  group('ComposerConfigOptions — rendering', () {
    testWidgets('model pill + folded chips + standalone mode pill', (
      tester,
    ) async {
      await _pump(
        tester,
        meta: SessionMeta(
          thinking: '',
          models: const [],
          configOptions: [
            _select(
              id: 'model',
              name: 'Model',
              category: 'model',
              currentValue: 'gpt-5',
              options: const [ConfigOptionValue(value: 'gpt-5', name: 'GPT-5')],
            ),
            _select(
              id: 'reasoning',
              name: 'Reasoning',
              category: 'thought_level',
              currentValue: 'high',
              options: const [
                ConfigOptionValue(value: 'low', name: 'low'),
                ConfigOptionValue(value: 'high', name: 'high'),
              ],
            ),
            _select(
              id: 'mode',
              name: 'Mode',
              category: 'mode',
              currentValue: 'code',
              options: const [
                ConfigOptionValue(value: 'ask', name: 'Ask'),
                ConfigOptionValue(value: 'code', name: 'Code'),
              ],
            ),
          ],
        ),
        child: const ComposerConfigOptions(sessionId: 's1'),
      );

      // The model pill shows the active model; reasoning folds into the model
      // pill as a signal-bar chip (no standalone 'high' label); mode stays a
      // separate pill after the model pill.
      final gpt5 = tester.getTopLeft(find.text('GPT-5'));
      final code = tester.getTopLeft(find.text('Code'));
      expect(gpt5.dx, lessThan(code.dx));
      expect(find.byType(ThinkingSignal), findsOneWidget);
      expect(find.text('high'), findsNothing);
    });

    testWidgets('empty configOptions renders nothing (legacy path elsewhere)', (
      tester,
    ) async {
      await _pump(
        tester,
        meta: const SessionMeta(thinking: '', models: []),
        child: const ComposerConfigOptions(sessionId: 's1'),
      );
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('boolean option shows its name as the pill label', (
      tester,
    ) async {
      await _pump(
        tester,
        meta: const SessionMeta(
          thinking: '',
          models: [],
          configOptions: [
            SessionConfigOption(
              id: 'web',
              name: 'Web search',
              type: ConfigOptionType.boolean,
              currentValue: false,
            ),
          ],
        ),
        child: const ComposerConfigOptions(sessionId: 's1'),
      );
      expect(find.text('Web search'), findsOneWidget);
    });
  });

  group('ComposerConfigOptions — actions', () {
    testWidgets('tapping a select pill opens a sheet and sends configOption', (
      tester,
    ) async {
      final store = await _pump(
        tester,
        meta: SessionMeta(
          thinking: '',
          models: const [],
          configOptions: [
            _select(
              id: 'mode',
              name: 'Mode',
              category: 'mode',
              currentValue: 'ask',
              options: const [
                ConfigOptionValue(value: 'ask', name: 'Ask'),
                ConfigOptionValue(value: 'code', name: 'Code'),
              ],
            ),
          ],
        ),
        child: const ComposerConfigOptions(sessionId: 's1'),
      );

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();
      // Sheet lists the choices.
      expect(find.text('Code'), findsOneWidget);
      await tester.tap(find.text('Code'));
      await tester.pumpAndSettle();

      expect(store.actions, hasLength(1));
      expect(store.actions.single.action, 'configOption');
      expect(store.actions.single.args, {'id': 'mode', 'value': 'code'});
    });

    testWidgets('model pill opens the picker menu and sends configOption', (
      tester,
    ) async {
      final store = await _pump(
        tester,
        meta: SessionMeta(
          thinking: '',
          models: const [],
          configOptions: [
            _select(
              id: 'model',
              name: 'Model',
              category: 'model',
              currentValue: 'gpt-5',
              options: const [
                ConfigOptionValue(value: 'gpt-5', name: 'GPT-5'),
                ConfigOptionValue(value: 'opus', name: 'Claude Opus'),
              ],
            ),
          ],
        ),
        child: const ComposerConfigOptions(sessionId: 's1'),
      );

      await tester.tap(find.text('GPT-5'));
      await tester.pumpAndSettle();
      // Empty query shows Recent (only the active model); hunt for the target.
      await tester.enterText(find.byType(TextField), 'Opus');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Claude Opus'));
      await tester.pumpAndSettle();

      expect(store.actions.single.action, 'configOption');
      expect(store.actions.single.args, {'id': 'model', 'value': 'opus'});
    });

    testWidgets('boolean pill toggles and sends the negated value', (
      tester,
    ) async {
      final store = await _pump(
        tester,
        meta: const SessionMeta(
          thinking: '',
          models: [],
          configOptions: [
            SessionConfigOption(
              id: 'web',
              name: 'Web search',
              type: ConfigOptionType.boolean,
              currentValue: false,
            ),
          ],
        ),
        child: const ComposerConfigOptions(sessionId: 's1'),
      );

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect(store.actions.single.action, 'configOption');
      expect(store.actions.single.args, {'id': 'web', 'value': true});
    });

    testWidgets('grouped select renders labeled sections', (tester) async {
      await _pump(
        tester,
        meta: SessionMeta(
          thinking: '',
          models: const [],
          configOptions: [
            _select(
              id: 'model',
              name: 'Model',
              category: 'model_config',
              currentValue: 'gpt-5',
              groups: const [
                ConfigOptionGroup(
                  name: 'OpenAI',
                  options: [ConfigOptionValue(value: 'gpt-5', name: 'GPT-5')],
                ),
                ConfigOptionGroup(
                  name: 'Anthropic',
                  options: [
                    ConfigOptionValue(value: 'opus', name: 'Claude Opus'),
                  ],
                ),
              ],
            ),
          ],
        ),
        child: const ComposerConfigOptions(sessionId: 's1'),
      );

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();
      // Group headers are shown as labeled sections alongside their choices.
      expect(find.text('OpenAI'), findsOneWidget);
      expect(find.text('Anthropic'), findsOneWidget);
      expect(find.text('Claude Opus'), findsOneWidget);
    });
  });

  group('ComposerConfigOptions — recents', () {
    testWidgets(
      'a live non-active model select records the value into recents',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            sessionMetaProvider('s1').overrideWithValue(
              SessionMeta(
                thinking: '',
                models: const [],
                configOptions: [
                  _select(
                    id: 'model',
                    name: 'Model',
                    category: 'model',
                    currentValue: 'gpt-5',
                    options: const [
                      ConfigOptionValue(value: 'gpt-5', name: 'GPT-5'),
                      ConfigOptionValue(value: 'opus', name: 'Claude Opus'),
                    ],
                  ),
                ],
              ),
            ),
            sessionsProvider.overrideWithValue(
              SessionsState([_session(agent: 'zed')]),
            ),
            connectionControllerProvider.overrideWith(
              (ref) => ConnectionController(const _EmptyStorage()),
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: Scaffold(body: ComposerConfigOptions(sessionId: 's1')),
            ),
          ),
        );

        // Recents start empty.
        expect(container.read(recentModelsControllerProvider), isEmpty);

        await tester.tap(find.text('GPT-5'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Opus');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Claude Opus'));
        await tester.pump();

        // The select is recorded optimistically on the gesture, per agent.
        expect(
          container
              .read(recentModelsControllerProvider.notifier)
              .recentModels('zed'),
          ['opus'],
        );
      },
    );
  });

  group('ComposerConfigOptions — dependent re-render', () {
    testWidgets('a changed configOptions list re-renders the pills', (
      tester,
    ) async {
      SessionMeta metaWith(String current, List<ConfigOptionValue> reasoning) =>
          SessionMeta(
            thinking: '',
            models: const [],
            configOptions: [
              _select(
                id: 'reasoning',
                name: 'Reasoning',
                category: 'thought_level',
                currentValue: current,
                options: reasoning,
              ),
            ],
          );

      // A StateProvider the meta override watches lets the test re-emit the
      // complete list, mirroring how the store refreshes configOptions.
      final metaCtrl = StateProvider<SessionMeta?>(
        (ref) => metaWith('low', const [
          ConfigOptionValue(value: 'low', name: 'low'),
        ]),
      );
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState([_session()])),
          connectionControllerProvider.overrideWith(
            (ref) => ConnectionController(const _EmptyStorage()),
          ),
          sessionMetaProvider('s1').overrideWith((ref) => ref.watch(metaCtrl)),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: ComposerConfigOptions(sessionId: 's1')),
          ),
        ),
      );
      expect(find.text('low'), findsOneWidget);
      expect(find.text('high'), findsNothing);

      // Dependent option recompute: the agent returns a new complete list.
      container.read(metaCtrl.notifier).state = metaWith('high', const [
        ConfigOptionValue(value: 'low', name: 'low'),
        ConfigOptionValue(value: 'high', name: 'high'),
      ]);
      await tester.pump();

      expect(find.text('high'), findsOneWidget);
    });
  });
}
