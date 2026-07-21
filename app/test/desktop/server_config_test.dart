import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/settings/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'defaults to auto bind mode on port 7777 with no CLI override',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cfg = ServerConfigController.load(prefs);
      expect(cfg.bindMode, ServerBindMode.auto);
      expect(cfg.customHost, '');
      expect(cfg.port, 7777);
      expect(cfg.cliPath, '');
    },
  );

  test('load reads persisted values', () async {
    SharedPreferences.setMockInitialValues({
      'desktop_server_bind_mode': 'custom',
      'desktop_server_custom_host': '0.0.0.0',
      'desktop_server_port': 9000,
      'desktop_server_cli_path': '/opt/makit/makit',
    });
    final prefs = await SharedPreferences.getInstance();
    final cfg = ServerConfigController.load(prefs);
    expect(cfg.bindMode, ServerBindMode.custom);
    expect(cfg.customHost, '0.0.0.0');
    expect(cfg.port, 9000);
    expect(cfg.cliPath, '/opt/makit/makit');
  });

  group('legacy host migration', () {
    test('a deliberately-set non-loopback host migrates to custom', () async {
      SharedPreferences.setMockInitialValues({
        'desktop_server_host': '100.1.2.3',
        'desktop_server_port': 9100,
      });
      final prefs = await SharedPreferences.getInstance();
      final cfg = ServerConfigController.load(prefs);
      expect(cfg.bindMode, ServerBindMode.custom);
      expect(cfg.customHost, '100.1.2.3');
      expect(cfg.port, 9100);
    });

    test('the old default loopback host migrates to auto', () async {
      SharedPreferences.setMockInitialValues({
        'desktop_server_host': 'localhost',
      });
      final prefs = await SharedPreferences.getInstance();
      final cfg = ServerConfigController.load(prefs);
      expect(cfg.bindMode, ServerBindMode.auto);
      expect(cfg.customHost, '');
    });

    test('an explicit new bind mode wins over a stale legacy host', () async {
      SharedPreferences.setMockInitialValues({
        'desktop_server_bind_mode': 'lan',
        'desktop_server_host': '100.1.2.3',
      });
      final prefs = await SharedPreferences.getInstance();
      final cfg = ServerConfigController.load(prefs);
      expect(cfg.bindMode, ServerBindMode.lan);
    });
  });

  group('serveArgs', () {
    test('auto passes no --host/--lan, only the port', () {
      expect(const ServerConfig().serveArgs(), ['--port', '7777']);
    });

    test('lan passes --lan', () {
      const cfg = ServerConfig(bindMode: ServerBindMode.lan, port: 8000);
      expect(cfg.serveArgs(), ['--lan', '--port', '8000']);
    });

    test('loopback pins 127.0.0.1', () {
      const cfg = ServerConfig(bindMode: ServerBindMode.loopback);
      expect(cfg.serveArgs(), ['--host', '127.0.0.1', '--port', '7777']);
    });

    test('custom forwards the explicit host', () {
      const cfg = ServerConfig(
        bindMode: ServerBindMode.custom,
        customHost: '0.0.0.0',
      );
      expect(cfg.serveArgs(), ['--host', '0.0.0.0', '--port', '7777']);
    });

    test('custom with a blank host falls back to auto', () {
      const cfg = ServerConfig(
        bindMode: ServerBindMode.custom,
        customHost: '  ',
      );
      expect(cfg.serveArgs(), ['--port', '7777']);
    });
  });

  test('setters persist and blank/invalid falls back to defaults', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final controller = ServerConfigController(prefs, const ServerConfig());

    await controller.setBindMode(ServerBindMode.lan);
    await controller.setCustomHost('example.local');
    await controller.setPort(9100);
    await controller.setCliPath('/opt/makit/makit');
    expect(controller.state.bindMode, ServerBindMode.lan);
    expect(controller.state.customHost, 'example.local');
    expect(controller.state.port, 9100);
    expect(controller.state.cliPath, '/opt/makit/makit');
    expect(prefs.getString('desktop_server_bind_mode'), 'lan');
    expect(prefs.getString('desktop_server_custom_host'), 'example.local');
    expect(prefs.getInt('desktop_server_port'), 9100);
    expect(prefs.getString('desktop_server_cli_path'), '/opt/makit/makit');

    await controller.setPort(0);
    expect(controller.state.port, 7777);
  });
}
