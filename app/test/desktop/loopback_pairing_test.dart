import 'package:flutter_test/flutter_test.dart';
import 'package:makit/control/control_contract.dart';
import 'package:makit/desktop/chat/loopback_pairing.dart';
import 'package:makit/desktop/screens/fake_control_client.dart';
import 'package:makit/pairing/pair_info.dart';

StatusData _status({int port = 8787, String fingerprint = 'ab12cd34'}) =>
    StatusData(
      pid: 1,
      uptimeMs: 0,
      host: '100.1.2.3',
      port: port,
      fingerprint: fingerprint,
      advertiseHost: '100.1.2.3',
      pairedDevices: 0,
      runningSessions: 0,
      version: '1.0.0',
    );

PairMintData _mint({String token = 'tok-123'}) => PairMintData(
      url: 'makit://pair?host=100.1.2.3&port=8787&fp=ab12cd34&t=$token',
      token: token,
      expiresAt: 0,
      fingerprint: 'ab12cd34',
    );

void main() {
  test('ensurePaired is a no-op when already paired', () async {
    final control = FakeControlClient(
      status: _status(),
      mint: _mint(),
      latency: Duration.zero,
    );
    var pairCalls = 0;
    final pairing = LoopbackPairing(
      control: control,
      isPaired: () => true,
      pairWith: (info, {String label = 'Mac'}) async => pairCalls++,
    );

    final didPair = await pairing.ensurePaired();

    expect(didPair, isFalse);
    expect(pairCalls, 0);
  });

  test('ensurePaired self-pairs over loopback when unpaired', () async {
    final control = FakeControlClient(
      status: _status(port: 9999, fingerprint: 'deadbeef'),
      mint: _mint(token: 'tok-xyz'),
      latency: Duration.zero,
    );
    PairInfo? seen;
    String? seenLabel;
    final pairing = LoopbackPairing(
      control: control,
      isPaired: () => false,
      label: 'Mac',
      pairWith: (info, {String label = 'Mac'}) async {
        seen = info;
        seenLabel = label;
      },
    );

    final didPair = await pairing.ensurePaired();

    expect(didPair, isTrue);
    expect(seen, isNotNull);
    // Must target loopback, not the daemon's advertised (Tailscale/LAN) host.
    expect(seen!.host, '127.0.0.1');
    expect(seen!.port, 9999);
    expect(seen!.fingerprint, 'deadbeef');
    expect(seen!.token, 'tok-xyz');
    expect(seenLabel, 'Mac');
  });
}
