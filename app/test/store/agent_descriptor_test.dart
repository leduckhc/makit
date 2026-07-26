import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';

void main() {
  group('AgentDescriptor.fromJson', () {
    test('parses transport, fingerprint, and configOptions', () {
      final d = AgentDescriptor.fromJson({
        'id': 'pi',
        'label': 'Pi (ACP)',
        'transport': 'acp',
        'available': true,
        'fingerprint': 'abc123',
        'configOptions': [
          {
            'id': 'model',
            'name': 'Model',
            'category': 'model',
            'type': 'select',
            'currentValue': 'gpt-5',
            'options': [
              {'value': 'gpt-5', 'name': 'GPT-5'},
            ],
          },
          {
            'id': 'reasoning',
            'name': 'Reasoning',
            'category': 'thought_level',
            'type': 'select',
            'currentValue': 'high',
          },
        ],
      });
      expect(d, isNotNull);
      expect(d!.id, 'pi');
      expect(d.label, 'Pi (ACP)');
      expect(d.transport, 'acp');
      expect(d.available, isTrue);
      expect(d.fingerprint, 'abc123');
      expect(d.configOptions, hasLength(2));
      expect(d.configOptions[0].id, 'model');
      expect(d.configOptions[0].category, 'model');
      expect(d.configOptions[1].id, 'reasoning');
    });

    test('defaults fingerprint to empty and configOptions to empty', () {
      final d = AgentDescriptor.fromJson({
        'id': 'codex',
        'transport': 'native',
      });
      expect(d, isNotNull);
      expect(d!.id, 'codex');
      expect(d.label, 'codex');
      expect(d.transport, 'native');
      expect(d.available, isTrue);
      expect(d.fingerprint, '');
      expect(d.configOptions, isEmpty);
    });

    test('tolerates wrong-typed fingerprint and configOptions', () {
      final d = AgentDescriptor.fromJson({
        'id': 'pi',
        'fingerprint': 42,
        'configOptions': 'nope',
      });
      expect(d, isNotNull);
      expect(d!.fingerprint, '');
      expect(d.configOptions, isEmpty);
      // absent transport falls back to native (existing behavior).
      expect(d.transport, 'native');
    });

    test('drops malformed configOptions entries', () {
      final d = AgentDescriptor.fromJson({
        'id': 'pi',
        'configOptions': [
          {'id': 'model', 'name': 'Model', 'currentValue': 'gpt-5'},
          {'name': 'no-id'},
          'garbage',
        ],
      });
      expect(d, isNotNull);
      expect(d!.configOptions, hasLength(1));
      expect(d.configOptions.single.id, 'model');
    });

    test('returns null when id is missing', () {
      expect(AgentDescriptor.fromJson({'label': 'x'}), isNull);
    });
  });

  group('ConfigOptionPick.toJson', () {
    test('serializes a string pick', () {
      expect(const ConfigOptionPick(id: 'model', value: 'gpt-5').toJson(), {
        'id': 'model',
        'value': 'gpt-5',
      });
    });

    test('serializes a boolean pick', () {
      expect(const ConfigOptionPick(id: 'yolo', value: true).toJson(), {
        'id': 'yolo',
        'value': true,
      });
    });
  });
}
