/// SPEC-starter-pane-parity D3/D4 — the starter pane's slash palette. There is no session yet,
/// so agent commands can only come from what a live session in this project
/// already advertised (`CachedCommandsController`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/selected_worktree.dart';
import 'package:makit/desktop/chat/worktree_starter.dart';
import 'package:makit/store/cached_commands.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

const _zed = AgentDescriptor(
  id: 'zed',
  label: 'Zed',
  transport: 'acp',
  available: true,
);
const _codex = AgentDescriptor(
  id: 'codex',
  label: 'Codex',
  transport: 'native',
  available: true,
);

const _skill = SlashCmd(
  name: 'skill:makit-computer-use',
  description: 'Drive the desktop',
  source: 'skill',
  location: 'project',
);

Future<CachedCommandsController> _pump(
  WidgetTester tester, {
  List<AgentDescriptor> agents = const [_zed],
}) async {
  final cache = CachedCommandsController.ephemeral();
  final container = ProviderContainer(
    overrides: [
      agentsProvider.overrideWith((ref) => agents),
      cachedCommandsControllerProvider.overrideWith((ref) => cache),
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
  return cache;
}

void main() {
  testWidgets('the starter palette offers this project\'s cached commands', (
    tester,
  ) async {
    final cache = await _pump(tester);
    await cache.record(agent: 'zed', projectId: 'p1', commands: [_skill]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '/computer');
    await tester.pumpAndSettle();

    expect(find.text('/skill:makit-computer-use'), findsOneWidget);
  });

  testWidgets('commands cached for another harness are not offered', (
    tester,
  ) async {
    // The selected harness is `zed` (first available); the cache only knows
    // codex's commands, which are a different agent's palette.
    final cache = await _pump(tester);
    await cache.record(agent: 'codex', projectId: 'p1', commands: [_skill]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '/computer');
    await tester.pumpAndSettle();

    expect(find.text('/skill:makit-computer-use'), findsNothing);
  });

  testWidgets('switching the harness switches the cached palette', (
    tester,
  ) async {
    final cache = await _pump(tester, agents: const [_zed, _codex]);
    await cache.record(agent: 'codex', projectId: 'p1', commands: [_skill]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Codex'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '/computer');
    await tester.pumpAndSettle();

    expect(find.text('/skill:makit-computer-use'), findsOneWidget);
  });

  testWidgets('the starter palette offers no client commands', (tester) async {
    // `/model`, `/cancel`, `/compact`… are intercepted app-side by
    // `handleClientCommand`, which requires a sessionId — so this pane cannot
    // run them, and its send path does not even try. Offering them would spawn a
    // session whose first message is the literal text "/model" (SPEC-starter-pane-parity D8, the
    // same reasoning SPEC-pending-queue-edit-reorder applied to queued messages).
    final cache = await _pump(tester);
    await cache.record(agent: 'zed', projectId: 'p1', commands: [_skill]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '/');
    await tester.pumpAndSettle();

    expect(find.text('/model'), findsNothing);
    expect(find.text('/cancel'), findsNothing);
    // The agent's own commands are exactly what this palette is for.
    expect(find.text('/skill:makit-computer-use'), findsOneWidget);
  });

  testWidgets('commands cached for another project are not offered', (
    tester,
  ) async {
    // Command lists are cwd-dependent, which is why the cache is keyed by
    // project as well as harness (D3). Without this, only the agent half of
    // `commandsFor` was constrained, and a repo-wide key would have passed.
    final cache = await _pump(tester);
    await cache.record(
      agent: 'zed',
      projectId: 'some-other-project',
      commands: [_skill],
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '/computer');
    await tester.pumpAndSettle();

    expect(find.text('/skill:makit-computer-use'), findsNothing);
  });
}
