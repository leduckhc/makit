import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/prefs/preference.dart';
import 'package:makit/store/prefs/preference_entries.dart';
import 'package:makit/store/prefs/preferences_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A throwaway entry used to exercise the generic codec paths.
const _intEntry = PreferenceEntry<int>(
  id: 'test.count',
  defaultValue: 0,
  encode: _encodeInt,
  decode: _decodeInt,
);
Object? _encodeInt(int v) => v;
int? _decodeInt(Object? json) => json is int ? json : null;

void main() {
  _normalizationTests();

  group('PreferencesController (ephemeral)', () {
    test('get returns the default when unset', () {
      final controller = PreferencesController.ephemeral();
      expect(controller.get(themeModePreference), ThemeMode.system);
      expect(controller.isModified(themeModePreference), isFalse);
    });

    test('set == default removes the key (no override stored)', () async {
      final controller = PreferencesController.ephemeral();
      await controller.set(themeModePreference, ThemeMode.dark);
      expect(controller.isModified(themeModePreference), isTrue);

      await controller.set(themeModePreference, ThemeMode.system);
      expect(controller.isModified(themeModePreference), isFalse);
      expect(controller.get(themeModePreference), ThemeMode.system);
    });

    test('set != default stores the override and isModified is true', () async {
      final controller = PreferencesController.ephemeral();
      await controller.set(themeModePreference, ThemeMode.light);
      expect(controller.get(themeModePreference), ThemeMode.light);
      expect(controller.isModified(themeModePreference), isTrue);
    });

    test('reset removes a single override', () async {
      final controller = PreferencesController.ephemeral();
      await controller.set(themeModePreference, ThemeMode.dark);
      await controller.set(_intEntry, 5);
      await controller.reset(themeModePreference);
      expect(controller.isModified(themeModePreference), isFalse);
      expect(controller.isModified(_intEntry), isTrue);
    });

    test('resetAll clears every override', () async {
      // Both registered preferences: resetAll deliberately preserves ids that
      // are *not* in kPreferenceEntries (they belong to another build — see the
      // resetAll doc), and `_intEntry` is a test-local entry, so using it here
      // would assert the opposite of the documented behaviour.
      final controller = PreferencesController.ephemeral();
      await controller.set(themeModePreference, ThemeMode.dark);
      await controller.set(textScalePreference, 1.2);
      await controller.resetAll();
      expect(controller.isModified(themeModePreference), isFalse);
      expect(controller.isModified(textScalePreference), isFalse);
      expect(controller.state, isEmpty);
    });

    test('resetAll keeps an entry this build does not know', () async {
      final controller = PreferencesController.ephemeral();
      await controller.set(_intEntry, 5);
      await controller.resetAll();
      expect(
        controller.isModified(_intEntry),
        isTrue,
        reason: 'an unregistered id is not this build\'s to reset',
      );
    });

    test(
      'internal entries do not count as user-facing modifications',
      () async {
        final controller = PreferencesController.ephemeral();
        expect(controller.modifiedUserFacingCount, 0);

        // Selecting sections writes the internal lastSection entry.
        await controller.set(lastSectionPreference, 'appearance');
        expect(controller.isModified(lastSectionPreference), isTrue);
        expect(controller.modifiedUserFacingCount, 0);

        // A real preference bumps the user-facing count.
        await controller.set(themeModePreference, ThemeMode.dark);
        expect(controller.modifiedUserFacingCount, 1);
      },
    );

    test('resetAll clears user prefs but preserves internal entries', () async {
      final controller = PreferencesController.ephemeral();
      await controller.set(themeModePreference, ThemeMode.dark);
      await controller.set(lastSectionPreference, 'appearance');

      await controller.resetAll();

      expect(controller.isModified(themeModePreference), isFalse);
      expect(controller.isModified(lastSectionPreference), isTrue);
      expect(controller.get(lastSectionPreference), 'appearance');
      expect(controller.modifiedUserFacingCount, 0);
    });
  });

  group('PreferencesController (persistent)', () {
    test('set writes through a single json map under one key', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = PreferencesController.load(prefs);

      await controller.set(themeModePreference, ThemeMode.dark);
      final raw = prefs.getString(PreferencesController.storageKey);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, Object?>;
      expect(decoded[themeModePreference.id], 'dark');
    });

    test('set == default removes the storage key entirely', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = PreferencesController.load(prefs);

      await controller.set(themeModePreference, ThemeMode.dark);
      await controller.set(themeModePreference, ThemeMode.system);
      expect(prefs.getString(PreferencesController.storageKey), isNull);
    });

    test('reload reconstructs overrides from prefs', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = PreferencesController.load(prefs);
      await controller.set(themeModePreference, ThemeMode.light);
      await controller.set(lastSectionPreference, 'appearance');

      final reloaded = PreferencesController.load(prefs);
      expect(reloaded.get(themeModePreference), ThemeMode.light);
      expect(reloaded.get(lastSectionPreference), 'appearance');
      expect(reloaded.isModified(themeModePreference), isTrue);
    });

    test('resetAll clears the storage key', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = PreferencesController.load(prefs);
      await controller.set(themeModePreference, ThemeMode.dark);
      await controller.resetAll();
      expect(prefs.getString(PreferencesController.storageKey), isNull);
    });

    test('corrupt json is ignored (falls back to defaults)', () async {
      SharedPreferences.setMockInitialValues({
        PreferencesController.storageKey: 'not-json{',
      });
      final prefs = await SharedPreferences.getInstance();
      final controller = PreferencesController.load(prefs);
      expect(controller.get(themeModePreference), ThemeMode.system);
      expect(controller.state, isEmpty);
    });

    test(
      'unknown ids and undecodable values fall back to the default',
      () async {
        SharedPreferences.setMockInitialValues({
          PreferencesController.storageKey: jsonEncode({
            'appearance.themeMode': 42, // wrong type -> default
            'some.unknown.id': 'ignored-by-consumers',
          }),
        });
        final prefs = await SharedPreferences.getInstance();
        final controller = PreferencesController.load(prefs);
        // Undecodable value falls back to the entry default.
        expect(controller.get(themeModePreference), ThemeMode.system);
      },
    );
  });
}

/// Loading normalises what is on disk (PR #123 review): a persisted value that
/// no longer decodes, or that now equals its default, must not keep reporting
/// the preference as modified while `get` hands back the default.
void _normalizationTests() {
  group('load normalises stale overrides', () {
    Future<PreferencesController> load(Map<String, Object?> stored) async {
      SharedPreferences.setMockInitialValues({
        PreferencesController.storageKey: jsonEncode(stored),
      });
      return PreferencesController.load(await SharedPreferences.getInstance());
    }

    test('drops a value that no longer decodes', () async {
      // e.g. an enum renamed between app versions.
      final c = await load({themeModePreference.id: 'ultraviolet'});

      expect(c.get(themeModePreference), ThemeMode.system);
      expect(
        c.isModified(themeModePreference),
        isFalse,
        reason: 'the effective value is the default, so nothing is modified',
      );
      expect(c.modifiedUserFacingCount, 0);
    });

    test('drops a value that now equals the default', () async {
      // e.g. the shipped default changed to match what the user had stored.
      final c = await load({themeModePreference.id: 'system'});

      expect(c.get(themeModePreference), ThemeMode.system);
      expect(c.isModified(themeModePreference), isFalse);
      expect(c.modifiedUserFacingCount, 0);
    });

    test('keeps a genuine non-default override', () async {
      final c = await load({themeModePreference.id: 'dark'});

      expect(c.get(themeModePreference), ThemeMode.dark);
      expect(c.isModified(themeModePreference), isTrue);
      expect(c.modifiedUserFacingCount, 1);
    });

    test('resetAll leaves an unknown id on disk', () async {
      // Consistency with load: if an unrecognised id is preserved because it
      // belongs to a newer build, Reset-all must not be the thing that deletes
      // it. Reloaded from storage, not just read back in memory, so this also
      // proves it was persisted.
      SharedPreferences.setMockInitialValues({
        PreferencesController.storageKey: jsonEncode({
          'from.the.future': 42,
          themeModePreference.id: 'dark',
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      final c = PreferencesController.load(prefs);

      await c.resetAll();
      final reloaded = PreferencesController.load(prefs);

      expect(reloaded.state.containsKey('from.the.future'), isTrue);
      expect(
        reloaded.isModified(themeModePreference),
        isFalse,
        reason: 'known preferences still reset',
      );
    });

    test('keeps an unknown id on disk but never counts it as modified', () async {
      // A newer build's setting seen by an older one: load preserves it, since
      // dropping it would silently discard the newer build's preference, but it
      // is not a setting *this* build can claim the user changed.
      final c = await load({'from.the.future': 42});

      expect(c.state.containsKey('from.the.future'), isTrue);
      expect(c.modifiedUserFacingCount, 0);
    });
  });
}
