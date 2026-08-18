import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/docs.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/docs/publish_sheet.dart';
import 'package:qr_flutter/qr_flutter.dart';

DocGrant _grant({
  DocReach reach = DocReach.tailnet,
  String url = 'https://mac.tail.ts.net/docs/7f3a/mockups/x.html',
  int expiresAt = 0,
}) => DocGrant(
  grantId: '7f3a',
  worktreePath: '/repo',
  relPath: 'mockups/x.html',
  url: url,
  reach: reach,
  expiresAt: expiresAt,
);

/// In-memory secure storage so ConnectionController boots without platform
/// channels (mirrors repo_card_test.dart).
class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

/// A StoreController whose publish resolves on demand, so a test can land the
/// `docs.publish` reply AFTER the sheet is dismissed and assert the revoke.
class _FakeStore extends StoreController {
  _FakeStore(super.ref);

  final Completer<DocGrant> publishCompleter = Completer<DocGrant>();
  final List<String> unpublished = [];

  @override
  Future<DocGrant> publishDoc(String worktreePath, String relPath) =>
      publishCompleter.future;

  @override
  Future<void> unpublishDoc(String grantId) async {
    unpublished.add(grantId);
  }
}

Future<void> _pump(
  WidgetTester tester, {
  DocGrant? grant,
  String? error,
  int nowMs = 0,
  VoidCallback? onStop,
  VoidCallback? onOpen,
  VoidCallback? onCopy,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: PublishSheetBody(
        title: 'Board X',
        relPath: 'mockups/x.html',
        grant: grant,
        error: error,
        nowMs: nowMs,
        onStop: onStop ?? () {},
        onOpen: onOpen ?? () {},
        onCopy: onCopy ?? () {},
      ),
    ),
  ),
);

void main() {
  testWidgets('a successful grant shows the URL, a QR and the reach pill', (
    tester,
  ) async {
    await _pump(tester, grant: _grant());
    expect(find.textContaining('mac.tail.ts.net/docs/7f3a'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('tailnet'), findsOneWidget);
  });

  testWidgets('a lan grant is labelled lan (never invented as tailnet)', (
    tester,
  ) async {
    await _pump(tester, grant: _grant(reach: DocReach.lan));
    expect(find.text('lan'), findsOneWidget);
    expect(find.text('tailnet'), findsNothing);
  });

  testWidgets('Stop sharing revokes', (tester) async {
    var stopped = false;
    await _pump(tester, grant: _grant(), onStop: () => stopped = true);
    await tester.tap(find.text('Stop sharing'));
    expect(stopped, isTrue);
  });

  // The body is pure (data in, callbacks out), so it is responsible for firing
  // the action — not for performing it. The clipboard write and the "Link copied"
  // status post live in _PublishSheetState, which has a `ref`; doing them here
  // would have required a ProviderScope in every widget test of this body.
  testWidgets('Copy link fires onCopy', (tester) async {
    var copies = 0;
    await _pump(tester, grant: _grant(), onCopy: () => copies++);
    await tester.tap(find.text('Copy link'));
    await tester.pump();
    expect(copies, 1);
  });

  // The PR objectives list a stale expiry-timer fix, so the live "expires N min"
  // countdown deserves a test — every other case freezes at expired (nowMs ==
  // expiresAt == 0).
  testWidgets('a grant expiring ahead of now shows a live countdown', (
    tester,
  ) async {
    const thirtyMin = 30 * 60 * 1000;
    await _pump(tester, grant: _grant(expiresAt: thirtyMin), nowMs: 0);
    expect(find.text('expires 30 min'), findsOneWidget);
    expect(find.text('expired'), findsNothing);
  });

  // SPEC-doc-preview D9/D15 security: the user taps publish, dismisses the sheet, then
  // the docs.publish reply lands. The grant is live on the server with nothing
  // in the UI referencing it — a document stays shared the user believes they
  // cancelled. A grant arriving after dismissal must be revoked.
  group('grant arriving after dismissal', () {
    testWidgets('is revoked, not leaked', (tester) async {
      late _FakeStore store;
      final navKey = GlobalKey<NavigatorState>();
      final container = ProviderContainer(
        overrides: [
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

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: navKey,
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showPublishSheet(
                    context,
                    worktreePath: '/repo',
                    relPath: 'mockups/x.html',
                    title: 'Board X',
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pump(); // start the sheet's open animation
      await tester.pump(const Duration(milliseconds: 400)); // finish it
      // Sheet is up, publish is in flight (spinner) but not yet resolved.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Dismiss the sheet before the reply lands.
      navKey.currentState!.pop();
      await tester.pump(); // start the dismiss animation
      await tester.pump(const Duration(milliseconds: 400)); // finish it

      // Now the docs.publish reply arrives.
      store.publishCompleter.complete(_grant());
      await tester.pump();
      await tester.pump();

      expect(store.unpublished, [
        '7f3a',
      ], reason: 'a grant that lands after dismissal must be revoked');
    });
  });

  group('D15 — degrade loudly', () {
    testWidgets('a publish failure shows the reason, never a dead URL', (
      tester,
    ) async {
      await _pump(tester, error: 'tailscale serve is not available');
      expect(find.byKey(kPublishError), findsOneWidget);
      expect(
        find.textContaining('tailscale serve is not available'),
        findsOneWidget,
      );
      // No URL, no QR, no Stop sharing when there is nothing shared.
      expect(find.byType(QrImageView), findsNothing);
      expect(find.text('Stop sharing'), findsNothing);
    });

    testWidgets(
      'shows a spinner while neither grant nor error is present yet',
      (tester) async {
        await _pump(tester);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      },
    );
  });
}
