import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/notifications/push_registration.dart';
import 'package:makit/transport/protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('pushRegisterBody (B3)', () {
    test('builds the register cmd body', () {
      final body = pushRegisterBody(token: 'tok-123', platform: 'apns');
      expect(body, {
        'kind': 'push.register',
        'token': 'tok-123',
        'platform': 'apns',
      });
    });

    test('uses the CmdKind.registerPush wire string', () {
      final body = pushRegisterBody(token: 't', platform: 'fcm');
      expect(body['kind'], CmdKind.registerPush.wire);
      expect(CmdKind.registerPush.wire, 'push.register');
    });
  });

  group('NoopPushRegistrar (B3)', () {
    test('returns null token (no native provider wired)', () async {
      const registrar = NoopPushRegistrar();
      expect(await registrar.getToken(), isNull);
      expect(registrar.platform, 'apns');
    });
  });

  group('ChannelPushRegistrar (MAJOR 1)', () {
    const codec = StandardMethodCodec();

    Future<void> invokeNative(MethodChannel channel, MethodCall call) {
      return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            codec.encodeMethodCall(call),
            (_) {},
          );
    }

    test('token is null until the native didRegister call fires', () async {
      final registrar = ChannelPushRegistrar(
        channel: const MethodChannel('makit/push/test-null'),
      );
      expect(await registrar.getToken(), isNull);
      expect(registrar.platform, 'apns');
    });

    test('didRegister stores the token and fires the listener', () async {
      const channel = MethodChannel('makit/push/test-register');
      final registrar = ChannelPushRegistrar(channel: channel);
      String? fired;
      registrar.onToken = (t) => fired = t;

      await invokeNative(
        channel,
        const MethodCall('didRegister', 'deadbeef01'),
      );

      expect(await registrar.getToken(), 'deadbeef01');
      expect(fired, 'deadbeef01');
    });

    test('non-string / empty arguments are ignored', () async {
      const channel = MethodChannel('makit/push/test-ignore');
      final registrar = ChannelPushRegistrar(channel: channel);
      var fireCount = 0;
      registrar.onToken = (_) => fireCount++;

      await invokeNative(channel, const MethodCall('didRegister', 42));
      await invokeNative(channel, const MethodCall('didRegister', ''));
      await invokeNative(channel, const MethodCall('didFail', 'boom'));

      expect(await registrar.getToken(), isNull);
      expect(fireCount, 0);
    });
  });
}
