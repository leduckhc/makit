// Integration test for the unified server-control chain: a real
// [ServerConfigController] + real [DesktopController] + real [DaemonLifecycle],
// wired exactly as `runDesktopApp` wires them, with only the process spawn and
// the control socket faked. Proves that a bind-mode selection flows all the way
// through to the `makit` CLI argv the daemon is actually launched with — the
// cross-layer contract the widget/unit tests each only cover one side of.
//
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/control/control_contract.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';
import 'package:makit/desktop/desktop_controller.dart';
import 'package:makit/desktop/screens/fake_control_client.dart';
import 'package:makit/desktop/settings/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _cliPath = '/usr/local/bin/makit';

StatusData _status() => const StatusData(
  pid: 1,
  uptimeMs: 0,
  host: '127.0.0.1',
  port: 7788,
  fingerprint: 'fp',
  advertiseHost: '127.0.0.1',
  pairedDevices: 0,
  runningSessions: 0,
  version: 'test',
);

void main() {
  late List<List<String>> calls;

  Future<ServerConfigController> makeConfig([
    ServerConfig initial = const ServerConfig(),
  ]) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return ServerConfigController(prefs, initial);
  }

  DesktopController build(ServerConfigController config) {
    final lifecycle = DaemonLifecycle(
      resolver: MakitCliResolver(
        candidatePaths: const [_cliPath],
        exists: (p) => p == _cliPath || p == '/opt/dev/makit',
        shellLookup: () async => null,
        // Mirrors runDesktopApp: the resolver honors the live CLI-path override.
        overridePath: () => config.current.cliPath,
      ),
      run: (exe, args) async {
        calls.add([exe, ...args]);
        return ProcessResult(0, 0, '', '');
      },
    );
    return DesktopController(
      client: FakeControlClient(status: _status(), latency: Duration.zero),
      lifecycle: lifecycle,
      serveArgs: () => config.current.serveArgs(),
    );
  }

  setUp(() => calls = []);

  test('auto (default) starts the daemon with no --host/--lan', () async {
    final controller = build(await makeConfig());
    addTearDown(controller.dispose);

    await controller.start();

    expect(calls.single, [_cliPath, 'start', '--port', '7777']);
  });

  test('LAN mode forwards --lan', () async {
    final config = await makeConfig();
    await config.setBindMode(ServerBindMode.lan);
    final controller = build(config);
    addTearDown(controller.dispose);

    await controller.start();

    expect(calls.single, [_cliPath, 'start', '--lan', '--port', '7777']);
  });

  test('loopback mode pins --host 127.0.0.1', () async {
    final config = await makeConfig();
    await config.setBindMode(ServerBindMode.loopback);
    final controller = build(config);
    addTearDown(controller.dispose);

    await controller.start();

    expect(calls.single, [
      _cliPath,
      'start',
      '--host',
      '127.0.0.1',
      '--port',
      '7777',
    ]);
  });

  test('custom mode forwards the explicit host and port on restart', () async {
    final config = await makeConfig();
    await config.setBindMode(ServerBindMode.custom);
    await config.setCustomHost('0.0.0.0');
    await config.setPort(7788);
    final controller = build(config);
    addTearDown(controller.dispose);

    await controller.restart();

    expect(calls.single, [
      _cliPath,
      'restart',
      '--host',
      '0.0.0.0',
      '--port',
      '7788',
    ]);
  });

  test('a CLI-path override launches the configured binary', () async {
    final config = await makeConfig();
    await config.setCliPath('/opt/dev/makit');
    final controller = build(config);
    addTearDown(controller.dispose);

    await controller.start();

    expect(calls.single.first, '/opt/dev/makit');
  });

  test('live config changes are honored on the next start (no rebuild)', () async {
    final config = await makeConfig();
    final controller = build(config);
    addTearDown(controller.dispose);

    await controller.start();
    expect(calls.single, [_cliPath, 'start', '--port', '7777']);

    // Change the bind mode after the controller was built; the serveArgs
    // closure reads live config, so the next start reflects it.
    calls.clear();
    await config.setBindMode(ServerBindMode.lan);
    await controller.start();
    expect(calls.single, [_cliPath, 'start', '--lan', '--port', '7777']);
  });
}
