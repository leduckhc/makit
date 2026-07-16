import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/settings/prefs/preference.dart';
import 'package:makit/desktop/settings/prefs/preference_entries.dart';
import 'package:makit/desktop/settings/prefs/preferences_controller.dart';
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
      final controller = PreferencesController.ephemeral();
      await controller.set(themeModePreference, ThemeMode.dark);
      await controller.set(_intEntry, 5);
      await controller.resetAll();
      expect(controller.isModified(themeModePreference), isFalse);
      expect(controller.isModified(_intEntry), isFalse);
      expect(controller.state, isEmpty);
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
