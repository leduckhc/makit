import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/recent_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('RecentModelsController (ephemeral)', () {
    test('unknown agent reads an empty list', () {
      final controller = RecentModelsController.ephemeral();
      expect(controller.recentModels('zed'), isEmpty);
    });

    test('recordSelect prepends most-recent-first', () async {
      final controller = RecentModelsController.ephemeral();
      await controller.recordSelect('zed', 'gpt-5');
      await controller.recordSelect('zed', 'opus');
      expect(controller.recentModels('zed'), ['opus', 'gpt-5']);
    });

    test(
      'recordSelect dedupes and moves an existing value to the front',
      () async {
        final controller = RecentModelsController.ephemeral();
        await controller.recordSelect('zed', 'gpt-5');
        await controller.recordSelect('zed', 'opus');
        await controller.recordSelect('zed', 'gpt-5');
        expect(controller.recentModels('zed'), ['gpt-5', 'opus']);
      },
    );

    test('recordSelect caps the list at kRecentModelsMax', () async {
      final controller = RecentModelsController.ephemeral();
      for (var i = 0; i < kRecentModelsMax + 3; i++) {
        await controller.recordSelect('zed', 'm$i');
      }
      final recent = controller.recentModels('zed');
      expect(recent, hasLength(kRecentModelsMax));
      // Most-recent-first: the last recorded is at the head.
      expect(recent.first, 'm${kRecentModelsMax + 2}');
      // The three oldest were evicted.
      expect(recent, isNot(contains('m0')));
    });

    test('recent lists are isolated per agent', () async {
      final controller = RecentModelsController.ephemeral();
      await controller.recordSelect('zed', 'gpt-5');
      await controller.recordSelect('codex', 'opus');
      expect(controller.recentModels('zed'), ['gpt-5']);
      expect(controller.recentModels('codex'), ['opus']);
    });
  });

  group('RecentModelsController (persistent)', () {
    test('recordSelect writes a single json map under one key', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = RecentModelsController.load(prefs);

      await controller.recordSelect('zed', 'gpt-5');
      final raw = prefs.getString(RecentModelsController.storageKey);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['zed'], ['gpt-5']);
    });

    test('load reconstructs recents from prefs', () async {
      SharedPreferences.setMockInitialValues({
        RecentModelsController.storageKey: jsonEncode({
          'zed': ['gpt-5', 'opus'],
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      final controller = RecentModelsController.load(prefs);
      expect(controller.recentModels('zed'), ['gpt-5', 'opus']);
    });

    test('corrupt json falls back to empty', () async {
      SharedPreferences.setMockInitialValues({
        RecentModelsController.storageKey: 'not-json{',
      });
      final prefs = await SharedPreferences.getInstance();
      final controller = RecentModelsController.load(prefs);
      expect(controller.recentModels('zed'), isEmpty);
    });

    test('a malformed agent entry is ignored (not a string list)', () async {
      SharedPreferences.setMockInitialValues({
        RecentModelsController.storageKey: jsonEncode({
          'zed': 'not-a-list',
          'codex': ['opus', 42, 'gpt-5'],
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      final controller = RecentModelsController.load(prefs);
      expect(controller.recentModels('zed'), isEmpty);
      // Non-string members are dropped, string members preserved in order.
      expect(controller.recentModels('codex'), ['opus', 'gpt-5']);
    });
  });
}
