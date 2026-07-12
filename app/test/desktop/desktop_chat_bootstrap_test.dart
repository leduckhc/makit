import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_chat_bootstrap.dart';

void main() {
  test('pairs after the daemon is running', () async {
    var paired = false;
    final boot = DesktopChatBootstrap(
      ensureDaemonRunning: () async => true,
      ensurePaired: () async => paired = true,
    );

    final ok = await boot.run();

    expect(ok, isTrue);
    expect(paired, isTrue);
  });

  test('does not pair when the daemon never comes up', () async {
    var pairCalled = false;
    final boot = DesktopChatBootstrap(
      ensureDaemonRunning: () async => false,
      ensurePaired: () async => pairCalled = true,
    );

    final ok = await boot.run();

    expect(ok, isFalse);
    expect(pairCalled, isFalse);
  });
}
