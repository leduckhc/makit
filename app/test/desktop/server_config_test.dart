import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/settings/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('defaults to localhost:8787 when nothing is persisted', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cfg = ServerConfigController.load(prefs);
    expect(cfg.host, 'localhost');
    expect(cfg.port, 8787);
  });

  test('load reads persisted values', () async {
    SharedPreferences.setMockInitialValues({
      'desktop_server_host': '127.0.0.1',
      'desktop_server_port': 9000,
    });
    final prefs = await SharedPreferences.getInstance();
    final cfg = ServerConfigController.load(prefs);
    expect(cfg.host, '127.0.0.1');
    expect(cfg.port, 9000);
  });

  test('setters persist and blank/invalid falls back to defaults', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final controller = ServerConfigController(prefs, const ServerConfig());

    await controller.setPort(9100);
    await controller.setHost('example.local');
    expect(controller.state.port, 9100);
    expect(controller.state.host, 'example.local');
    expect(prefs.getInt('desktop_server_port'), 9100);
    expect(prefs.getString('desktop_server_host'), 'example.local');

    await controller.setHost('   ');
    await controller.setPort(0);
    expect(controller.state.host, 'localhost');
    expect(controller.state.port, 8787);
  });
}
