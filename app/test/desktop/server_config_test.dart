import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/settings/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('defaults to myDevices, no LAN fallback, port 7777, no CLI', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cfg = ServerConfigController.load(prefs);
    expect(cfg.reachability, Reachability.myDevices);
    expect(cfg.allowLanFallback, isFalse);
    expect(cfg.customHost, '');
    expect(cfg.port, 7777);
    expect(cfg.cliPath, '');
  });

  test('load reads persisted new-schema values', () async {
    SharedPreferences.setMockInitialValues({
      'desktop_server_reachability': 'thisMacOnly',
      'desktop_server_allow_lan_fallback': true,
      'desktop_server_custom_host': '0.0.0.0',
      'desktop_server_port': 9000,
      'desktop_server_cli_path': '/opt/makit/makit',
    });
    final prefs = await SharedPreferences.getInstance();
    final cfg = ServerConfigController.load(prefs);
    expect(cfg.reachability, Reachability.thisMacOnly);
    expect(cfg.allowLanFallback, isTrue);
    expect(cfg.customHost, '0.0.0.0');
    expect(cfg.port, 9000);
    expect(cfg.cliPath, '/opt/makit/makit');
  });

  group('bind-mode migration (pre-SPEC-50 desktop_server_bind_mode)', () {
    Future<ServerConfig> migrate(Map<String, Object> values) async {
      SharedPreferences.setMockInitialValues(values);
      final prefs = await SharedPreferences.getInstance();
      return ServerConfigController.load(prefs);
    }

    test('auto → myDevices, no LAN fallback, no custom host', () async {
      final cfg = await migrate({'desktop_server_bind_mode': 'auto'});
      expect(cfg.reachability, Reachability.myDevices);
      expect(cfg.allowLanFallback, isFalse);
      expect(cfg.customHost, '');
    });

    test('lan → myDevices with allowLanFallback true', () async {
      final cfg = await migrate({'desktop_server_bind_mode': 'lan'});
      expect(cfg.reachability, Reachability.myDevices);
      expect(cfg.allowLanFallback, isTrue);
      expect(cfg.customHost, '');
    });

    test('loopback → thisMacOnly', () async {
      final cfg = await migrate({'desktop_server_bind_mode': 'loopback'});
      expect(cfg.reachability, Reachability.thisMacOnly);
      expect(cfg.allowLanFallback, isFalse);
    });

    test('custom → myDevices, retains the custom host', () async {
      final cfg = await migrate({
        'desktop_server_bind_mode': 'custom',
        'desktop_server_custom_host': '0.0.0.0',
      });
      expect(cfg.reachability, Reachability.myDevices);
      expect(cfg.customHost, '0.0.0.0');
    });

    test('a stale custom host under auto is not carried over', () async {
      final cfg = await migrate({
        'desktop_server_bind_mode': 'auto',
        'desktop_server_custom_host': '0.0.0.0',
      });
      expect(cfg.reachability, Reachability.myDevices);
      expect(cfg.customHost, '');
    });
  });

  group('legacy host migration (desktop_server_host)', () {
    Future<ServerConfig> migrate(Map<String, Object> values) async {
      SharedPreferences.setMockInitialValues(values);
      final prefs = await SharedPreferences.getInstance();
      return ServerConfigController.load(prefs);
    }

    test('a deliberately-set non-loopback host → myDevices + custom', () async {
      final cfg = await migrate({
        'desktop_server_host': '100.1.2.3',
        'desktop_server_port': 9100,
      });
      expect(cfg.reachability, Reachability.myDevices);
      expect(cfg.customHost, '100.1.2.3');
      expect(cfg.port, 9100);
    });

    test('the old default loopback host → default myDevices', () async {
      final cfg = await migrate({'desktop_server_host': 'localhost'});
      expect(cfg.reachability, Reachability.myDevices);
      expect(cfg.customHost, '');
    });

    test('a new-schema value wins over a stale legacy host', () async {
      final cfg = await migrate({
        'desktop_server_reachability': 'thisMacOnly',
        'desktop_server_host': '100.1.2.3',
      });
      expect(cfg.reachability, Reachability.thisMacOnly);
    });

    test('a bind-mode value wins over a stale legacy host', () async {
      final cfg = await migrate({
        'desktop_server_bind_mode': 'lan',
        'desktop_server_host': '100.1.2.3',
      });
      expect(cfg.reachability, Reachability.myDevices);
      expect(cfg.allowLanFallback, isTrue);
    });

    // Layer precedence, top to bottom, with ALL THREE present at once. A user
    // who upgrades twice keeps every generation of key on disk, so the newest
    // must win outright -- otherwise a stale pre-SPEC-50 bind mode would quietly
    // re-open a server the user had since restricted to this Mac.
    test('the newest schema wins when every generation is present', () async {
      final cfg = await migrate({
        'desktop_server_reachability': 'thisMacOnly',
        'desktop_server_allow_lan_fallback': true,
        'desktop_server_bind_mode': 'lan',
        'desktop_server_host': '100.1.2.3',
      });
      expect(
        cfg.reachability,
        Reachability.thisMacOnly,
        reason: 'a stale bind mode re-opened a restricted server',
      );
      expect(cfg.serveArgs(), contains('127.0.0.1'));
    });
  });

  group('serveArgs', () {
    test('thisMacOnly pins 127.0.0.1', () {
      const cfg = ServerConfig(reachability: Reachability.thisMacOnly);
      expect(cfg.serveArgs(), ['--host', '127.0.0.1', '--port', '7777']);
    });

    test('myDevices with no fallback passes no host flag', () {
      const cfg = ServerConfig(port: 8000);
      expect(cfg.serveArgs(), ['--port', '8000']);
    });

    test('myDevices with LAN fallback passes --lan', () {
      const cfg = ServerConfig(allowLanFallback: true, port: 8000);
      expect(cfg.serveArgs(), ['--lan', '--port', '8000']);
    });

    test('a non-empty custom host wins (explicit escape hatch)', () {
      const cfg = ServerConfig(
        reachability: Reachability.thisMacOnly,
        allowLanFallback: true,
        customHost: '0.0.0.0',
      );
      expect(cfg.serveArgs(), ['--host', '0.0.0.0', '--port', '7777']);
    });

    test('a blank custom host is ignored', () {
      const cfg = ServerConfig(customHost: '  ', allowLanFallback: true);
      expect(cfg.serveArgs(), ['--lan', '--port', '7777']);
    });
  });

  test('setters persist and blank/invalid falls back to defaults', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final controller = ServerConfigController(prefs, const ServerConfig());

    await controller.setReachability(Reachability.thisMacOnly);
    await controller.setAllowLanFallback(true);
    await controller.setCustomHost('example.local');
    await controller.setPort(9100);
    await controller.setCliPath('/opt/makit/makit');
    expect(controller.state.reachability, Reachability.thisMacOnly);
    expect(controller.state.allowLanFallback, isTrue);
    expect(controller.state.customHost, 'example.local');
    expect(controller.state.port, 9100);
    expect(controller.state.cliPath, '/opt/makit/makit');
    expect(prefs.getString('desktop_server_reachability'), 'thisMacOnly');
    expect(prefs.getBool('desktop_server_allow_lan_fallback'), isTrue);
    expect(prefs.getString('desktop_server_custom_host'), 'example.local');
    expect(prefs.getInt('desktop_server_port'), 9100);
    expect(prefs.getString('desktop_server_cli_path'), '/opt/makit/makit');

    await controller.setPort(0);
    expect(controller.state.port, 7777);
  });

  test('setPort(0) restores the profile default port, not 7777', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final controller = ServerConfigController(
      prefs,
      const ServerConfig(port: 7842),
      defaultPort: 7842,
    );

    await controller.setPort(0);
    expect(controller.state.port, 7842);
    expect(prefs.getInt('desktop_server_port'), 7842);
  });
}
