import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/transport/transport.dart';
import 'package:makit/ui/settings/settings_screen.dart';

/// Unpair is the most destructive control in the app: re-pairing needs physical
/// access to each Mac's QR code. Forgetting *one* server already confirms, so
/// dropping all of them must not fire on a single tap.
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

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required int serverCount,
}) async {
  final servers = [
    _srv('10.0.0.1', _fpA, 'work mac'),
    if (serverCount > 1) _srv('10.0.0.2', _fpB, 'home mac'),
  ];
  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(
          _Storage({
            'paired_servers': jsonEncode({
              'servers': servers,
              'activeId': _fpA,
            }),
          }),
          transportFactory: _Transport.new,
          browseLan: ({Duration timeout = const Duration(seconds: 3)}) async =>
              [],
          rediscoverStall: Duration.zero,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(connectionControllerProvider);
  // A router is needed because unpair navigates to /pair afterwards.
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SettingsScreen()),
      GoRoute(
        path: '/pair',
        builder: (_, _) => const Scaffold(body: Text('pair screen')),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// The unpair row sits at the bottom of a long settings list, below the fold in
/// the default test viewport.
Future<void> _tapUnpairRow(WidgetTester tester, String label) async {
  final row = find.text(label);
  await tester.scrollUntilVisible(
    row,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('unpairing several servers asks first, and cancel keeps them', (
    tester,
  ) async {
    final c = await _pump(tester, serverCount: 2);
    expect(c.read(connectionProvider).servers, hasLength(2));

    await _tapUnpairRow(tester, 'Unpair from all 2 servers');

    // Nothing destroyed yet, and the prompt names the scope so the user knows
    // this is not the single-server Forget.
    expect(c.read(connectionProvider).servers, hasLength(2));
    expect(find.textContaining('2 servers'), findsWidgets);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(c.read(connectionProvider).servers, hasLength(2));
  });

  testWidgets('confirming drops every server', (tester) async {
    final c = await _pump(tester, serverCount: 2);

    await _tapUnpairRow(tester, 'Unpair from all 2 servers');
    await tester.tap(find.widgetWithText(FilledButton, 'Unpair'));
    await tester.pumpAndSettle();

    expect(c.read(connectionProvider).servers, isEmpty);
    expect(c.read(connectionProvider).paired, isFalse);
    // …and the user is taken to pairing. Clearing the list while leaving them
    // on Settings would be a dead end.
    expect(find.text('pair screen'), findsOneWidget);
  });

  testWidgets('a single paired server is also confirmed before unpairing', (
    tester,
  ) async {
    final c = await _pump(tester, serverCount: 1);

    await _tapUnpairRow(tester, 'Unpair this device');
    expect(c.read(connectionProvider).servers, hasLength(1));

    await tester.tap(find.widgetWithText(FilledButton, 'Unpair'));
    await tester.pumpAndSettle();
    expect(c.read(connectionProvider).servers, isEmpty);
  });
}
