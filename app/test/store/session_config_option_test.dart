import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';

void main() {
  group('SessionConfigOption.fromJson', () {
    test('parses a flat select option', () {
      final opt = SessionConfigOption.fromJson({
        'id': 'model',
        'name': 'Model',
        'description': 'Which model to run',
        'category': 'model',
        'type': 'select',
        'currentValue': 'gpt-5',
        'options': [
          {'value': 'gpt-5', 'name': 'GPT-5', 'description': 'flagship'},
          {'value': 'o3', 'name': 'o3'},
        ],
      });
      expect(opt, isNotNull);
      expect(opt!.id, 'model');
      expect(opt.name, 'Model');
      expect(opt.description, 'Which model to run');
      expect(opt.category, 'model');
      expect(opt.type, ConfigOptionType.select);
      expect(opt.currentValue, 'gpt-5');
      expect(opt.options, hasLength(2));
      expect(opt.options[0].value, 'gpt-5');
      expect(opt.options[0].name, 'GPT-5');
      expect(opt.options[0].description, 'flagship');
      expect(opt.options[1].name, 'o3');
      expect(opt.options[1].description, isNull);
      expect(opt.groups, isEmpty);
    });

    test('parses a grouped select option', () {
      final opt = SessionConfigOption.fromJson({
        'id': 'model',
        'name': 'Model',
        'category': 'model',
        'type': 'select',
        'currentValue': 'claude-opus',
        'groups': [
          {
            'name': 'Anthropic',
            'options': [
              {'value': 'claude-opus', 'name': 'Opus'},
              {'value': 'claude-sonnet', 'name': 'Sonnet'},
            ],
          },
          {
            'name': 'OpenAI',
            'options': [
              {'value': 'gpt-5', 'name': 'GPT-5'},
            ],
          },
        ],
      });
      expect(opt, isNotNull);
      expect(opt!.groups, hasLength(2));
      expect(opt.groups[0].name, 'Anthropic');
      expect(opt.groups[0].options, hasLength(2));
      expect(opt.groups[0].options[0].value, 'claude-opus');
      expect(opt.groups[1].name, 'OpenAI');
      expect(opt.groups[1].options.single.value, 'gpt-5');
      expect(opt.options, isEmpty);
    });

    test('parses a boolean option', () {
      final opt = SessionConfigOption.fromJson({
        'id': 'web',
        'name': 'Web search',
        'type': 'boolean',
        'currentValue': true,
      });
      expect(opt, isNotNull);
      expect(opt!.type, ConfigOptionType.boolean);
      expect(opt.currentValue, isTrue);
      expect(opt.options, isEmpty);
      expect(opt.groups, isEmpty);
    });

    test('preserves an unknown category as a string', () {
      final opt = SessionConfigOption.fromJson({
        'id': 'x',
        'name': 'X',
        'category': '_experimental',
        'type': 'select',
        'currentValue': 'a',
      });
      expect(opt, isNotNull);
      expect(opt!.category, '_experimental');
    });

    test('defaults type to select when absent', () {
      final opt = SessionConfigOption.fromJson({
        'id': 'mode',
        'name': 'Mode',
        'currentValue': 'ask',
      });
      expect(opt, isNotNull);
      expect(opt!.type, ConfigOptionType.select);
    });

    test('returns null when id is missing', () {
      expect(
        SessionConfigOption.fromJson({'name': 'X', 'type': 'select'}),
        isNull,
      );
    });

    test('returns null when name is missing', () {
      expect(
        SessionConfigOption.fromJson({'id': 'x', 'type': 'select'}),
        isNull,
      );
    });
  });

  group('SessionMeta.configOptions', () {
    test('is empty when configOptions is absent (legacy-only meta)', () {
      final meta = SessionMeta.fromJson({
        'model': {'provider': 'openai', 'id': 'gpt-5', 'name': 'GPT-5'},
        'thinking': 'high',
        'models': [
          {'provider': 'openai', 'id': 'gpt-5', 'name': 'GPT-5'},
        ],
        'modes': {
          'current': 'ask',
          'available': [
            {'id': 'ask', 'name': 'Ask'},
          ],
        },
      });
      expect(meta.configOptions, isEmpty);
      // Legacy fields still parse untouched.
      expect(meta.model?.id, 'gpt-5');
      expect(meta.thinking, 'high');
      expect(meta.models, hasLength(1));
      expect(meta.modes?.current, 'ask');
    });

    test('parses configOptions preserving order', () {
      final meta = SessionMeta.fromJson(<String, Object?>{
        'thinking': '',
        'models': const [],
        'configOptions': [
          {'id': 'a', 'name': 'A', 'type': 'select', 'currentValue': '1'},
          {'id': 'b', 'name': 'B', 'type': 'boolean', 'currentValue': false},
          {'id': 'c', 'name': 'C', 'type': 'select', 'currentValue': '2'},
        ],
      });
      expect(meta.configOptions.map((o) => o.id).toList(), ['a', 'b', 'c']);
    });

    test('skips malformed entries without throwing', () {
      final meta = SessionMeta.fromJson(<String, Object?>{
        'thinking': '',
        'models': const [],
        'configOptions': [
          <String, Object?>{'id': 'ok', 'name': 'OK', 'type': 'select', 'currentValue': '1'},
          'not-a-map',
          {'name': 'no id'},
          42,
          {'id': 'ok2', 'name': 'OK2', 'type': 'boolean', 'currentValue': true},
        ],
      });
      expect(meta.configOptions.map((o) => o.id).toList(), ['ok', 'ok2']);
    });

    test('both legacy + configOptions present → both accessible', () {
      final meta = SessionMeta.fromJson(<String, Object?>{
        'model': {'provider': 'openai', 'id': 'gpt-5', 'name': 'GPT-5'},
        'thinking': 'high',
        'models': const [],
        'modes': {
          'current': 'ask',
          'available': [
            {'id': 'ask', 'name': 'Ask'},
          ],
        },
        'configOptions': [
          {
            'id': 'model',
            'name': 'Model',
            'category': 'model',
            'type': 'select',
            'currentValue': 'gpt-5',
          },
        ],
      });
      expect(meta.modes?.current, 'ask');
      expect(meta.model?.id, 'gpt-5');
      expect(meta.configOptions, hasLength(1));
      expect(meta.configOptions.single.category, 'model');
    });
  });
}
