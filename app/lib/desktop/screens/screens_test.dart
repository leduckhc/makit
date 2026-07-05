/// Widget tests for the SPEC-03 desktop control screens.
///
/// Every test drives a screen through a [FakeControlClient] injected via a
/// `ProviderScope` override, covering the data, empty, and error states.
library;

// This test lives beside the screens (per SPEC-03 Stream C layout), so it
// imports the flutter_test dev-dependency from a lib/ path.
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pino/control/control_contract.dart';
import 'package:pino/desktop/screens/devices_screen.dart';
import 'package:pino/desktop/screens/fake_control_client.dart';
import 'package:pino/desktop/screens/providers.dart';
import 'package:pino/desktop/screens/qr_screen.dart';
import 'package:pino/desktop/screens/session_log_screen.dart';
import 'package:pino/desktop/screens/sessions_screen.dart';
import 'package:pino/desktop/screens/status_screen.dart';

StatusData _status() => const StatusData(
  pid: 4242,
  uptimeMs: 8000000,
  host: '127.0.0.1',
  port: 8317,
  fingerprint: 'AA:BB:CC:DD',
  advertiseHost: 'macbook.local',
  pairedDevices: 2,
  runningSessions: 1,
  version: '0.1.0',
);

List<DeviceInfo> _devices() => [
  DeviceInfo(
    id: 'd1',
    label: 'iPhone 15',
    pairedAt: DateTime.now()
        .subtract(const Duration(days: 3))
        .millisecondsSinceEpoch,
    lastSeenAt: DateTime.now()
        .subtract(const Duration(minutes: 5))
        .millisecondsSinceEpoch,
    connected: true,
  ),
];

List<SessionDto> _sessions() => [
  SessionDto(
    id: 's1',
    title: 'Refactor auth',
    status: 'running',
    projectId: 'p1',
    lastActivityAt: DateTime.now()
        .subtract(const Duration(minutes: 2))
        .millisecondsSinceEpoch,
  ),
];

Widget _host(ControlClient client, Widget child) => ProviderScope(
  overrides: [controlClientProvider.overrideWithValue(client)],
  child: MaterialApp(home: child),
);

void main() {
  group('StatusScreen', () {
    testWidgets('renders status fields once loaded', (tester) async {
      final client = FakeControlClient(status: _status());
      await tester.pumpWidget(_host(client, const StatusScreen()));
      await tester.pumpAndSettle();

      expect(find.text('4242'), findsOneWidget);
      expect(find.textContaining('AA:BB:CC:DD'), findsOneWidget);
      expect(find.textContaining('127.0.0.1:8317'), findsOneWidget);
      expect(find.text('0.1.0'), findsOneWidget);
    });

    testWidgets('shows a loading indicator while fetching', (tester) async {
      final client = FakeControlClient(status: _status());
      await tester.pumpWidget(_host(client, const StatusScreen()));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('renders an error state with a retry button', (tester) async {
      final client = FakeControlClient(throwOnStatus: true);
      await tester.pumpWidget(_host(client, const StatusScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('refresh button re-fetches status', (tester) async {
      final client = FakeControlClient(status: _status());
      await tester.pumpWidget(_host(client, const StatusScreen()));
      await tester.pumpAndSettle();
      expect(client.statusCalls, 1);

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(client.statusCalls, 2);
    });
  });

  group('QrScreen', () {
    testWidgets('mints when no current token and shows the QR + url', (
      tester,
    ) async {
      final client = FakeControlClient(
        current: null,
        mint: const PairMintData(
          url: 'pino://pair?t=abc',
          token: 'abc',
          expiresAt: 9999999999999,
          fingerprint: 'AA:BB',
        ),
      );
      await tester.pumpWidget(_host(client, const QrScreen()));
      // Resolve pairCurrent (null) then pairMint.
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 60));

      expect(client.pairCurrentCalls, 1);
      expect(client.pairMintCalls, 1);
      expect(find.textContaining('pino://pair?t=abc'), findsOneWidget);
    });

    testWidgets('uses the current token when one exists', (tester) async {
      final client = FakeControlClient(
        current: const PairCurrentData(
          url: 'pino://pair?t=live',
          token: 'live',
          expiresAt: 9999999999999,
        ),
      );
      await tester.pumpWidget(_host(client, const QrScreen()));
      await tester.pump(const Duration(milliseconds: 60));

      expect(client.pairMintCalls, 0);
      expect(find.textContaining('pino://pair?t=live'), findsOneWidget);
    });

    testWidgets('refresh button explicitly mints', (tester) async {
      final client = FakeControlClient(
        current: const PairCurrentData(
          url: 'pino://pair?t=live',
          token: 'live',
          expiresAt: 9999999999999,
        ),
        mint: const PairMintData(
          url: 'pino://pair?t=fresh',
          token: 'fresh',
          expiresAt: 9999999999999,
          fingerprint: 'AA:BB',
        ),
      );
      await tester.pumpWidget(_host(client, const QrScreen()));
      await tester.pump(const Duration(milliseconds: 60));

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pump(); // apply setState → loading
      await tester.pump(const Duration(milliseconds: 60));
      expect(client.pairMintCalls, 1);
      expect(find.textContaining('pino://pair?t=fresh'), findsOneWidget);
    });
  });

  group('DevicesScreen', () {
    testWidgets('renders each device', (tester) async {
      final client = FakeControlClient(devices: _devices());
      await tester.pumpWidget(_host(client, const DevicesScreen()));
      await tester.pumpAndSettle();
      expect(find.text('iPhone 15'), findsOneWidget);
    });

    testWidgets('shows the empty state', (tester) async {
      final client = FakeControlClient(devices: const []);
      await tester.pumpWidget(_host(client, const DevicesScreen()));
      await tester.pumpAndSettle();
      expect(find.text('No paired devices'), findsOneWidget);
    });

    testWidgets('renders an error state', (tester) async {
      final client = FakeControlClient(throwOnDevicesList: true);
      await tester.pumpWidget(_host(client, const DevicesScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('revoke button invokes the client and refreshes', (
      tester,
    ) async {
      final client = FakeControlClient(devices: _devices());
      await tester.pumpWidget(_host(client, const DevicesScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Revoke'));
      await tester.pumpAndSettle();
      expect(client.revokedIds, ['d1']);
      expect(find.text('No paired devices'), findsOneWidget);
    });
  });

  group('SessionsScreen', () {
    testWidgets('renders each session with a status chip', (tester) async {
      final client = FakeControlClient(sessions: _sessions());
      await tester.pumpWidget(_host(client, const SessionsScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Refactor auth'), findsOneWidget);
      expect(find.widgetWithText(Chip, 'running'), findsOneWidget);
    });

    testWidgets('shows the empty state', (tester) async {
      final client = FakeControlClient(sessions: const []);
      await tester.pumpWidget(_host(client, const SessionsScreen()));
      await tester.pumpAndSettle();
      expect(find.text('No running sessions'), findsOneWidget);
    });

    testWidgets('renders an error state', (tester) async {
      final client = FakeControlClient(throwOnSessionsList: true);
      await tester.pumpWidget(_host(client, const SessionsScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('tapping a tile prints the route', (tester) async {
      final client = FakeControlClient(sessions: _sessions());
      final printed = <String?>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message);
      try {
        await tester.pumpWidget(_host(client, const SessionsScreen()));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Refactor auth'));
        await tester.pumpAndSettle();
      } finally {
        debugPrint = previous;
      }
      expect(printed, contains('/sessions/s1'));
    });
  });

  group('SessionLogScreen', () {
    testWidgets('shows Connecting… before the first line', (tester) async {
      final client = FakeControlClient();
      await tester.pumpWidget(
        _host(client, const SessionLogScreen(sessionId: 's1')),
      );
      await tester.pump();
      expect(find.text('Connecting…'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('renders streamed lines', (tester) async {
      final client = FakeControlClient(
        logLines: const [
          LogLine(text: 'hello'),
          LogLine(text: 'world'),
        ],
      );
      await tester.pumpWidget(
        _host(client, const SessionLogScreen(sessionId: 's1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('hello'), findsOneWidget);
      expect(find.text('world'), findsOneWidget);
    });

    testWidgets('shows Connection lost on a stream error', (tester) async {
      final client = FakeControlClient(throwOnTailLogs: true);
      await tester.pumpWidget(
        _host(client, const SessionLogScreen(sessionId: 's1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Connection lost'), findsOneWidget);
    });
  });
}
