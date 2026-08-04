import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/pairing/servers_screen.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/transport/transport.dart';

const _fpA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _fpB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

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

/// A container seeded with two paired servers, "work mac" active.
ProviderContainer _container() {
  final storage = _Storage({
    'paired_servers': jsonEncode({
      'servers': [
        _srv('10.0.0.1', _fpA, 'work mac'),
        _srv('10.0.0.2', _fpB, 'home mac'),
      ],
      'activeId': _fpA,
    }),
  });
  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(
          storage,
          transportFactory: _Transport.new,
          browseLan:
              ({Duration timeout = const Duration(seconds: 3)}) async => [],
          rediscoverStall: Duration.zero,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<ProviderContainer> _pumpServers(WidgetTester tester) async {
  final container = _container();
  // Let the controller boot and load the seeded servers.
  container.read(connectionControllerProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ServersScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('lists every paired server and marks the active one', (
    tester,
  ) async {
    await _pumpServers(tester);

    expect(find.text('work mac'), findsOneWidget);
    expect(find.text('home mac'), findsOneWidget);
    // Exactly one row advertises itself as the connected server.
    expect(find.text('Connected'), findsOneWidget);
  });

  testWidgets('tapping an inactive server switches the connection to it', (
    tester,
  ) async {
    final container = await _pumpServers(tester);
    expect(container.read(connectionProvider).activeServer?.label, 'work mac');

    await tester.tap(find.text('home mac'));
    await tester.pumpAndSettle();

    expect(container.read(connectionProvider).activeServer?.label, 'home mac');
  });

  testWidgets('renaming a server updates its label in place', (tester) async {
    final container = await _pumpServers(tester);

    await tester.tap(find.byKey(const Key('serverMenu-$_fpB')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'studio');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      container
          .read(connectionProvider)
          .servers
          .firstWhere((s) => s.fingerprint == _fpB)
          .label,
      'studio',
    );
    expect(find.text('studio'), findsOneWidget);
  });

  testWidgets('forgetting a server needs confirmation, then drops it', (
    tester,
  ) async {
    final container = await _pumpServers(tester);

    await tester.tap(find.byKey(const Key('serverMenu-$_fpB')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();

    // Still two until confirmed — a destructive action never fires on one tap.
    expect(container.read(connectionProvider).servers, hasLength(2));

    await tester.tap(find.widgetWithText(FilledButton, 'Forget'));
    await tester.pumpAndSettle();

    expect(container.read(connectionProvider).servers, hasLength(1));
    expect(find.text('home mac'), findsNothing);
  });

  testWidgets('offers a way to add another server', (tester) async {
    await _pumpServers(tester);
    expect(find.text('Add server'), findsOneWidget);
  });
}
