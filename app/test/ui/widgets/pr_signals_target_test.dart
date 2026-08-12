// Step 8: an unresolvable target must be SAID, not merely hidden.
//
// Suppressing the +/- pill (which `Worktree.showsDiff` does) stops the app
// publishing a partial count that reads as "barely diverged". But suppression
// alone makes the row identical to a clean worktree: the user has committed work
// and the UI says nothing. This signal is what closes that gap.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/widgets/pr_signals.dart';

void main() {
  test('an automatic retarget is announced as a quiet fact', () {
    // Rule 4: a target that vanished without a wrap-up falls back to the default,
    // and the change must be SAID. A silent repoint moves this worktree's diff and
    // its future pull request to a different destination.
    final s = prStatus(
      pr: null,
      branch: 'feat/child',
      targetBranch: 'main',
      retargetedFrom: 'feat/parent',
    );
    final fact = s.signals.firstWhere((x) => x.label.contains('feat/parent'));
    expect(fact.label, contains('main'));
    expect(
      fact.tone,
      PrTone.quiet,
      reason: 'it is already fixed, so it informs rather than demands',
    );
    expect(fact.remedy, isNull);
  });

  test('the announcement never outranks an actionable fact', () {
    // Caught in the real app: added too early in the list it became the composer
    // strip's headline and pushed `1 commit unpushed` into `+1 more` — an
    // informational note crowding out the thing you can act on. `loud` is just
    // `signals.first`, so position IS the priority.
    final s = prStatus(
      pr: null,
      branch: 'feat/child',
      uncommittedFiles: 1,
      targetBranch: 'main',
      retargetedFrom: 'feat/parent',
    );
    expect(s.loud.label, contains('uncommitted'));
    expect(s.signals.last.label, contains('was feat/parent'));
  });

  test('the announcement is always listed, even behind the all-clear', () {
    // It never takes the loud slot — not from an actionable fact, and not from the
    // all-clear either: "ready for a PR" is the more useful headline, and the
    // announcement's required home is the sheet (which lists every signal) plus
    // the strip's `+n more`. Simplest rule that satisfies "say so": always
    // present, never promoted.
    final s = prStatus(
      pr: null,
      branch: 'feat/child',
      targetBranch: 'main',
      retargetedFrom: 'feat/parent',
    );
    expect(s.loud.label, isNot(contains('was feat/parent')));
    expect(
      s.signals.any((x) => x.label.contains('was feat/parent, now main')),
      isTrue,
    );
  });

  test('no announcement once the user has taken ownership', () {
    final s = prStatus(pr: null, branch: 'feat/child', targetBranch: 'main');
    expect(s.signals.any((x) => x.label.contains('was ')), isFalse);
  });

  test(
    'an unresolvable target is still reported when nothing could be salvaged',
    () {
      final s = prStatus(
        pr: null,
        branch: 'feat/child',
        uncommittedFiles: 2,
        targetBranch: 'feat/parent',
        targetResolved: false,
      );
      expect(s.signals.first.label, contains('feat/parent'));
      expect(s.signals.first.label, contains('gone'));
      expect(
        s.signals.first.tone,
        PrTone.blocking,
        reason: 'you cannot land anywhere, so it outranks uncommitted work',
      );
    },
  );

  test('it carries no remedy — the fix lives in the pickers, one line up', () {
    final s = prStatus(
      pr: null,
      branch: 'feat/child',
      targetBranch: 'feat/parent',
      targetResolved: false,
    );
    // Deliberately not a PrDirectOp: opening a picker is navigation, and the
    // remedy plumbing is built for server ops and canned prompts.
    expect(s.signals.first.remedy, isNull);
  });

  test('a resolved target adds no signal at all', () {
    final s = prStatus(
      pr: null,
      branch: 'feat/child',
      uncommittedFiles: 1,
      targetBranch: 'feat/parent',
      targetResolved: true,
    );
    expect(
      s.signals.any((x) => x.label.contains('feat/parent')),
      isFalse,
      reason: 'a working target is not news',
    );
  });

  test('no target means nothing to resolve, so no signal', () {
    // The primary checkout and detached worktrees have no target.
    final s = prStatus(
      pr: null,
      branch: 'main',
      isPrimary: true,
      targetBranch: null,
      targetResolved: true,
    );
    expect(s.signals.any((x) => x.label.contains('gone')), isFalse);
  });

  test('the signal survives alongside an open PR', () {
    // Retargeting an open PR is legitimate, so a PR does not suppress this.
    // Pass an actual OPEN PR (not null) so the test exercises the contract its
    // name states, not merely the commitsAhead path.
    const openPr = PullRequest(
      number: 4,
      url: 'https://example.test/4',
      state: 'OPEN',
      title: 'child',
      isDraft: false,
      checkRollup: 'none',
      unresolvedComments: 0,
      checks: [],
    );
    final s = prStatus(
      pr: openPr,
      branch: 'feat/child',
      commitsAhead: 3,
      targetBranch: 'feat/parent',
      targetResolved: false,
    );
    expect(s.signals.first.label, contains('gone'));
    expect(s.signals.length, greaterThan(1));
  });

  // The CTA must not offer to open a PR when the target is gone: `gh pr create`
  // would fall back to the CLI default and raise the PR against the WRONG base.
  group('an unresolvable target gates the PR-creating CTA', () {
    test('a PR-less branch with a resolvable target still offers Ship it', () {
      final s = prStatus(
        pr: null,
        branch: 'feat/child',
        targetBranch: 'feat/parent',
        targetResolved: true,
      );
      expect(s.cta.label, 'Ship it');
      expect(s.cta.remedy, isA<PromptRemedy>());
    });

    test('an unresolvable target withdraws Ship it (nowhere to land)', () {
      final s = prStatus(
        pr: null,
        branch: 'feat/child',
        targetBranch: 'feat/parent',
        targetResolved: false,
      );
      expect(s.cta.label, isNot('Ship it'));
      // Falls back to the non-actionable offer rather than a wrong-base create.
      expect(s.cta.label, 'Ask the agent');
      expect(s.cta.isIdle, isTrue);
    });

    test(
      'a null target (no destination set) still ships against the default',
      () {
        final s = prStatus(
          pr: null,
          branch: 'feat/child',
          targetResolved: true,
        );
        expect(s.cta.label, 'Ship it');
      },
    );
  });
}
