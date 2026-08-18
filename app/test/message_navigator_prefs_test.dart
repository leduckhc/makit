// T1 — SPEC-message-navigator: the navigator style enum, its shared provider, and the
// preference entries backing the desktop rail switch.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/prefs/preference_entries.dart';
import 'package:makit/store/prefs/preferences_controller.dart';
import 'package:makit/ui/session/navigator/navigator_style.dart';

void main() {
  group('messageNavigatorStyleProvider', () {
    test('defaults to off — a surface that forgets to override gets no '
        'navigator rather than a broken one', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(messageNavigatorStyleProvider),
        MessageNavigatorStyle.off,
      );
    });

    test('is overridable per surface', () {
      final container = ProviderContainer(
        overrides: [
          messageNavigatorStyleProvider.overrideWithValue(
            MessageNavigatorStyle.rail,
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(
        container.read(messageNavigatorStyleProvider),
        MessageNavigatorStyle.rail,
      );
    });

    test('a stored "scrubber" — a style that used to exist — decodes to the '
        'default rather than breaking the pane', () {
      final controller = PreferencesController(null, const {
        'chat.navigator.style': 'scrubber',
      });
      expect(
        controller.get(messageNavigatorStylePreference),
        MessageNavigatorStyle.rail,
      );
    });
  });

  group('style preference codec', () {
    test('round-trips every style', () async {
      for (final style in MessageNavigatorStyle.values) {
        final controller = PreferencesController.ephemeral();
        await controller.set(messageNavigatorStylePreference, style);
        expect(controller.get(messageNavigatorStylePreference), style);
      }
    });

    test('an unknown id falls back to the default, never throws', () {
      final controller = PreferencesController(null, const {
        'chat.navigator.style': 'quantum',
      });
      expect(
        controller.get(messageNavigatorStylePreference),
        MessageNavigatorStyle.rail,
      );
    });

    test('a wrong-typed stored value falls back to the default', () {
      for (final junk in <Object?>[42, null, true, <String>[]]) {
        final controller = PreferencesController(null, {
          'chat.navigator.style': junk,
        });
        expect(
          controller.get(messageNavigatorStylePreference),
          MessageNavigatorStyle.rail,
          reason: 'stored $junk should fall back',
        );
      }
    });

    test('defaults to rail', () {
      expect(
        messageNavigatorStylePreference.defaultValue,
        MessageNavigatorStyle.rail,
      );
    });
  });

  group('rail option entries', () {
    test('every entry is registered in kPreferenceEntries', () {
      final ids = kPreferenceEntries.map((e) => e.id).toSet();
      for (final id in const [
        'chat.navigator.style',
        'chat.navigator.rail.spacing',
        'chat.navigator.rail.ripple',
        'chat.navigator.rail.encodeLength',
      ]) {
        expect(ids, contains(id), reason: '$id must be persisted');
      }
    });

    test('defaults match the spec', () {
      final c = PreferencesController.ephemeral();
      expect(c.get(railTickSpacingPreference), 6);
      expect(c.get(railRipplePreference), isTrue);
      expect(c.get(railEncodeLengthPreference), isTrue);
    });

    // The bug the settings mockup exposed: turning the rail off must not clear
    // its options (SPEC-message-navigator §schema, 3).
    test('options survive a round trip through off', () async {
      final controller = PreferencesController.ephemeral();
      await controller.set(railTickSpacingPreference, 14);
      await controller.set(railRipplePreference, false);

      await controller.set(
        messageNavigatorStylePreference,
        MessageNavigatorStyle.off,
      );
      await controller.set(
        messageNavigatorStylePreference,
        MessageNavigatorStyle.rail,
      );

      expect(controller.get(railTickSpacingPreference), 14);
      expect(controller.get(railRipplePreference), isFalse);
    });
  });
}
