// T5b — SPEC-34: mobile's single navigator control.
//
// Mobile does not get the desktop picker (the preference system does not reach
// here — see the spec's Surface matrix), so these tests pin the two things that
// must hold: the pointer-only styles are unreachable, and the user can turn the
// navigator off.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/mobile_navigator.dart';
import 'package:makit/ui/session/navigator/navigator_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults to on, and on means the scrubber', () async {
    final prefs = await SharedPreferences.getInstance();
    final controller = MobileNavigatorController.load(prefs);
    expect(controller.state, isTrue);
    expect(controller.style, MessageNavigatorStyle.scrubber);
  });

  test('off means no navigator at all', () async {
    final prefs = await SharedPreferences.getInstance();
    final controller = MobileNavigatorController.load(prefs);
    await controller.set(false);
    expect(controller.style, MessageNavigatorStyle.off);
  });

  test('the choice survives a relaunch', () async {
    final prefs = await SharedPreferences.getInstance();
    await MobileNavigatorController.load(prefs).set(false);

    // A fresh controller over the same store — i.e. the next launch.
    expect(MobileNavigatorController.load(prefs).state, isFalse);
    expect(
      MobileNavigatorController.load(prefs).style,
      MessageNavigatorStyle.off,
    );
  });

  test('a corrupt stored value falls back to on', () async {
    SharedPreferences.setMockInitialValues({kMobileNavigatorKey: 'not a bool'});
    final prefs = await SharedPreferences.getInstance();
    expect(MobileNavigatorController.load(prefs).state, isTrue);
  });

  test('mobile can never reach a pointer-only style', () async {
    final prefs = await SharedPreferences.getInstance();
    final controller = MobileNavigatorController.load(prefs);
    for (final enabled in [true, false]) {
      await controller.set(enabled);
      expect(
        controller.style,
        isNot(MessageNavigatorStyle.rail),
        reason: 'the rail needs hover',
      );
      expect(controller.style, isNot(MessageNavigatorStyle.breadcrumb));
    }
  });

  test('the ephemeral controller does not touch storage', () async {
    final controller = MobileNavigatorController.ephemeral();
    expect(controller.state, isTrue);
    await controller.set(false);
    expect(controller.state, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kMobileNavigatorKey), isNull);
  });
}
