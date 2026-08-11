// SPEC-52 B1 — the wire contract for session identity.
//
// Two OPTIONAL fields on `SessionDTO`: `agentSessionId` and `transcriptPath`.
// Optional so a new app paired with an older server renders fewer rows rather
// than a fabricated one — the same rule `createdAt` follows (SPEC-47 D12).
//
// The empty-string cases are not paranoia. `''` is what a sloppy or partially
// migrated server sends for "I have no value", and an empty string here would
// render a copy affordance that copies nothing — which is exactly the
// placeholder D9 exists to forbid. Normalising at the edge means every consumer
// above this line only has to check for null.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/transport/codec.dart';

Session _decode(Map<String, Object?> extra) {
  final sessions = WireCodec.decodeSessions([
    {
      'id': 's1',
      'projectId': 'p1',
      'agent': 'pi',
      'title': 'T',
      'status': 'idle',
      'policy': 'ask-on-risky',
      ...extra,
    },
  ]);
  return sessions!.single;
}

void main() {
  test('both identity fields survive the wire', () {
    final s = _decode({
      'agentSessionId': '019fa9f4-443d-7d86-8f4c-d9c4988ddf4f',
      'transcriptPath': '/Users/le/.pi/agent/sessions/--x--/a.jsonl',
    });
    expect(s.agentSessionId, '019fa9f4-443d-7d86-8f4c-d9c4988ddf4f');
    expect(s.transcriptPath, '/Users/le/.pi/agent/sessions/--x--/a.jsonl');
  });

  test('an older server that sends neither yields two nulls', () {
    final s = _decode({});
    expect(s.agentSessionId, isNull);
    expect(s.transcriptPath, isNull);
  });

  test('an empty string is normalised to null, not kept as a blank row', () {
    final s = _decode({'agentSessionId': '', 'transcriptPath': ''});
    expect(s.agentSessionId, isNull);
    expect(s.transcriptPath, isNull);
  });

  test('a non-string is rejected rather than coerced', () {
    // A malformed snapshot must not take down the session list — the same
    // degrade-don't-crash rule the rest of `decodeSessions` follows.
    final s = _decode({'agentSessionId': 42, 'transcriptPath': false});
    expect(s.agentSessionId, isNull);
    expect(s.transcriptPath, isNull);
  });

  test('copyWith carries them', () {
    final s = _decode({
      'agentSessionId': 'a',
      'transcriptPath': '/p',
    }).copyWith(title: 'renamed');
    expect(s.agentSessionId, 'a');
    expect(s.transcriptPath, '/p');
  });
}
