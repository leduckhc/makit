/// SPEC-45 D3–D5 — the per-(agent, project) slash-command cache: what a live
/// session advertised, remembered so the pre-session starter pane can offer the
/// same palette.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/cached_commands.dart';
import 'package:makit/store/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _skill = SlashCmd(
  name: 'skill:dart-add-unit-test',
  description: 'Write unit tests',
  source: 'skill',
  location: 'project',
);
const _prompt = SlashCmd(
  name: 'fix-tests',
  description: 'Make the suite green',
  source: 'prompt',
);

/// The palette identifies a command by name, and `SlashCmd` has no value
/// equality, so assertions compare names.
List<String> names(List<SlashCmd> cmds) => [for (final c in cmds) c.name];

void main() {
  group('CachedCommandsController (ephemeral)', () {
    test('an unseen agent/project pair reads an empty list', () {
      final controller = CachedCommandsController.ephemeral();
      expect(controller.commandsFor('zed', 'p1'), isEmpty);
    });

    test('record makes the commands readable for that pair only', () async {
      final controller = CachedCommandsController.ephemeral();
      await controller.record(
        agent: 'zed',
        projectId: 'p1',
        commands: [_skill],
      );

      expect(names(controller.commandsFor('zed', 'p1')), [_skill.name]);
      // A different harness in the same repo, and the same harness in another
      // repo, are different palettes.
      expect(controller.commandsFor('codex', 'p1'), isEmpty);
      expect(controller.commandsFor('zed', 'p2'), isEmpty);
    });

    test('record replaces the previous list wholesale', () async {
      final controller = CachedCommandsController.ephemeral();
      await controller.record(
        agent: 'zed',
        projectId: 'p1',
        commands: [_skill],
      );
      await controller.record(
        agent: 'zed',
        projectId: 'p1',
        commands: [_prompt],
      );
      expect(names(controller.commandsFor('zed', 'p1')), [_prompt.name]);
    });

    test('an empty advertisement never overwrites a known list', () async {
      final controller = CachedCommandsController.ephemeral();
      await controller.record(
        agent: 'zed',
        projectId: 'p1',
        commands: [_skill],
      );
      await controller.record(
        agent: 'zed',
        projectId: 'p1',
        commands: const [],
      );
      expect(names(controller.commandsFor('zed', 'p1')), [_skill.name]);
    });

    test('an empty advertisement for an unknown pair stores nothing', () async {
      final controller = CachedCommandsController.ephemeral();
      await controller.record(
        agent: 'zed',
        projectId: 'p1',
        commands: const [],
      );
      expect(controller.state, isEmpty);
    });

    test(
      'the oldest-written pair is evicted past kCachedCommandKeysMax',
      () async {
        final controller = CachedCommandsController.ephemeral();
        for (var i = 0; i < kCachedCommandKeysMax + 2; i++) {
          await controller.record(
            agent: 'zed',
            projectId: 'p$i',
            commands: [_skill],
          );
        }
        expect(controller.state, hasLength(kCachedCommandKeysMax));
        expect(controller.commandsFor('zed', 'p0'), isEmpty);
        expect(controller.commandsFor('zed', 'p1'), isEmpty);
        expect(names(controller.commandsFor('zed', 'p2')), [_skill.name]);
      },
    );

    test(
      're-recording a pair refreshes its place in the eviction order',
      () async {
        final controller = CachedCommandsController.ephemeral();
        for (var i = 0; i < kCachedCommandKeysMax; i++) {
          await controller.record(
            agent: 'zed',
            projectId: 'p$i',
            commands: [_skill],
          );
        }
        // p0 is the oldest — touching it must save it from the next eviction.
        await controller.record(
          agent: 'zed',
          projectId: 'p0',
          commands: [_prompt],
        );
        await controller.record(
          agent: 'zed',
          projectId: 'new',
          commands: [_skill],
        );

        expect(names(controller.commandsFor('zed', 'p0')), [_prompt.name]);
        expect(controller.commandsFor('zed', 'p1'), isEmpty);
      },
    );
  });

  group('CachedCommandsController (persistent)', () {
    test('record writes one json map under a single key', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = CachedCommandsController.load(prefs);

      await controller.record(
        agent: 'zed',
        projectId: 'p1',
        commands: [_skill],
      );

      final raw = prefs.getString(CachedCommandsController.storageKey);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded.keys.single, contains('zed'));
      final entries = decoded.values.single as List;
      expect((entries.single as Map)['name'], 'skill:dart-add-unit-test');
      expect((entries.single as Map)['source'], 'skill');
      expect((entries.single as Map)['location'], 'project');
    });

    test('a persisted cache is read back on load', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final first = CachedCommandsController.load(prefs);
      await first.record(
        agent: 'zed',
        projectId: 'p1',
        commands: [_skill, _prompt],
      );

      final reloaded = CachedCommandsController.load(prefs);
      final restored = reloaded.commandsFor('zed', 'p1');
      expect(names(restored), [_skill.name, _prompt.name]);
      // Every field round-trips, not just the name the palette filters on.
      expect(restored.first.description, _skill.description);
      expect(restored.first.source, 'skill');
      expect(restored.first.location, 'project');
      expect(restored.last.location, isNull);
    });

    test('corrupt json loads as an empty cache instead of throwing', () async {
      SharedPreferences.setMockInitialValues({
        CachedCommandsController.storageKey: 'not json',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(CachedCommandsController.load(prefs).state, isEmpty);
    });

    test('entries that are not command maps are skipped', () async {
      SharedPreferences.setMockInitialValues({
        CachedCommandsController.storageKey: jsonEncode({
          'zed\u0000p1': [
            {'description': 'no name — unusable'},
            {'name': 'ok', 'description': '', 'source': 'prompt'},
          ],
          'zed\u0000p2': 'not a list',
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      final controller = CachedCommandsController.load(prefs);
      expect(controller.commandsFor('zed', 'p1').map((c) => c.name), ['ok']);
      expect(controller.commandsFor('zed', 'p2'), isEmpty);
    });

    test('a wrong-typed field does not take the whole cache down', () async {
      // `SlashCmd.fromJson` casts with `as String?`, which THROWS on a
      // wrong-typed field rather than returning null — so `whereType` cannot
      // filter it. This blob is loaded during the desktop bootstrap, so an
      // unhandled throw here is a failure to start, not a lost palette.
      SharedPreferences.setMockInitialValues({
        CachedCommandsController.storageKey: jsonEncode({
          'zed\u0000p1': [
            {'name': 123, 'description': 'name is a number'},
            {'name': 'survivor', 'description': '', 'source': 'skill'},
          ],
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      late CachedCommandsController controller;
      expect(
        () => controller = CachedCommandsController.load(prefs),
        returnsNormally,
      );
      expect(names(controller.commandsFor('zed', 'p1')), ['survivor']);
    });
  });
}
