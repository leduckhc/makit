// Widget tests for [SessionTile]'s swipe-to-quit path. The quit request must
// run inside `confirmDismiss` and only remove the row once the server acks, so
// a FAILED kill leaves the row in place (the session is still in
// sessionsProvider) rather than optimistically dropping it.
//
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/ui/home/session_tile.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();

  @override
  Future<String?> read({required String key}) async => null;

  @override
  Future<void> write({required String key, required String? value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}

/// A connection whose `session.kill` request behaviour is configurable: it can
/// resolve (success) or throw (failure) so both dismiss outcomes are testable.
class _KillConnection extends ConnectionController {
  _KillConnection({required this.killFails}) : super(const _EmptyStorage());

  final bool killFails;

  /// How many archives were requested — the only thing a non-swipe quit can be
  /// held to, since removing the row is `Dismissible`'s job, not the archive's.
  int archiveCalls = 0;

  @override
  Future<Map<String, dynamic>> request(
    MsgType type,
    Map<String, dynamic> body,
  ) async {
    if (body['kind'] == 'session.archive') {
      archiveCalls++;
      if (killFails) throw StateError('kill refused');
      return const {};
    }
    return const {};
  }
}

Session _session({String? parentId, String? handoffReason}) => Session(
  id: 's1',
  projectId: 'p1',
  agent: 'pi',
  title: 'Wire up pairing',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  lastPreview: '',
  lastActivityAt: 0,
  parentId: parentId,
  handoffReason: handoffReason,
);

Future<void> _pumpSession(WidgetTester tester, Session session) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionControllerProvider.overrideWith(
          (ref) => _KillConnection(killFails: false),
        ),
      ],
      child: MaterialApp(home: Scaffold(body: SessionTile(session: session))),
    ),
  );
  await tester.pump();
}

Future<_KillConnection> _pumpTile(
  WidgetTester tester, {
  required bool killFails,
}) async {
  final conn = _KillConnection(killFails: killFails);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [connectionControllerProvider.overrideWith((ref) => conn)],
      child: MaterialApp(
        home: Scaffold(body: SessionTile(session: _session())),
      ),
    ),
  );
  await tester.pump();
  return conn;
}

Future<void> _swipeAndConfirm(WidgetTester tester) async {
  await tester.drag(find.byType(Dismissible), const Offset(-600, 0));
  await tester.pumpAndSettle();
  // The confirm dialog appears; approve the quit.
  expect(find.text('Quit session?'), findsOneWidget);
  await tester.tap(find.widgetWithText(FilledButton, 'Quit'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a failed kill keeps the row (no optimistic removal)', (
    tester,
  ) async {
    await _pumpTile(tester, killFails: true);

    await _swipeAndConfirm(tester);

    // The kill was refused, so confirmDismiss returned false and the row stays.
    expect(find.text('Wire up pairing'), findsOneWidget);
    expect(
      find.text('Could not quit: Bad state: kill refused'),
      findsOneWidget,
    );
  });

  testWidgets('a successful kill dismisses the row', (tester) async {
    await _pumpTile(tester, killFails: false);

    await _swipeAndConfirm(tester);

    // The server acked, so the row is dismissed.
    expect(find.text('Wire up pairing'), findsNothing);
  });

  // Swipe is invisible to assistive tech and awkward one-handed, so quit must
  // also be reachable without it.
  testWidgets('long-press reaches the same quit confirmation', (tester) async {
    final conn = await _pumpTile(tester, killFails: false);

    await tester.longPress(find.text('Wire up pairing'));
    await tester.pumpAndSettle();

    expect(find.text('Quit session?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Quit'));
    await tester.pumpAndSettle();

    // Confirming actually archives. The row is NOT asserted gone: the swipe
    // tests' removal comes from `Dismissible`, and a long-press has no dismiss
    // gesture to trigger it — in the app the row leaves when sessionsProvider
    // drops the session, which this standalone tile is not driven by.
    expect(conn.archiveCalls, 1);
  });

  // SPEC-46 D10: a handed-off session appears in the list on its own, so the
  // row must explain its lineage — including the outgoing agent's reason.
  testWidgets('a session with lineage captions the handoff reason', (
    tester,
  ) async {
    await _pumpSession(
      tester,
      _session(parentId: 's0', handoffReason: 'ran out of context'),
    );

    expect(
      find.textContaining('Handed off'),
      findsOneWidget,
    );
    expect(find.textContaining('ran out of context'), findsOneWidget);
  });

  // Most sessions are not handoffs; a caption on all of them would be noise.
  testWidgets('a session with no lineage shows no caption', (tester) async {
    await _pumpSession(tester, _session());

    expect(find.textContaining('Handed off'), findsNothing);
  });

  // The parent may be archived or simply uncached, so the caption must still
  // render — it is absent exactly when the user is most confused otherwise.
  testWidgets('lineage to an unknown parent still captions', (tester) async {
    await _pumpSession(
      tester,
      _session(parentId: 'not-in-app', handoffReason: 'stuck on a rebase'),
    );

    expect(find.textContaining('Handed off'), findsOneWidget);
    expect(find.textContaining('stuck on a rebase'), findsOneWidget);
  });

  // SPEC-46 U4: a *fork* sets `parentId` with no `handoffReason` — it is an
  // adapter-native branch of the conversation, not a written handoff (D6). The
  // fallback wording must therefore not claim a handoff happened, or every forked
  // session is mislabelled in the one place the user meets it.
  testWidgets('lineage without a reason does not claim a handoff', (
    tester,
  ) async {
    await _pumpSession(tester, _session(parentId: 's0'));

    expect(find.textContaining('Continued from'), findsOneWidget);
    expect(find.textContaining('Handed off'), findsNothing);
  });

  testWidgets('quit is published as a semantics action for screen readers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpTile(tester, killFails: false);

    // The action exists in the semantics tree, so VoiceOver/TalkBack can invoke
    // it without any gesture.
    expect(
      tester
          .getSemantics(find.byType(SessionTile))
          .getSemanticsData()
          .customSemanticsActionIds,
      isNotEmpty,
    );
    handle.dispose();
  });
}
