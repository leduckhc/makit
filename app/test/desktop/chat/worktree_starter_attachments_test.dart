/// SPEC-starter-pane-parity D6/D7 — the starter pane can attach images to the message that
/// *starts* the session. `POST /media` needs no session, so the only thing that
/// ever blocked this was the live pane's "a session must exist" guard.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/selected_worktree.dart';
import 'package:makit/desktop/chat/starter_prune.dart';
import 'package:makit/desktop/chat/worktree_starter.dart';
import 'package:makit/store/composer_attachments.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/media.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/media_client.dart';
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

final _key = starterDraftKey('p1', '/tmp/wt');
final _bytes = Uint8List.fromList([1, 2, 3]);

/// Records the spawn + send the starter performs, so the test can assert the
/// staged images rode along. [spawnFails] stages the "server refused" path.
class _FakeStore extends StoreController {
  _FakeStore(super.ref, {this.spawnFails = false});
  final bool spawnFails;
  int spawns = 0;
  final List<List<MediaAttachmentRef>> sent = [];

  /// The optimistic bubble's copy. Recorded separately: the user's own message
  /// must show its image, so a regression that forwards attachments to the wire
  /// but not to the transcript is a real one.
  final List<List<MediaAttachmentRef>> echoed = [];

  @override
  Future<String> spawnSession(
    String projectId, {
    String? title,
    String? agent,
    String? worktreePath,
    String? branch,
    List<ConfigOptionPick>? configOptions,
  }) async {
    spawns++;
    if (spawnFails) throw StateError('no worktree');
    return 's-new';
  }

  @override
  void appendOptimisticMessage(
    String sessionId,
    String text, {
    List<MediaAttachmentRef> attachments = const [],
  }) => echoed.add(attachments);

  @override
  void sendMessage(
    String sessionId,
    String text, {
    List<MediaAttachmentRef> attachments = const [],
  }) => sent.add(attachments);
}

Future<({ProviderContainer container, _FakeStore store})> _pump(
  WidgetTester tester, {
  bool withUploader = true,
  bool spawnFails = false,
}) async {
  late _FakeStore store;
  final container = ProviderContainer(
    overrides: [
      agentsProvider.overrideWith((ref) => [_agent]),
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
      // A reachable server is the paperclip's only precondition (D7).
      mediaUploaderProvider.overrideWithValue(
        withUploader
            ? (Uint8List bytes, String mime) async => MediaDescriptor(
                mediaId: 'a' * 64,
                mime: mime,
                sizeBytes: bytes.length,
              )
            : null,
      ),
      storeControllerProvider.overrideWith((ref) {
        store = _FakeStore(ref, spawnFails: spawnFails);
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
  return (container: container, store: store);
}

Future<void> _stage(ProviderContainer container) async {
  await container
      .read(composerAttachmentsProvider.notifier)
      .add(
        key: _key,
        localId: 'l1',
        bytes: _bytes,
        mime: 'image/png',
        name: 'shot.png',
      );
}

void main() {
  testWidgets('images staged for this worktree are shown by the starter', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _stage(h.container);
    await tester.pumpAndSettle();

    expect(find.text('shot.png'), findsOneWidget);
  });

  testWidgets('sending carries the staged images and clears them', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _stage(h.container);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'look at this');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(PhosphorIconsLight.arrowUp));
    await tester.pumpAndSettle();

    expect(h.store.spawns, 1);
    expect(h.store.sent.single.map((a) => a.mediaId), ['a' * 64]);
    expect(h.store.echoed.single.map((a) => a.mediaId), ['a' * 64]);
    // Sent images are gone from the strip: a second send cannot resend them.
    expect(
      h.container.read(composerAttachmentsProvider)[_key] ?? const [],
      isEmpty,
    );
  });

  testWidgets('a refused spawn leaves the images staged', (tester) async {
    final h = await _pump(tester, spawnFails: true);
    await _stage(h.container);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'look at this');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(PhosphorIconsLight.arrowUp));
    await tester.pumpAndSettle();

    expect(h.store.sent, isEmpty);
    // The upload is still valid — taking the chips here would make the user
    // pick the file again to retry a send that never happened.
    expect(h.container.read(composerAttachmentsProvider)[_key], hasLength(1));
  });

  testWidgets(
    'with no server to upload to, the paperclip is inert but says why',
    (tester) async {
      // D7's precondition is a reachable server and nothing else. Unpaired, the
      // paperclip stays visible and disabled with the reason (a connectivity gap
      // the user can fix), rather than vanishing or silently swallowing a pick.
      await _pump(tester, withUploader: false);

      final clip = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(PhosphorIconsLight.paperclip),
          matching: find.byType(IconButton),
        ),
      );
      expect(clip.onPressed, isNull);
      expect(clip.tooltip, 'Connect to your makit server to attach images');
    },
  );

  testWidgets('images already staged stay visible when the server goes away', (
    tester,
  ) async {
    // Losing the server mid-stage must not hide images the next send would still
    // carry — the chips are handed over regardless of `pick`.
    final h = await _pump(tester, withUploader: false);
    await _stage(h.container);
    await tester.pumpAndSettle();

    expect(find.text('shot.png'), findsOneWidget);
  });
}
