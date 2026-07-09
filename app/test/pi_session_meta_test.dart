import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';

void main() {
  test('PiSessionMeta.fromJson maps all fields', () {
    final m = PiSessionMeta.fromJson({
      'piSessionId': 'abc-123',
      'name': 'refactor the parser',
      'lastActivityAt': 1735689600000,
      'preview': 'refactor the parser to be pure',
      'messageCount': 12,
    });
    expect(m, isNotNull);
    expect(m!.piSessionId, 'abc-123');
    expect(m.name, 'refactor the parser');
    expect(m.lastActivityAt, 1735689600000);
    expect(m.preview, 'refactor the parser to be pure');
    expect(m.messageCount, 12);
  });

  test('PiSessionMeta.fromJson returns null without a piSessionId', () {
    expect(PiSessionMeta.fromJson({'name': 'x'}), isNull);
  });

  test('PiSessionMeta.fromJson tolerates missing optional fields', () {
    final m = PiSessionMeta.fromJson({'piSessionId': 'id'});
    expect(m, isNotNull);
    expect(m!.name, '');
    expect(m.preview, '');
    expect(m.messageCount, 0);
    expect(m.lastActivityAt, 0);
  });
}
