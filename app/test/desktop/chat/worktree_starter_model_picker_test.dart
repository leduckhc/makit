import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/selected_worktree.dart';
import 'package:makit/desktop/chat/worktree_starter.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/recent_models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/composer_selectors.dart' show ModelConfigPill;
import 'package:makit/ui/composer/model_picker_menu.dart'
    show kModelFlyoutCaretIcon;

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

/// Records session actions so the test can assert the draft never dispatches a
/// live `configOption` (it only mutates local picks).
class _FakeStore extends StoreController {
  _FakeStore(super.ref);
  final List<String> actions = [];
  @override
  void sendSessionAction(
    String sessionId,
    String action, {
    Map<String, dynamic>? args,
  }) {
    actions.add(action);
  }
}

const _agent = AgentDescriptor(
  id: 'zed',
  label: 'Zed',
  transport: 'acp',
  available: true,
  configOptions: [
    SessionConfigOption(
      id: 'model',
      name: 'Model',
      category: 'model',
      type: ConfigOptionType.select,
      currentValue: 'gpt-5',
      options: [
        ConfigOptionValue(value: 'gpt-5', name: 'GPT-5'),
        ConfigOptionValue(value: 'opus', name: 'Claude Opus'),
      ],
    ),
    SessionConfigOption(
      id: 'reasoning',
      name: 'Reasoning',
      category: 'thought_level',
      type: ConfigOptionType.select,
      currentValue: 'low',
      options: [
        ConfigOptionValue(value: 'low', name: 'low'),
        ConfigOptionValue(value: 'high', name: 'high'),
      ],
    ),
  ],
);

Future<({_FakeStore store, ProviderContainer container})> _pump(
  WidgetTester tester,
) async {
  late _FakeStore store;
  final container = ProviderContainer(
    overrides: [
      agentsProvider.overrideWith((ref) => [_agent]),
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
      child: const MaterialApp(
        home: Scaffold(
          body: WorktreeStarter(
            worktree: SelectedWorktree(
              projectId: 'p1',
              path: '/tmp/wt',
              branch: 'feat',
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (store: store, container: container);
}

void main() {
  testWidgets('draft footer shows the model pill from the harness catalog', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byType(ModelConfigPill), findsOneWidget);
    expect(find.text('GPT-5'), findsOneWidget);
  });

  testWidgets(
    'draft model select updates local picks without recents or actions',
    (tester) async {
      final harness = await _pump(tester);

      await tester.tap(find.text('GPT-5'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == 'Search models…',
        ),
        'Opus',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Claude Opus'));
      await tester.pumpAndSettle();

      // The sheet stays open (no pop); the footer chip behind it reflects the
      // new local pick. Scope to the footer pill to disambiguate from the
      // open sheet's own result row.
      expect(
        find.descendant(
          of: find.byType(ModelConfigPill),
          matching: find.text('Claude Opus'),
        ),
        findsOneWidget,
      );
      // No live action dispatched, and recents are untouched (draft gesture).
      expect(harness.store.actions, isEmpty);
      expect(harness.container.read(recentModelsControllerProvider), isEmpty);
    },
  );

  testWidgets('draft flyout tuning records a local pick, no action', (
    tester,
  ) async {
    final harness = await _pump(tester);

    await tester.tap(find.text('GPT-5'));
    await tester.pumpAndSettle();
    // Open the flyout for the active model and pick a reasoning value.
    await tester.tap(find.byIcon(kModelFlyoutCaretIcon));
    await tester.pumpAndSettle();
    await tester.tap(find.text('high'));
    await tester.pumpAndSettle();

    expect(harness.store.actions, isEmpty);
  });
}
