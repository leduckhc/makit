// SPEC-29: Session DTO carries `resumable`; codec parses it (default false).
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/transport/codec.dart';

void main() {
  group('Session resumable field (SPEC-29)', () {
    test('decodeSessions parses resumable=true', () {
      final sessions = WireCodec.decodeSessions([
        {
          'id': 's1',
          'projectId': 'p1',
          'agent': 'pi',
          'title': 'resumable one',
          'status': 'exited',
          'policy': 'ask-on-risky',
          'resumable': true,
        },
      ]);
      expect(sessions!.single.resumable, isTrue);
    });

    test('resumable defaults to false when absent (back-compat)', () {
      final sessions = WireCodec.decodeSessions([
        {
          'id': 's2',
          'projectId': 'p1',
          'agent': 'pi',
          'title': 'legacy',
          'status': 'idle',
          'policy': 'ask-on-risky',
        },
      ]);
      expect(sessions!.single.resumable, isFalse);
      expect(sessions.single.closed, isFalse);
    });

    test('decodeSessions parses closed=true (SPEC-29)', () {
      final sessions = WireCodec.decodeSessions([
        {
          'id': 's3',
          'projectId': 'p1',
          'agent': 'pi',
          'title': 'closed one',
          'status': 'exited',
          'policy': 'ask-on-risky',
          'closed': true,
        },
      ]);
      expect(sessions!.single.closed, isTrue);
    });
  });
}
