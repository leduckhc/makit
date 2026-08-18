/// SPEC-starter-pane-parity — what the starter pane holds on to across the tab switch that
/// recreates it: the typed message (D1) and the staged attachments (D6).
///
/// The starter used to own a bare `TextEditingController`, so `split_view.dart`
/// keying `DesktopChatPane` by tab id destroyed the half-typed first message.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/selected_worktree.dart';
import 'package:makit/desktop/chat/starter_prune.dart';
import 'package:makit/desktop/chat/worktree_starter.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/composer_draft.dart';
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

const _agent = AgentDescriptor(
  id: 'zed',
  label: 'Zed',
  transport: 'acp',
  available: true,
);

/// A store whose spawn always fails, to stage the refused-send path. [gate] lets
/// a test hold the spawn open long enough to unmount the pane under it.
class _RefusingStore extends StoreController {
  _RefusingStore(super.ref, {this.gate});
  final Future<void>? gate;
  @override
  Future<String> spawnSession(
    String projectId, {
    String? title,
    String? agent,
    String? worktreePath,
    String? branch,
    List<ConfigOptionPick>? configOptions,
  }) async {
    if (gate != null) await gate;
    throw StateError('worktree is gone');
  }
}

ProviderContainer _container({bool refuseSpawn = false, Future<void>? gate}) {
  final container = ProviderContainer(
    overrides: [
      agentsProvider.overrideWith((ref) => [_agent]),
      if (refuseSpawn)
        storeControllerProvider.overrideWith(
          (ref) => _RefusingStore(ref, gate: gate),
        ),
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Widget _app(ProviderContainer container, {String path = '/tmp/wt'}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: WorktreeStarter(
            // Keyed by path so remounting for another worktree is a different
            // element, mirroring the tab-keyed pane.
            key: ValueKey(path),
            worktree: SelectedWorktree(
              projectId: 'p1',
              path: path,
              branch: 'feat',
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('the starter persists its draft under a worktree-scoped key', (
    tester,
  ) async {
    final container = _container();
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'half typed');
    await tester.pumpAndSettle();

    expect(
      container.read(composerDraftsProvider)[starterDraftKey('p1', '/tmp/wt')],
      'half typed',
    );
  });

  testWidgets('a recreated starter re-seeds the draft it was typed into', (
    tester,
  ) async {
    final container = _container();
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'survives the tab switch');
    await tester.pumpAndSettle();

    // The tab switch: the pane (and with it the starter) is disposed and a
    // different one is built, then the user comes back.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SizedBox())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    expect(find.text('survives the tab switch'), findsOneWidget);
  });

  testWidgets("another worktree's starter does not inherit the draft", (
    tester,
  ) async {
    final container = _container();
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'wt one');
    await tester.pumpAndSettle();

    await tester.pumpWidget(_app(container, path: '/tmp/other'));
    await tester.pumpAndSettle();

    expect(find.text('wt one'), findsNothing);
    expect(
      container.read(composerDraftsProvider)[starterDraftKey('p1', '/tmp/wt')],
      'wt one',
    );
    expect(
      container.read(composerDraftsProvider)[starterDraftKey(
        'p1',
        '/tmp/other',
      )],
      isNull,
    );
  });

  testWidgets('a refused spawn gives the message back', (tester) async {
    // The composer clears its field on send, so without a restore the text is
    // gone for a send that never happened — while its attachments (D6) stayed.
    final container = _container(refuseSpawn: true);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'never left the pane');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(PhosphorIconsLight.arrowUp));
    await tester.pumpAndSettle();

    expect(find.text('never left the pane'), findsOneWidget);
    expect(
      container.read(composerDraftsProvider)[starterDraftKey('p1', '/tmp/wt')],
      'never left the pane',
    );
  });

  testWidgets('a spawn refused after the pane is gone still keeps the message', (
    tester,
  ) async {
    // Switching tabs while the spawn is in flight disposes this pane. If the
    // spawn then fails, the restore must still land in the draft store: the
    // composer already cleared its field on send, so bailing out on `!mounted`
    // was the difference between "your message is waiting for you" and gone.
    final gate = Completer<void>();
    final container = _container(refuseSpawn: true, gate: gate.future);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'sent into the void');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(PhosphorIconsLight.arrowUp));
    await tester.pump();

    // The tab switch, mid-spawn.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SizedBox())),
      ),
    );
    await tester.pumpAndSettle();

    gate.complete();
    await tester.pumpAndSettle();

    expect(
      container.read(composerDraftsProvider)[starterDraftKey('p1', '/tmp/wt')],
      'sent into the void',
    );
  });
}
