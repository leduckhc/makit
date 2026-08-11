// SPEC-52 A1 + A2 — the pure half of session identity: the per-agent vocabulary
// table and the clipboard payload.
//
// These are unit tests on pure functions, deliberately, for the same reason
// `context_usage_test.dart` tests `formatTokens` / `headroomLabel` directly: the
// copy contract is the feature, and a widget test would only observe it through
// three layers of rendering.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/session/session_identity.dart';

/// Two REAL pi session ids from one directory on the author's machine that share
/// their first 8 characters. They are the standing evidence for D15: pi ids are
/// UUIDv7, whose first 48 bits are a millisecond timestamp, so an 8-char prefix
/// pins only the top 32 bits and leaves ~65 s of ambiguity.
///
/// Review drove the ambiguity to be sure: `pi --session 019fa9f4` does NOT error
/// — it silently resolves to one of these and offers to fork it. A resume
/// command that can silently target the wrong session is worse than no command,
/// so the full id is asserted below and the prefix form is asserted absent.
const kRealId = '019fa9f4-443d-7d86-8f4c-d9c4988ddf4f';
const kCollidingId = '019fa9f4-d3c8-7e0d-9e34-8c70180ca113';
const kSharedPrefix = '019fa9f4';

const kRealPath =
    '/Users/le/.pi/agent/sessions/--Users-le-.worktrees-makit-feat-get-session-id--/'
    '2026-08-11T14-01-46-945Z_019ff121-1cc1-7c60-bc40-65890c87e6ff.jsonl';

SessionIdentity _identity({
  String agent = 'pi',
  String makitSessionId = '7c9e6d5a-1f42-4b8e-9a01-2d3f4e5a6b7c',
  String? agentSessionId = kRealId,
  String? transcriptPath = kRealPath,
}) => SessionIdentity.from(
  agent: agent,
  makitSessionId: makitSessionId,
  agentSessionId: agentSessionId,
  transcriptPath: transcriptPath,
);

void main() {
  group('A1 — per-agent vocabulary (D10, D15)', () {
    test('pi gets pi\'s own noun and its --session flag', () {
      final id = _identity(agent: 'pi');
      expect(id.agentLabel, 'pi session');
      expect(id.resumeCommand, 'pi --session $kRealId');
    });

    test('codex gets codex\'s own noun (thread) and its resume verb', () {
      final id = _identity(agent: 'codex');
      expect(id.agentLabel, 'Thread');
      expect(id.resumeCommand, 'codex resume $kRealId');
    });

    test('an unknown agent gets a generic label and NO resume command', () {
      // The open/closed escape hatch: a third agent works unedited, it just
      // does not get a resume line, because inventing a CLI we have never seen
      // is D9's failure mode in command form.
      final id = _identity(agent: 'stub');
      expect(id.agentLabel, 'Agent session');
      expect(id.resumeCommand, isNull);
    });

    test('D15 — the resume command carries the FULL id, never a prefix', () {
      for (final agent in ['pi', 'codex']) {
        final cmd = _identity(agent: agent).resumeCommand!;
        expect(
          cmd,
          contains(kRealId),
          reason: '$agent must resume by the whole 36-char id',
        );
        // The specific unsafe form, spelled out so the mutation is obvious.
        expect(
          cmd.endsWith(kSharedPrefix),
          isFalse,
          reason:
              'a truncated id can silently resolve to $kCollidingId, which '
              'shares the prefix $kSharedPrefix in the same directory',
        );
      }
    });

    test('no agent session id means no resume command, for every agent', () {
      for (final agent in ['pi', 'codex', 'stub']) {
        expect(
          _identity(agent: agent, agentSessionId: null).resumeCommand,
          isNull,
          reason: '$agent cannot be resumed by an id that does not exist',
        );
      }
    });
  });

  group('A2 — sessionIdentityText (D14, D4, D9)', () {
    test('four measured values produce four label: value lines', () {
      final text = sessionIdentityText(_identity());
      final lines = text.split('\n');
      expect(lines, hasLength(4));
      for (final line in lines) {
        expect(line, contains(': '), reason: 'every line is label: value');
      }
      expect(text, contains(kRealId));
      expect(text, contains(kRealPath));
    });

    test('labels are padded into a shared column', () {
      // Asserted rather than implied: rev 1 stated the padding but left it
      // unprovable, so a stub that never padded would have passed.
      final lines = sessionIdentityText(_identity()).split('\n');
      final valueStarts = lines.map((l) => l.indexOf(': ') + 2).toSet();
      expect(
        valueStarts,
        hasLength(1),
        reason: 'all values begin at the same column: $lines',
      );
    });

    test('no trailing newline', () {
      expect(sessionIdentityText(_identity()).endsWith('\n'), isFalse);
    });

    test('D4 — the path is absolute and unabbreviated, and no ~ appears', () {
      final text = sessionIdentityText(_identity());
      expect(text, contains('/Users/le/.pi/agent/sessions/'));
      expect(
        text,
        isNot(contains('~')),
        reason:
            'the path belongs to the SERVER host; ~ only expands if a shell '
            'gets there first, and the receiver here may be a prompt',
      );
    });

    test('D9 — an unmeasured transcript omits its line entirely', () {
      final text = sessionIdentityText(_identity(transcriptPath: null));
      final lines = text.split('\n');
      expect(lines, hasLength(3));
      expect(text, isNot(contains('transcript')));
      expect(
        lines.any((l) => l.trim().endsWith(':')),
        isFalse,
        reason: 'no label may be emitted with an empty value',
      );
      expect(text, isNot(contains('\n\n')), reason: 'no blank line');
    });

    test('D9 — an unknown agent omits the resume line', () {
      final text = sessionIdentityText(_identity(agent: 'stub'));
      expect(text, isNot(contains('resume')));
      expect(text.split('\n'), hasLength(3));
    });

    test('the payload is plain text: no markdown, no fences, no JSON', () {
      final text = sessionIdentityText(_identity());
      for (final noise in ['```', '**', '- ', '{', '}', '|']) {
        expect(
          text,
          isNot(contains(noise)),
          reason: 'must survive being pasted into a prompt or a shell comment',
        );
      }
    });

    test('an identity with nothing but the makit id still copies one line', () {
      final text = sessionIdentityText(
        _identity(agent: 'stub', agentSessionId: null, transcriptPath: null),
      );
      expect(text.split('\n'), hasLength(1));
      expect(text, contains('7c9e6d5a-1f42-4b8e-9a01-2d3f4e5a6b7c'));
    });
  });
}
