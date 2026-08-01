// T1 — SPEC-34: the navigator style enum, its shared provider, and the
// preference entries backing the desktop picker.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/settings/prefs/preference_entries.dart';
import 'package:makit/desktop/settings/prefs/preferences_controller.dart';
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
            MessageNavigatorStyle.outline,
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(
        container.read(messageNavigatorStyleProvider),
        MessageNavigatorStyle.outline,
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

  group('per-style option entries', () {
    test('every entry is registered in kPreferenceEntries', () {
      final ids = kPreferenceEntries.map((e) => e.id).toSet();
      for (final id in const [
        'chat.navigator.style',
        'chat.navigator.rail.spacing',
        'chat.navigator.rail.ripple',
        'chat.navigator.rail.encodeLength',
        'chat.navigator.palette.searchAll',
        'chat.navigator.crumb.autoHide',
        'chat.navigator.crumb.counter',
        'chat.navigator.outline.hideTools',
        'chat.navigator.outline.showCounts',
      ]) {
        expect(ids, contains(id), reason: '$id must be persisted');
      }
    });

    test('defaults match the spec', () {
      final c = PreferencesController.ephemeral();
      expect(c.get(railTickSpacingPreference), 6);
      expect(c.get(railRipplePreference), isTrue);
      expect(c.get(railEncodeLengthPreference), isTrue);
      expect(c.get(paletteSearchAllPreference), isFalse);
      expect(c.get(crumbAutoHidePreference), isTrue);
      expect(c.get(crumbCounterPreference), isTrue);
      expect(c.get(outlineHideToolsPreference), isFalse);
      expect(c.get(outlineShowCountsPreference), isTrue);
    });

    // The bug the settings mockup exposed: switching style must not clear the
    // options of the style you switched away from (SPEC-34 §schema, 3).
    test('options survive a round trip through another style', () async {
      final controller = PreferencesController.ephemeral();
      await controller.set(railTickSpacingPreference, 14);
      await controller.set(railRipplePreference, false);

      await controller.set(
        messageNavigatorStylePreference,
        MessageNavigatorStyle.outline,
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
