// SPEC-52 C2a — `sessionIdentityProvider(sessionId)`: the seam that maps the
// store's `Session` to the UI-level `SessionIdentity` the panel watches (D19).
//
// The load-bearing invariant here is that the provider NEVER returns null and
// NEVER throws: the panel always has something to show (the makit session id at
// minimum), so a null provider would force every call site to branch. The
// no-throw tests below are what the "return null instead of a null-fields
// identity" mutation must break.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/session/session_identity.dart';

const kAgentId = '019fa9f4-443d-7d86-8f4c-d9c4988ddf4f';
const kPath =
    '/Users/le/.pi/agent/sessions/--Users-le-.worktrees-makit-feat-get-session-id--/'
    '2026-08-11T14-01-46-945Z_019ff121-1cc1-7c60-bc40-65890c87e6ff.jsonl';

Session _session({
  String id = 's1',
  String agent = 'pi',
  String? agentSessionId,
  String? transcriptPath,
}) => Session(
  id: id,
  projectId: 'p1',
  agent: agent,
  title: 'Session',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  agentSessionId: agentSessionId,
  transcriptPath: transcriptPath,
);

ProviderContainer _container(List<Session> sessions) {
  final container = ProviderContainer(
    overrides: [sessionsProvider.overrideWithValue(SessionsState(sessions))],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('C2a — sessionIdentityProvider', () {
    test('both wire fields present → a fully populated identity', () {
      final container = _container([
        _session(agentSessionId: kAgentId, transcriptPath: kPath),
      ]);
      final identity = container.read(sessionIdentityProvider('s1'));
      expect(identity.makitSessionId, 's1');
      expect(identity.agentLabel, 'pi session');
      expect(identity.agentSessionId, kAgentId);
      expect(identity.transcriptPath, kPath);
      expect(identity.resumeCommand, 'pi --session $kAgentId');
    });

    test('the per-agent label follows the session\'s agent', () {
      final container = _container([
        _session(agent: 'codex', agentSessionId: kAgentId),
      ]);
      final identity = container.read(sessionIdentityProvider('s1'));
      expect(identity.agentLabel, 'Thread');
      expect(identity.resumeCommand, 'codex resume $kAgentId');
    });

    test('neither field → a null-FIELDS identity, not null, and no throw', () {
      final container = _container([_session()]);
      final identity = container.read(sessionIdentityProvider('s1'));
      expect(identity, isNotNull);
      expect(identity.agentSessionId, isNull);
      expect(identity.transcriptPath, isNull);
      expect(identity.resumeCommand, isNull);
      // The makit id is always present — that is the whole point of never
      // returning null.
      expect(identity.makitSessionId, 's1');
    });

    test('an unknown session id → null-fields identity, no throw', () {
      // Choice (stated in the provider): an unknown id echoes back as the makit
      // id with an unknown agent, rather than throwing or returning null. That
      // is truthful (this client has no record of it) and keeps the panel
      // openable without a null check at every call site.
      final container = _container([]);
      final identity = container.read(sessionIdentityProvider('ghost'));
      expect(identity.makitSessionId, 'ghost');
      expect(identity.agentSessionId, isNull);
      expect(identity.transcriptPath, isNull);
      expect(identity.agentLabel, 'Agent session');
    });
  });
}
