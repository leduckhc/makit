import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/pairing/device_name.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(deviceInfoChannel, null);
  });

  test('returns the native device name', () async {
    messenger.setMockMethodCallHandler(deviceInfoChannel, (call) async {
      return call.method == 'name' ? "KC's iPhone" : null;
    });
    expect(await deviceName(), "KC's iPhone");
  });

  test('trims surrounding whitespace', () async {
    messenger.setMockMethodCallHandler(
      deviceInfoChannel,
      (call) async => "  KC's iPhone  ",
    );
    expect(await deviceName(), "KC's iPhone");
  });

  test(
    'falls back to a generic name when the channel is unavailable',
    () async {
      messenger.setMockMethodCallHandler(deviceInfoChannel, (call) async {
        throw PlatformException(code: 'unavailable');
      });
      final name = await deviceName();
      expect(name, isNotEmpty);
      expect(name, isNot("KC's iPhone"));
    },
  );

  test('falls back when the native name is blank', () async {
    messenger.setMockMethodCallHandler(
      deviceInfoChannel,
      (call) async => '   ',
    );
    expect(await deviceName(), isNotEmpty);
  });
}
