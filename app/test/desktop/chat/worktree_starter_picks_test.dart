/// SPEC-45 D2 — the starter pane's *pending session* survives the tab switch
/// that recreates it: not only the typed message, but the harness it will run
/// and the model / reasoning picks that ride the spawn.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/harness_picker.dart' show HarnessCard;
import 'package:makit/desktop/chat/selected_worktree.dart';
import 'package:makit/desktop/chat/starter_picks.dart';
import 'package:makit/desktop/chat/worktree_starter.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/composer_selectors.dart' show ModelConfigPill;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

const _key = 'starter:/tmp/wt';

/// Two available harnesses, each with its own catalog — `pi` is the default
/// (first available), so choosing `codex` is an observable user gesture.
const _pi = AgentDescriptor(
  id: 'pi',
  label: 'Pi',
  transport: 'acp',
  available: true,
  configOptions: [
    SessionConfigOption(
      id: 'model',
      name: 'Model',
      category: 'model',
      type: ConfigOptionType.select,
      currentValue: 'sonnet',
      options: [
        ConfigOptionValue(value: 'sonnet', name: 'Sonnet'),
        ConfigOptionValue(value: 'opus', name: 'Claude Opus'),
      ],
    ),
  ],
);
const _codex = AgentDescriptor(
  id: 'codex',
  label: 'Codex',
  transport: 'native',
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
        ConfigOptionValue(value: 'gpt-5-codex', name: 'GPT-5 Codex'),
      ],
    ),
  ],
);

/// Records the spawn so the test can assert the restored picks ride it.
class _FakeStore extends StoreController {
  _FakeStore(super.ref);
  String? agent;
  List<ConfigOptionPick>? picks;

  @override
  Future<String> spawnSession(
    String projectId, {
    String? title,
    String? agent,
    String? worktreePath,
    String? branch,
    List<ConfigOptionPick>? configOptions,
  }) async {
    this.agent = agent;
    picks = configOptions;
    return 's-new';
  }

  @override
  void appendOptimisticMessage(
    String sessionId,
    String text, {
    List<MediaAttachmentRef> attachments = const [],
  }) {}

  @override
  void sendMessage(
    String sessionId,
    String text, {
    List<MediaAttachmentRef> attachments = const [],
  }) {}
}

({ProviderContainer container, _FakeStore store}) _container() {
  late _FakeStore store;
  final container = ProviderContainer(
    overrides: [
      agentsProvider.overrideWith((ref) => [_pi, _codex]),
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
  container.read(storeControllerProvider.notifier);
  return (container: container, store: store);
}

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
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
);

/// The tab switch: this pane is disposed, another is built, the user returns.
Future<void> _remount(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SizedBox())),
    ),
  );
  await tester.pumpAndSettle();
  await tester.pumpWidget(_app(container));
  await tester.pumpAndSettle();
}

bool _isSelected(WidgetTester tester, String label) {
  final card = tester.widget<HarnessCard>(
    find.ancestor(of: find.text(label), matching: find.byType(HarnessCard)),
  );
  return card.selected;
}

Future<void> _pickModel(WidgetTester tester, String from, String to) async {
  await tester.tap(find.text(from));
  await tester.pumpAndSettle();
  await tester.tap(find.text(to).last);
  await tester.pumpAndSettle();
  // Close the sheet, which SPEC-31 keeps open after a pick.
  await tester.tapAt(const Offset(10, 10));
  await tester.pumpAndSettle();
}

Future<void> _send(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), 'go');
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(PhosphorIconsLight.arrowUp));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the chosen harness survives the pane being recreated', (
    tester,
  ) async {
    final h = _container();
    await tester.pumpWidget(_app(h.container));
    await tester.pumpAndSettle();
    expect(_isSelected(tester, 'Pi'), isTrue, reason: 'default is first');

    await tester.tap(find.text('Codex'));
    await tester.pumpAndSettle();
    await _remount(tester, h.container);

    expect(_isSelected(tester, 'Codex'), isTrue);
    expect(_isSelected(tester, 'Pi'), isFalse);
  });

  testWidgets('a model pick survives the pane being recreated', (tester) async {
    final h = _container();
    await tester.pumpWidget(_app(h.container));
    await tester.pumpAndSettle();

    await _pickModel(tester, 'Sonnet', 'Claude Opus');
    await _remount(tester, h.container);

    expect(
      find.descendant(
        of: find.byType(ModelConfigPill),
        matching: find.text('Claude Opus'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the restored picks ride the spawn', (tester) async {
    final h = _container();
    await tester.pumpWidget(_app(h.container));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Codex'));
    await tester.pumpAndSettle();
    await _pickModel(tester, 'GPT-5', 'GPT-5 Codex');
    await _remount(tester, h.container);

    await _send(tester);

    expect(h.store.agent, 'codex');
    expect(h.store.picks?.single.id, 'model');
    expect(h.store.picks?.single.value, 'gpt-5-codex');
  });

  testWidgets('changing the harness still drops the previous catalog picks', (
    tester,
  ) async {
    final h = _container();
    await tester.pumpWidget(_app(h.container));
    await tester.pumpAndSettle();

    await _pickModel(tester, 'Sonnet', 'Claude Opus');
    await tester.tap(find.text('Codex'));
    await tester.pumpAndSettle();

    // `opus` is not in codex's catalog, so carrying it over would send a pick
    // the harness cannot honour.
    expect(h.container.read(starterPicksProvider)[_key]?.picks, isEmpty);
    expect(
      find.descendant(
        of: find.byType(ModelConfigPill),
        matching: find.text('GPT-5'),
      ),
      findsOneWidget,
    );
  });

  testWidgets("another worktree's starter does not inherit the picks", (
    tester,
  ) async {
    final h = _container();
    await tester.pumpWidget(_app(h.container));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Codex'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: const MaterialApp(
          home: Scaffold(
            body: WorktreeStarter(
              worktree: SelectedWorktree(
                projectId: 'p1',
                path: '/tmp/other',
                branch: 'other',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_isSelected(tester, 'Pi'), isTrue);
    expect(
      h.container.read(starterPicksProvider)['starter:/tmp/other'],
      isNull,
    );
  });

  testWidgets('a started session clears the pending picks', (tester) async {
    final h = _container();
    await tester.pumpWidget(_app(h.container));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Codex'));
    await tester.pumpAndSettle();

    await _send(tester);

    // The pending session became a real one; its draft state is spent, exactly
    // as the sent message's draft text is pruned.
    expect(h.container.read(starterPicksProvider)[_key], isNull);
  });
}
