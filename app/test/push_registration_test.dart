import 'package:flutter_test/flutter_test.dart';
import 'package:pino/notifications/push_registration.dart';
import 'package:pino/transport/protocol.dart';

void main() {
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
}
