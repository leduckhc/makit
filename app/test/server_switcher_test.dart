import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/transport/transport.dart';
import 'package:makit/ui/home/server_switcher.dart';

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

ProviderContainer _container({required List<Map<String, dynamic>> servers}) {
  final storage = _Storage({
    if (servers.isNotEmpty)
      'paired_servers': jsonEncode({'servers': servers, 'activeId': _fpA}),
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

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required List<Map<String, dynamic>> servers,
}) async {
  final container = _container(servers: servers);
  container.read(connectionControllerProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: Center(child: ServerSwitcher())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('shows the active server name as the home title', (tester) async {
    await _pump(
      tester,
      servers: [
        _srv('10.0.0.1', _fpA, 'work mac'),
        _srv('10.0.0.2', _fpB, 'home mac'),
      ],
    );
    expect(find.text('work mac'), findsOneWidget);
  });

  testWidgets('with one server there is nothing to switch between, so no caret',
      (tester) async {
    await _pump(tester, servers: [_srv('10.0.0.1', _fpA, 'work mac')]);
    expect(find.text('work mac'), findsOneWidget);
    expect(find.byKey(const Key('serverSwitcherCaret')), findsNothing);
  });

  testWidgets('falls back to the app name when nothing is paired', (
    tester,
  ) async {
    await _pump(tester, servers: const []);
    expect(find.text('Makit'), findsOneWidget);
  });

  testWidgets('tapping opens a picker and choosing another server switches', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      servers: [
        _srv('10.0.0.1', _fpA, 'work mac'),
        _srv('10.0.0.2', _fpB, 'home mac'),
      ],
    );
    expect(find.byKey(const Key('serverSwitcherCaret')), findsOneWidget);

    await tester.tap(find.text('work mac'));
    await tester.pumpAndSettle();

    // The sheet lists every server, including the current one.
    expect(find.text('home mac'), findsOneWidget);

    await tester.tap(find.text('home mac'));
    await tester.pumpAndSettle();

    expect(container.read(connectionProvider).activeServer?.label, 'home mac');
    // Sheet dismissed, title now reflects the new server.
    expect(find.text('home mac'), findsOneWidget);
  });
}
