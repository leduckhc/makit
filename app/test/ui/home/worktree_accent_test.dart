import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/home/repo_chips.dart';

/// Direction C encodes a worktree's state as a coloured accent bar. The mapping
/// is a pure function so the precedence is pinned here rather than inferred from
/// pixels: the bar's whole job is to be scannable, and it can only be trusted if
/// "wants you" always wins over "busy".
Session _s(SessionStatus status, {bool pending = false}) => Session(
  id: 'x${status.name}$pending',
  projectId: 'p1',
  agent: 'pi',
  title: 't',
  status: status,
  policy: ApprovalPolicy.askOnRisky,
  pending: pending,
);

void main() {
  test('no sessions is a quiet worktree', () {
    expect(worktreeAccent(const []), WorktreeAccent.none);
  });

  test('a running session reads as working', () {
    expect(worktreeAccent([_s(SessionStatus.running)]), WorktreeAccent.working);
  });

  test('idle and exited sessions do not colour the bar', () {
    expect(
      worktreeAccent([_s(SessionStatus.idle), _s(SessionStatus.exited)]),
      WorktreeAccent.none,
    );
  });

  group('"wants you" outranks everything', () {
    test('awaiting input beats a running sibling', () {
      expect(
        worktreeAccent([
          _s(SessionStatus.running),
          _s(SessionStatus.awaitingInput),
        ]),
        WorktreeAccent.wantsYou,
      );
    });

    test('awaiting approval beats a running sibling', () {
      expect(
        worktreeAccent([
          _s(SessionStatus.running),
          _s(SessionStatus.awaitingApproval),
        ]),
        WorktreeAccent.wantsYou,
      );
    });

    test('awaiting input beats an errored sibling', () {
      expect(
        worktreeAccent([
          _s(SessionStatus.error),
          _s(SessionStatus.awaitingInput),
        ]),
        WorktreeAccent.wantsYou,
      );
    });
  });

  test('an error outranks working but not a request for the user', () {
    expect(
      worktreeAccent([_s(SessionStatus.error), _s(SessionStatus.running)]),
      WorktreeAccent.failed,
    );
  });

  test('a draft is not yet a running session, so it stays quiet', () {
    expect(
      worktreeAccent([_s(SessionStatus.running, pending: true)]),
      WorktreeAccent.none,
    );
  });

  test('a draft is skipped, not short-circuited, next to a live session', () {
    // Guards the `continue`: an early `return` on the pending session would
    // still pass the lone-draft case above, but would hide the live sibling.
    expect(
      worktreeAccent([
        _s(SessionStatus.running, pending: true),
        _s(SessionStatus.running),
      ]),
      WorktreeAccent.working,
    );
  });
}
