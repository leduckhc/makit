import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_chat_pane.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/media.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/session/media_view.dart';

import '../media_client_test.dart' show kPng;

/// The macOS desktop pane renders the shared [chatItemWidget] set, so media has
/// to work there too — the desktop self-pairs over loopback and fetches from the
/// same /media route.
/// Starts unpaired, so the pane's store doesn't boot a real WS connection from
/// this machine's persisted pairing (which a test env can't complete).
class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

Session _session() => Session(
  id: 's1',
  projectId: 'p1',
  agent: 'pi',
  title: 'Test session',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  lastPreview: '',
  lastActivityAt: 0,
);

Future<void> _pump(WidgetTester tester, {required String mediaId}) async {
  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
      sessionsProvider.overrideWithValue(SessionsState([_session()])),
      eventsProvider.overrideWithValue(EventsState(const {}, const {})),
      chatItemsProvider('s1').overrideWithValue([
        AgentMediaItem(
          seq: 1,
          ts: 0,
          mediaId: mediaId,
          mime: 'image/png',
          alt: 'shot.png',
        ),
      ]),
      mediaFetcherProvider.overrideWithValue((_) async => kPng),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: DesktopChatPane(sessionId: 's1')),
      ),
    ),
  );
  // The pane builds its transcript through a few layout passes, so give the
  // image stream several real-time frames to resolve.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 40));
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

void main() {
  testWidgets('the desktop pane renders an agent media row', (tester) async {
    await tester.runAsync(() => _pump(tester, mediaId: '1' * 64));
    expect(find.byType(AgentMediaView), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(MediaPlaceholder), findsNothing);
  });

  testWidgets('tapping it opens fullscreen (the pane has a Navigator)', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await _pump(tester, mediaId: '2' * 64);
      await tester.tap(find.byType(AgentMediaView));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await tester.pumpAndSettle();
    });
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });
}
