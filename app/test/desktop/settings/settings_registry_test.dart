import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/settings/registry/settings_item.dart';
import 'package:makit/desktop/settings/registry/settings_registry.dart';
import 'package:makit/desktop/settings/registry/settings_section.dart';

void main() {
  group('kSettingsSections', () {
    test('lists the 8 top-level sections in taxonomy order', () {
      expect(kSettingsSections.map((s) => s.id).toList(), [
        'general',
        'appearance',
        'agents_chat',
        'server_devices',
        'notifications',
        'shortcuts',
        'advanced',
        'about',
      ]);
    });

    test('every section has a builder and a stable icon', () {
      for (final section in kSettingsSections) {
        expect(section.title, isNotEmpty);
        expect(section.builder, isNotNull);
        expect(section.icon, isNotNull);
      }
    });

    test('the default lastSection matches the first section id', () {
      expect(kSettingsSections.first.id, 'general');
    });
  });

  group('searchSettings', () {
    test('empty / whitespace query returns no results', () {
      expect(searchSettings(''), isEmpty);
      expect(searchSettings('   '), isEmpty);
    });

    test('matches item title case-insensitively', () {
      final results = searchSettings('THEME');
      expect(results, isNotEmpty);
      expect(results.any((r) => r.item.id == 'appearance.theme'), isTrue);
      final themeResult = results.firstWhere(
        (r) => r.item.id == 'appearance.theme',
      );
      expect(themeResult.sectionId, 'appearance');
    });

    test('matches on keywords', () {
      final results = searchSettings('dark');
      expect(results.any((r) => r.item.id == 'appearance.theme'), isTrue);
    });

    test('matches on help text', () {
      final section = SettingsSection(
        id: 's',
        title: 'S',
        icon: kSettingsSections.first.icon,
        builder: (_) => throw UnimplementedError(),
        items: const [
          SettingsItem(
            id: 's.item',
            title: 'Nothing here',
            help: 'A special phrase to find',
            keywords: ['unrelated'],
          ),
        ],
      );
      final results = searchSettings('special phrase', sections: [section]);
      expect(results.single.item.id, 's.item');
    });

    test('carries section id + item id on each result', () {
      final results = searchSettings('theme');
      for (final r in results) {
        expect(r.sectionId, isNotEmpty);
        expect(r.item.id, isNotEmpty);
      }
    });

    test('comingSoon items are still discoverable in search', () {
      // At least one reserved leaf should be searchable so the taxonomy is
      // discoverable (spec requirement #10 + assumption #3).
      final results = searchSettings('language');
      expect(results, isNotEmpty);
      expect(
        results.any(
          (r) => r.item.availability == SettingsAvailability.comingSoon,
        ),
        isTrue,
      );
    });
  });

  group('settings-registry drift guard', () {
    test('every SettingsItem.id is unique and resolves to its section', () {
      final sectionIds = kSettingsSections.map((s) => s.id).toSet();
      final seen = <String>{};
      for (final section in kSettingsSections) {
        for (final item in section.items) {
          // Ids must be unique app-wide.
          expect(
            seen.add(item.id),
            isTrue,
            reason: 'duplicate SettingsItem id: ${item.id}',
          );
          // Convention: `<sectionId>.<leaf>` — the prefix must resolve to a
          // real section, and it must be the section that owns the item.
          final prefix = item.id.split('.').first;
          expect(
            sectionIds.contains(prefix),
            isTrue,
            reason: 'SettingsItem id ${item.id} has no resolvable section',
          );
          expect(
            prefix,
            section.id,
            reason: 'SettingsItem ${item.id} is filed under ${section.id}',
          );
        }
      }
    });

    test('every SettingsItem.id resolves via searchSettings by title', () {
      for (final section in kSettingsSections) {
        for (final item in section.items) {
          final hits = searchSettings(item.title);
          expect(
            hits.any((r) => r.item.id == item.id),
            isTrue,
            reason: 'SettingsItem ${item.id} not found by its own title',
          );
        }
      }
    });
  });
}
