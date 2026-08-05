import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/pairing/onboarding_controller.dart';
import 'package:makit/pairing/pairing_screen.dart';
import 'package:makit/pairing/readiness.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/transport/transport.dart';

/// The connect screen is now the single server surface: first run *and*
/// management. It lists paired servers, adds new ones, and offers demo data.
const _fpA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _fpB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class _Transport implements Transport {
  final _frames = StreamController<Envelope>.broadcast();
  final _state = StreamController<WsState>.broadcast();

  @override
  Future<void> connect(
    String url, {
    Map<String, dynamic> helloBody = const {},
    String? pinnedFingerprint,
  }) async => _state.add(WsState.connected);

  @override
  Future<void> close() async {}
  @override
  Stream<Envelope> get frames => _frames.stream;
  @override
  Stream<WsState> get state => _state.stream;
  @override
  void sendEnvelope(Envelope env) {}
  @override
  void forceReconnect() {}
}

class _Storage implements SecureStore {
  _Storage(this.data);
  final Map<String, String> data;

  @override
  Future<String?> read({required String key}) async => data[key];
  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({required String key}) async => data.remove(key);
}

Map<String, dynamic> _srv(String host, String fp, String label) => {
  'host': host,
  'port': 8443,
  'fingerprint': fp,
  'bearer': 'bearer-$fp',
  'label': label,
};

ProviderContainer _container({required List<Map<String, dynamic>> servers}) {
  final storage = _Storage({
    if (servers.isNotEmpty)
      'paired_servers': jsonEncode({'servers': servers, 'activeId': _fpA}),
  });
  final container = ProviderContainer(
    overrides: [
      onboardingControllerProvider.overrideWith(
        (_) => OnboardingController.withSeams(
          query: () async => NotificationPermission.granted,
          request: () async => NotificationPermission.granted,
        ),
      ),
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(
          storage,
          transportFactory: _Transport.new,
          browseLan: ({Duration timeout = const Duration(seconds: 3)}) async =>
              [],
          rediscoverStall: Duration.zero,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  List<Map<String, dynamic>> servers = const [],
}) async {
  final container = _container(servers: servers);
  container.read(connectionControllerProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: PairingScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

List<Map<String, dynamic>> get _twoServers => [
  _srv('10.0.0.1', _fpA, 'work mac'),
  _srv('10.0.0.2', _fpB, 'home mac'),
];

void main() {
  group('true first run (nothing paired)', () {
    testWidgets('leads with the hero, Add server and demo data', (
      tester,
    ) async {
      await _pump(tester);

      expect(find.text('Connect to your Mac'), findsOneWidget);
      expect(find.text('Add server'), findsOneWidget);
      expect(find.text('Open with fake data'), findsOneWidget);
    });

    testWidgets('shows no server list when there is nothing to list', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.text('Connected'), findsNothing);
    });
  });

  group('with servers paired', () {
    testWidgets('lists every server and marks the connected one', (
      tester,
    ) async {
      await _pump(tester, servers: _twoServers);

      expect(find.text('work mac'), findsOneWidget);
      expect(find.text('home mac'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      // Add server and demo data stay available alongside the list.
      expect(find.text('Add server'), findsOneWidget);
      expect(find.text('Open with fake data'), findsOneWidget);
    });

    testWidgets('the first-run hero steps aside once a server exists', (
      tester,
    ) async {
      await _pump(tester, servers: _twoServers);
      expect(find.text('Connect to your Mac'), findsNothing);
    });

    testWidgets('tapping an inactive server switches to it', (tester) async {
      final c = await _pump(tester, servers: _twoServers);
      expect(c.read(connectionProvider).activeServer?.label, 'work mac');

      await tester.tap(find.text('home mac'));
      await tester.pumpAndSettle();

      expect(c.read(connectionProvider).activeServer?.label, 'home mac');
    });

    testWidgets('renaming a server updates it in place', (tester) async {
      final c = await _pump(tester, servers: _twoServers);

      await tester.tap(find.byKey(const Key('serverMenu-$_fpB')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'studio');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        c
            .read(connectionProvider)
            .servers
            .firstWhere((s) => s.fingerprint == _fpB)
            .label,
        'studio',
      );
      expect(find.text('studio'), findsOneWidget);
    });

    testWidgets('forgetting needs confirmation, then drops the server', (
      tester,
    ) async {
      final c = await _pump(tester, servers: _twoServers);

      await tester.tap(find.byKey(const Key('serverMenu-$_fpB')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget'));
      await tester.pumpAndSettle();
      expect(c.read(connectionProvider).servers, hasLength(2));

      await tester.tap(find.widgetWithText(FilledButton, 'Forget'));
      await tester.pumpAndSettle();

      expect(c.read(connectionProvider).servers, hasLength(1));
      expect(find.text('home mac'), findsNothing);
    });
  });
}
