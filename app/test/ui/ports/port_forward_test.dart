// SPEC-44 P4b — the system-browser hand-off.
//
// The properties worth pinning: the confirm TELLS the user what they are getting
// (a link that is itself a credential, and a certificate warning), nothing is
// minted before they agree, the URL is built from the server this device is
// already talking to, and a grant that cannot be used is revoked instead of being
// left to time out.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/status/status_center.dart';
import 'package:makit/status/status_providers.dart';
import 'package:makit/ui/ports/port_forward.dart';

PortInfo _port() => const PortInfo(
  key: '48211:127.0.0.1:5173',
  port: 5173,
  address: '127.0.0.1',
  reach: PortReach.loopback,
  pid: 48211,
  command: '/opt/node_modules/.bin/vite --port 5173',
  startedAt: 1700000,
  worktreePath: '/wt/feat',
  openUrl: 'http://127.0.0.1:5173',
);

PairedServer _server() => PairedServer(
  host: '100.64.0.7',
  port: 9787,
  fingerprint: 'fp',
  bearer: 'tok',
  label: 'mac-mini',
);

void main() {
  group('forwardUrlFor', () {
    test('joins the grant path to the origin this device already reached', () {
      // Whatever address the app connected on is, by construction, one it can
      // reach — which is exactly why the server returns a path, not a URL.
      final url = forwardUrlFor(
        'https://100.64.0.7:9787',
        const ForwardGrant(
          grantId: 'G',
          port: 5173,
          path: '/forward/G/',
          expiresAt: 0,
          browser: true,
        ),
      );
      expect(url.toString(), 'https://100.64.0.7:9787/forward/G/');
    });

    test('no origin → no URL (never a guessed one)', () {
      expect(
        forwardUrlFor(
          null,
          const ForwardGrant(
            grantId: 'G',
            port: 5173,
            path: '/forward/G/',
            expiresAt: 0,
            browser: true,
          ),
        ),
        isNull,
      );
    });
  });

  group('confirmAndForwardPort', () {
    /// Pumps a button that runs the flow, with the socket replaced by a recorder.
    Future<List<Map<String, dynamic>>> run(
      WidgetTester tester, {
      required Map<String, dynamic> Function(Map<String, dynamic>) reply,
      PairedServer? server,
      StatusCenter? status,
    }) async {
      final sent = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            portsForwarderProvider.overrideWithValue(
              PortsForwarder((body) async {
                sent.add(body);
                return reply(body);
              }),
            ),
            connectionProvider.overrideWithValue(
              MakitConnState(
                servers: server == null ? const [] : [server],
                activeId: server?.id,
              ),
            ),
            if (status != null) statusCenterProvider.overrideWithValue(status),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => confirmAndForwardPort(context, ref, _port()),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return sent;
    }

    testWidgets('the confirm names the cost, and mints nothing until agreed', (
      tester,
    ) async {
      final sent = await run(
        tester,
        server: _server(),
        reply: (_) => {'grant': null},
      );
      expect(find.text('Open :5173 in your browser?'), findsOneWidget);
      // The two honest warnings: the link is a credential, and the cert is ours.
      expect(find.textContaining('certificate'), findsOneWidget);
      expect(find.textContaining('password'), findsOneWidget);
      expect(find.textContaining('without opening a port'), findsOneWidget);
      expect(sent, isEmpty, reason: 'no grant before consent');
    });

    testWidgets('Cancel sends nothing', (tester) async {
      final sent = await run(tester, server: _server(), reply: (_) => {});
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
    });

    testWidgets('confirming asks for a BROWSER grant', (tester) async {
      // `browser:true` is what makes the id a capability, and the app must say so
      // explicitly — the server never infers it.
      final sent = await run(
        tester,
        server: _server(),
        reply: (_) => {
          'grant': {
            'grantId': 'G',
            'port': 5173,
            'path': '/forward/G/',
            'expiresAt': 1,
            'browser': true,
          },
        },
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Open'));
      await tester.pumpAndSettle();
      expect(sent.first, {
        'kind': 'ports.forward',
        'worktreePath': '/wt/feat',
        'port': 5173,
        'browser': true,
      });
    });

    testWidgets('a refusal is shown verbatim — it names the actual rule', (
      tester,
    ) async {
      final center = StatusCenter();
      addTearDown(center.dispose);
      await run(
        tester,
        server: _server(),
        status: center,
        reply: (_) =>
            throw StateError('database and shell ports are never forwarded'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Open'));
      await tester.pumpAndSettle();
      expect(
        center.events.single.detail,
        contains('database and shell ports are never forwarded'),
      );
    });

    testWidgets('an unusable grant is REVOKED, not left to time out', (
      tester,
    ) async {
      // No paired server ⇒ no origin to open. Leaving the grant alive would keep a
      // capability in existence for 30 minutes for no reason.
      final sent = await run(
        tester,
        server: null,
        reply: (_) => {
          'grant': {
            'grantId': 'G',
            'port': 5173,
            'path': '/forward/G/',
            'expiresAt': 1,
            'browser': true,
          },
        },
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Open'));
      await tester.pumpAndSettle();
      expect(sent.map((s) => s['kind']), [
        'ports.forward',
        'ports.forward.stop',
      ]);
      expect(sent.last['grantId'], 'G');
    });
  });
}
