import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/docs.dart';
import 'package:makit/ui/docs/publish_sheet.dart';
import 'package:qr_flutter/qr_flutter.dart';

DocGrant _grant({
  DocReach reach = DocReach.tailnet,
  String url = 'https://mac.tail.ts.net/docs/7f3a/mockups/x.html',
}) => DocGrant(
  grantId: '7f3a',
  worktreePath: '/repo',
  relPath: 'mockups/x.html',
  url: url,
  reach: reach,
  expiresAt: 0,
);

Future<void> _pump(
  WidgetTester tester, {
  DocGrant? grant,
  String? error,
  VoidCallback? onStop,
  VoidCallback? onOpen,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: PublishSheetBody(
        title: 'Board X',
        relPath: 'mockups/x.html',
        grant: grant,
        error: error,
        nowMs: 0,
        onStop: onStop ?? () {},
        onOpen: onOpen ?? () {},
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

  testWidgets('Copy link copies the URL to the clipboard', (tester) async {
    // Clipboard.getData/setData has NO default mock in flutter_test; install a
    // handler so the call completes rather than hanging.
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pump(tester, grant: _grant());
    await tester.tap(find.text('Copy link'));
    await tester.pump();
    expect(copied.single, contains('mac.tail.ts.net/docs/7f3a'));
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
