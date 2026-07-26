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

  @override
  Future<Map<String, dynamic>> request(
    MsgType type,
    Map<String, dynamic> body,
  ) async {
    if (body['kind'] == 'session.archive') {
      if (killFails) throw StateError('kill refused');
      return const {};
    }
    return const {};
  }
}

Session _session() => Session(
  id: 's1',
  projectId: 'p1',
  agent: 'pi',
  title: 'Wire up pairing',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  lastPreview: '',
  lastActivityAt: 0,
);

Future<void> _pumpTile(WidgetTester tester, {required bool killFails}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionControllerProvider.overrideWith(
          (ref) => _KillConnection(killFails: killFails),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(body: SessionTile(session: _session())),
      ),
    ),
  );
  await tester.pump();
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
}
