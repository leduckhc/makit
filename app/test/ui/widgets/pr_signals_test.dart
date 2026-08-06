// The derivation behind the composer's next-step bar (direction B1): a
// worktree's facts, ordered loudest-first, and the one CTA that clears the
// loudest. Pure Dart — no widgets — so the *rules* are pinned here and the
// widget tests only have to prove the rules are rendered.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/widgets/pr_actions.dart';
import 'package:makit/ui/widgets/pr_signals.dart';

PullRequest _pr({
  int number = 142,
  String state = 'OPEN',
  bool isDraft = false,
  String rollup = 'pass',
  int unresolved = 0,
  bool unresolvedUnknown = false,
  String? mergeable,
  String? mergeStateStatus,
  List<PrCheck> checks = const [],
  bool stale = false,
}) => PullRequest(
  number: number,
  url: 'https://github.com/o/r/pull/$number',
  state: state,
  title: 'A title',
  isDraft: isDraft,
  mergeable: mergeable,
  mergeStateStatus: mergeStateStatus,
  checkRollup: rollup,
  unresolvedComments: unresolved,
  unresolvedUnknown: unresolvedUnknown,
  checks: checks,
  stale: stale,
);

PrStatus _status({
  PullRequest? pr,
  String? branch = 'feat/x',
  int uncommitted = 0,
  int ahead = 0,
  int behind = 0,
}) => prStatus(
  pr: pr,
  branch: branch,
  uncommittedFiles: uncommitted,
  commitsAhead: ahead,
  commitsBehind: behind,
);

/// The prompt a CTA/signal would insert, or null when it is not an agent remedy.
PrPromptAction? _prompt(PrRemedy? r) => r is PromptRemedy ? r.action : null;

/// The direct operation a CTA/signal would run, or null when it is not one.
PrDirectOp? _op(PrRemedy? r) => r is DirectRemedy ? r.op : null;

void main() {
  group('identity', () {
    test('an open PR identifies by its number', () {
      expect(_status(pr: _pr()).identity, '#142');
    });

    test('with no PR it identifies by the branch', () {
      expect(_status(pr: null).identity, 'feat/x');
    });

    test('a detached worktree falls back to a readable label', () {
      expect(_status(pr: null, branch: null).identity, 'detached');
    });
  });

  // Precedence is a property of the *loud fact*: which one leads the sentence,
  // and therefore which remedy the bar names when there is only one problem. With
  // two or more, the button generalises to the magic Fix (see below) — so these
  // assert the loud fact's own remedy, which stays meaningful either way.
  group('hasPr is data, not a parsed display string', () {
    test('a branch literally named #42 is still a branch', () {
      // `hasPr` used to be `identity.startsWith('#')`. `#42` is a legal git branch
      // name, so such a branch was classified as a pull request — which hid
      // "Create PR" from the one branch that most needed it.
      final s = _status(pr: null, branch: '#42');
      expect(s.hasPr, isFalse);
      expect(_prompt(s.cta.remedy), PrPromptAction.createPr);
    });

    test('an open PR has one', () {
      expect(_status(pr: _pr()).hasPr, isTrue);
    });

    test('a PR whose state is not one it knows is still a PR', () {
      // The live-state derivation only recognises OPEN, so anything else falls
      // through with no facts to report. "Create PR" was keyed off *that*
      // absence rather than off the PR, so the button offered to open a second
      // pull request for a branch that already had one — while the menu, which
      // reads `hasPr`, hid the same entry as meaningless.
      final s = _status(pr: _pr(state: 'LOCKED'));
      expect(s.hasPr, isTrue);
      expect(_prompt(s.cta.remedy), isNot(PrPromptAction.createPr));
    });

    test('isEnded follows the state, not the labels', () {
      expect(_status(pr: _pr(state: 'MERGED')).isEnded, isTrue);
      expect(_status(pr: _pr(state: 'CLOSED')).isEnded, isTrue);
      expect(_status(pr: _pr()).isEnded, isFalse);
      expect(_status(pr: null).isEnded, isFalse);
    });
  });

  group('precedence — which fact leads', () {
    // These five preserve the exact order the shipped `_situationFor` used, so
    // the rewrite cannot silently reshuffle what the button offers.
    test('uncommitted work outranks everything local and remote', () {
      final s = _status(
        pr: _pr(rollup: 'fail', unresolved: 3),
        uncommitted: 3,
        ahead: 1,
        behind: 2,
      );
      expect(s.loud.label, '3 files uncommitted');
      expect(_prompt(s.loud.remedy), PrPromptAction.commitAndPush);
    });

    test('behind the remote outranks unpushed commits', () {
      // A push would be rejected while behind, so pulling comes first.
      final s = _status(pr: _pr(), ahead: 1, behind: 2);
      expect(s.loud.label, '2 commits behind');
      expect(_prompt(s.loud.remedy), PrPromptAction.pull);
    });

    test('unpushed commits outrank a red build', () {
      final s = _status(pr: _pr(rollup: 'fail'), ahead: 1);
      expect(s.loud.label, '1 commit unpushed');
      expect(_prompt(s.loud.remedy), PrPromptAction.push);
    });

    test('a red build outranks unresolved threads', () {
      final s = _status(
        pr: _pr(
          rollup: 'fail',
          unresolved: 3,
          checks: const [
            PrCheck(name: 'analyze', bucket: 'fail'),
            PrCheck(name: 'test', bucket: 'fail'),
          ],
        ),
      );
      expect(s.loud.label, '2 checks failing');
      expect(_prompt(s.loud.remedy), PrPromptAction.fixPr);
    });

    test('unresolved threads are the last open-PR remedy', () {
      final s = _status(pr: _pr(unresolved: 3));
      expect(s.loud.label, '3 threads open');
      expect(_prompt(s.loud.remedy), PrPromptAction.resolveComments);
    });
  });

  group('the failing-check count comes from the checks, not the rollup', () {
    test('counts fail and cancel buckets', () {
      final s = _status(
        pr: _pr(
          rollup: 'fail',
          checks: const [
            PrCheck(name: 'analyze', bucket: 'fail'),
            PrCheck(name: 'test', bucket: 'cancel'),
            PrCheck(name: 'build', bucket: 'pass'),
          ],
        ),
      );
      expect(s.loud.label, '2 checks failing');
    });

    test('falls back to a countless phrase when checks were not reported', () {
      // The rollup can say `fail` with an empty check list (a shed lookup).
      // "0 checks failing" would be a lie, so it must not be said.
      final s = _status(pr: _pr(rollup: 'fail'));
      expect(s.loud.label, 'CI failing');
    });
  });

  group('conflicts', () {
    test('a conflicting PR blocks ahead of a red build', () {
      final s = _status(
        pr: _pr(mergeable: 'CONFLICTING', rollup: 'fail'),
      );
      expect(s.loud.label, 'conflicts with the base');
      expect(_prompt(s.loud.remedy), PrPromptAction.pull);
      // Two fixable facts, so the button offers to take on both.
      expect(s.cta.remedy, isA<MagicRemedy>());
    });

    test('conflicts on a merged PR are history, not a next step', () {
      final s = _status(
        pr: _pr(state: 'MERGED', mergeable: 'CONFLICTING'),
      );
      expect(_op(s.cta.remedy), PrDirectOp.wrapUp);
    });
  });

  group('draft', () {
    test('offers to mark it ready when nothing else is outstanding', () {
      final s = _status(pr: _pr(isDraft: true, rollup: 'pass'));
      expect(s.loud.label, 'still a draft');
      expect(_op(s.cta.remedy), PrDirectOp.markReady);
    });

    test('real work outranks coming out of draft', () {
      // Marking a half-finished PR ready is not the next step while there is
      // still uncommitted work on it.
      final s = _status(pr: _pr(isDraft: true, rollup: 'pass'), uncommitted: 2);
      expect(_prompt(s.cta.remedy), PrPromptAction.commitAndPush);
    });

    test('the button is not tinted inert just because the fact is quiet', () {
      // "still a draft" is quiet — it is not urgent. But the button that clears
      // it must not read as disabled, so the CTA promotes the tint.
      final s = _status(pr: _pr(isDraft: true, rollup: 'pass'));
      expect(s.loud.tone, PrTone.quiet, reason: 'the fact stays quiet');
      expect(s.cta.tone, PrTone.attention, reason: 'the button does not');
    });

    test('a merged PR is never offered "mark ready"', () {
      final s = _status(pr: _pr(state: 'MERGED', isDraft: true));
      expect(_op(s.cta.remedy), PrDirectOp.wrapUp);
    });
  });

  group('the base branch moving on', () {
    test('BEHIND offers to update the branch on GitHub', () {
      final s = _status(pr: _pr(mergeStateStatus: 'BEHIND'));
      expect(s.loud.label, 'the base branch moved on');
      expect(_op(s.cta.remedy), PrDirectOp.updateBranch);
    });

    test('a red build outranks a moved base', () {
      // Updating the branch reruns CI anyway, so fixing the build comes first.
      final s = _status(
        pr: _pr(
          mergeStateStatus: 'BEHIND',
          rollup: 'fail',
          checks: const [PrCheck(name: 'a', bucket: 'fail')],
        ),
      );
      expect(_prompt(s.cta.remedy), PrPromptAction.fixPr);
    });

    test('a moved base outranks unresolved threads', () {
      final s = _status(pr: _pr(mergeStateStatus: 'BEHIND', unresolved: 2));
      expect(_op(s.cta.remedy), PrDirectOp.updateBranch);
    });

    test('any other mergeStateStatus says nothing about the base', () {
      for (final st in ['CLEAN', 'BLOCKED', 'DIRTY', 'UNKNOWN']) {
        final s = _status(pr: _pr(mergeStateStatus: st));
        expect(
          s.signals.where((x) => x.label.contains('base branch')),
          isEmpty,
          reason: st,
        );
      }
    });

    test('a merged PR does not offer to update its branch', () {
      final s = _status(
        pr: _pr(state: 'MERGED', mergeStateStatus: 'BEHIND'),
      );
      expect(_op(s.cta.remedy), PrDirectOp.wrapUp);
    });
  });

  group('ready to merge', () {
    test('a green, mergeable, clean PR offers to squash & merge', () {
      // This state used to be a dead end: the CTA rested at "Ask the agent" on
      // exactly the PR that was ready to land.
      final s = _status(
        pr: _pr(rollup: 'pass', mergeable: 'MERGEABLE'),
      );
      expect(s.loud.label, 'ready to merge');
      expect(_op(s.cta.remedy), PrDirectOp.squashMerge);
      expect(s.cta.label, 'Squash & merge');
    });

    test('BLOCKED means GitHub would refuse, so it is not offered', () {
      // Required reviews or required checks are missing; GitHub greys its own
      // button here, and offering ours would just produce an error.
      final s = _status(
        pr: _pr(
          rollup: 'pass',
          mergeable: 'MERGEABLE',
          mergeStateStatus: 'BLOCKED',
        ),
      );
      expect(s.cta.remedy, isNull);
    });

    test('an unknown mergeability is not treated as mergeable', () {
      // `mergeable` is null on an older server and UNKNOWN while GitHub is still
      // computing. Guessing "yes" would offer a merge that fails.
      for (final m in [null, 'UNKNOWN', 'CONFLICTING']) {
        final s = _status(
          pr: _pr(rollup: 'pass', mergeable: m),
        );
        expect(_op(s.cta.remedy), isNot(PrDirectOp.squashMerge), reason: '$m');
      }
    });

    test('a draft is never offered a merge', () {
      final s = _status(
        pr: _pr(rollup: 'pass', mergeable: 'MERGEABLE', isDraft: true),
      );
      expect(_op(s.cta.remedy), PrDirectOp.markReady);
    });

    test('anything outstanding outranks merging', () {
      for (final s in [
        _status(
          pr: _pr(rollup: 'pass', mergeable: 'MERGEABLE'),
          uncommitted: 1,
        ),
        _status(
          pr: _pr(rollup: 'pass', mergeable: 'MERGEABLE'),
          ahead: 1,
        ),
        _status(
          pr: _pr(rollup: 'fail', mergeable: 'MERGEABLE'),
        ),
        _status(
          pr: _pr(
            rollup: 'pending',
            mergeable: 'MERGEABLE',
            checks: const [PrCheck(name: 'a', bucket: 'pending')],
          ),
        ),
        _status(
          pr: _pr(rollup: 'pass', mergeable: 'MERGEABLE', unresolved: 1),
        ),
      ]) {
        expect(_op(s.cta.remedy), isNot(PrDirectOp.squashMerge));
      }
    });

    test('merging is confirmed — it is not undoable in one click', () {
      expect(needsConfirm(PrDirectOp.squashMerge), isTrue);
    });
  });

  group('the magic Fix', () {
    test('never appears on a signal, only on the CTA', () {
      // It is composed *from* the signals, so a signal carrying it would be
      // circular. The type cannot express that without a second hierarchy, so
      // the invariant is checked here instead.
      final states = <PrStatus>[
        _status(pr: null),
        _status(pr: null, uncommitted: 3),
        _status(pr: _pr(rollup: 'pass')),
        _status(
          pr: _pr(rollup: 'pass', mergeable: 'MERGEABLE'),
        ),
        _status(pr: _pr(isDraft: true, rollup: 'fail')),
        _status(pr: _pr(mergeStateStatus: 'BEHIND')),
        _status(pr: _pr(mergeable: 'CONFLICTING')),
        _status(pr: _pr(state: 'MERGED'), uncommitted: 2),
        _status(pr: _pr(state: 'CLOSED')),
        _status(
          pr: _pr(
            rollup: 'fail',
            unresolved: 3,
            checks: const [PrCheck(name: 'a', bucket: 'fail')],
          ),
          uncommitted: 2,
          ahead: 1,
          behind: 1,
        ),
      ];
      for (final s in states) {
        expect(
          s.signals.where((x) => x.remedy is MagicRemedy),
          isEmpty,
          reason: s.loud.label,
        );
      }
      // …and at least one of those states really does put it on the CTA, so this
      // test cannot pass by never reaching the magic path at all.
      expect(states.any((s) => s.cta.remedy is MagicRemedy), isTrue);
    });

    test('two or more outstanding facts collapse into one Fix', () {
      // With several problems, "fix everything" genuinely *is* the single next
      // step — the individual remedies stay in the detail and the menu.
      final s = _status(
        pr: _pr(
          rollup: 'fail',
          unresolved: 3,
          checks: const [PrCheck(name: 'a', bucket: 'fail')],
        ),
        ahead: 1,
      );
      expect(s.cta.remedy, isA<MagicRemedy>());
      expect(s.cta.label, 'Fix');
    });

    test('a single problem keeps its own specific verb', () {
      // A magic button for one thing is just that thing with a vaguer label.
      final s = _status(pr: _pr(rollup: 'pass'), ahead: 1);
      expect(_prompt(s.cta.remedy), PrPromptAction.push);
    });

    test('facts you cannot act on do not count toward it', () {
      // "4 of 12 checks still running" is not a problem to fix.
      final s = _status(
        pr: _pr(
          rollup: 'pending',
          checks: const [
            PrCheck(name: 'a', bucket: 'pending'),
            PrCheck(name: 'b', bucket: 'pass'),
          ],
        ),
        ahead: 1,
      );
      expect(_prompt(s.cta.remedy), PrPromptAction.push);
    });

    test('the loud fact still leads the sentence', () {
      // The bar must keep saying *what* is wrong; only the button generalises.
      final s = _status(
        pr: _pr(
          rollup: 'fail',
          unresolved: 2,
          checks: const [PrCheck(name: 'a', bucket: 'fail')],
        ),
        uncommitted: 2,
      );
      expect(s.loud.label, '2 files uncommitted');
      expect(s.cta.remedy, isA<MagicRemedy>());
    });

    test('is not offered when a direct op is also outstanding', () {
      // The button says "Fix", and the prompt only carries prompt-backed facts —
      // so offering it while `the base branch moved on` (a direct op) is pending
      // would promise to fix everything and silently skip that one.
      final s = _status(
        pr: _pr(
          mergeStateStatus: 'BEHIND',
          rollup: 'fail',
          unresolved: 2,
          checks: const [PrCheck(name: 'a', bucket: 'fail')],
        ),
      );
      expect(s.cta.remedy, isNot(isA<MagicRemedy>()));
      expect(_prompt(s.cta.remedy), PrPromptAction.fixPr);
    });

    // No test for "a magic CTA with a quiet tone": it is unreachable. Only a
    // draft mutes its own facts, and a draft always contributes `still a draft`
    // (a direct op), which the rule above excludes from magic. Both CTA paths now
    // share one promoted-tone expression, so the draft case in
    // `group('draft')` covers the promotion itself.
    test('a merged PR gets no magic Fix — its problems are history', () {
      final s = _status(
        pr: _pr(state: 'MERGED', rollup: 'fail', unresolved: 2),
        uncommitted: 1,
      );
      expect(_op(s.cta.remedy), PrDirectOp.wrapUp);
    });

    test('it needs no confirm — it only writes to the composer', () {
      expect(prRemedyLabel(const MagicRemedy()), 'Fix');
      // The name's actual claim: a magic remedy never reaches `needsConfirm` at
      // all, because only a DirectRemedy carries an op. Asserting the label alone
      // left that invariant unpinned.
      expect(const MagicRemedy(), isNot(isA<DirectRemedy>()));
    });
  });

  group('nothing pressing', () {
    test('a green, synced, thread-free PR leaves the CTA idle', () {
      final s = _status(pr: _pr(rollup: 'pass'));
      expect(s.cta.remedy, isNull, reason: 'idle: menu only, no default verb');
      expect(s.cta.tone, PrTone.quiet);
    });

    test('checks in flight are reported but are not a remedy', () {
      final s = _status(
        pr: _pr(
          rollup: 'pending',
          checks: const [
            PrCheck(name: 'a', bucket: 'pending'),
            PrCheck(name: 'b', bucket: 'pass'),
          ],
        ),
      );
      expect(s.loud.label, '1 of 2 checks still running');
      expect(s.loud.remedy, isNull);
      expect(s.cta.remedy, isNull);
    });

    test('a draft is quiet even with a red build', () {
      // A draft is not up for review, so its failing build is not the user's
      // next action — the rule the shipped pill applied by going grey.
      final s = _status(pr: _pr(isDraft: true, rollup: 'fail'));
      expect(s.tone, PrTone.quiet);
    });
  });

  group('which direct ops need confirming', () {
    // Drives whether `runPrRemedy` puts a dialog up. Getting this wrong in
    // either direction is bad: an unconfirmed wrap up destroys uncommitted work
    // silently, and a confirmed mark-ready trains users to dismiss dialogs
    // unread — which is what would make the wrap-up dialog useless.
    test('the irreversible ones do', () {
      // Exhaustive on purpose: a new PrDirectOp must be classified here, not
      // left to inherit whichever branch the switch happens to fall into.
      expect(needsConfirm(PrDirectOp.wrapUp), isTrue);
      expect(needsConfirm(PrDirectOp.discardWorktree), isTrue);
      expect(needsConfirm(PrDirectOp.squashMerge), isTrue);
    });

    test('the two reversible GitHub changes do not', () {
      // `gh pr ready` is reversible; `gh pr update-branch` only adds a commit.
      // Neither touches the working tree.
      expect(needsConfirm(PrDirectOp.markReady), isFalse);
      expect(needsConfirm(PrDirectOp.updateBranch), isFalse);
    });

    // The two tests above name each op individually, which is what makes them
    // readable — and what lets a *new* op slip past both. Both classifiers are
    // exhaustive switches, so a new op cannot go unclassified; it will simply
    // inherit whichever arm the author extended, silently.
    //
    // The length assertion is the tripwire. It is the only thing here that fails
    // when an op is added, and it fails until someone comes to this group and
    // states, for both classifiers, which side the new op belongs on.
    test('adding an op forces a decision here', () {
      expect(
        PrDirectOp.values,
        hasLength(5),
        reason:
            'a new PrDirectOp needs a needsConfirm and a deletesBranch verdict '
            'below, then this count updated',
      );
      expect(PrDirectOp.values.where(needsConfirm).toSet(), {
        PrDirectOp.wrapUp,
        PrDirectOp.discardWorktree,
        PrDirectOp.squashMerge,
      });
      // `runPrRemedy` refuses these two when it cannot name the branch, so a new
      // branch-deleting op missing here would dispatch unguarded.
      expect(PrDirectOp.values.where(deletesBranch).toSet(), {
        PrDirectOp.wrapUp,
        PrDirectOp.discardWorktree,
      });
    });
  });

  group('the primary checkout', () {
    test('is not told to open a PR for itself', () {
      // You do not raise a pull request for `main`. The old bar offered exactly
      // that, because "no PR" was the only condition it looked at.
      final s = prStatus(pr: null, branch: 'main', isPrimary: true);
      expect(s.loud.label, 'clean');
      expect(s.cta.remedy, isNull);
    });

    test('still reports uncommitted work on it', () {
      final s = prStatus(
        pr: null,
        branch: 'main',
        isPrimary: true,
        uncommittedFiles: 2,
      );
      expect(s.loud.label, '2 files uncommitted');
      expect(_prompt(s.cta.remedy), PrPromptAction.commitAndPush);
    });

    test('has nothing to say when it is clean', () {
      // Drives whether the home row shows a chip at all: a quiet primary
      // checkout should add no chrome to the list.
      expect(
        prStatus(pr: null, branch: 'main', isPrimary: true).isQuiet,
        isTrue,
      );
    });
  });

  group('quietness drives whether the row shows anything', () {
    test('a branch with something to do is not quiet', () {
      expect(_status(pr: null, uncommitted: 1).isQuiet, isFalse);
    });

    test('a branch with a PR is never quiet, even a green one', () {
      // The PR number itself is worth a chip: it is how you reach the sheet.
      expect(_status(pr: _pr(rollup: 'pass')).isQuiet, isFalse);
    });

    test('a clean branch with no PR is quiet, despite offering Create PR', () {
      // The offer is a CTA, not a fact. A chip on every clean branch was pure
      // noise on the repo card — and made it tall enough to push its own
      // "Show less" control off screen.
      final s = _status(pr: null);
      expect(_prompt(s.cta.remedy), PrPromptAction.createPr);
      expect(s.isQuiet, isTrue);
    });
  });

  group('no PR yet', () {
    test('clean and committed → offer to create the PR', () {
      final s = _status(pr: null);
      expect(s.loud.label, 'ready for a PR');
      expect(_prompt(s.cta.remedy), PrPromptAction.createPr);
    });

    test('uncommitted work comes before creating the PR', () {
      final s = _status(pr: null, uncommitted: 3);
      expect(_prompt(s.cta.remedy), PrPromptAction.commitAndPush);
    });
  });

  group('endings', () {
    test('a merged PR offers to wrap up, not to fix its history', () {
      final s = _status(
        pr: _pr(state: 'MERGED', rollup: 'fail', unresolved: 4),
        uncommitted: 2,
      );
      expect(s.tone, PrTone.landed);
      expect(_op(s.cta.remedy), PrDirectOp.wrapUp);
      expect(s.cta.label, 'Wrap up');
    });

    test('a closed PR offers to discard the worktree', () {
      final s = _status(pr: _pr(state: 'CLOSED'));
      expect(_op(s.cta.remedy), PrDirectOp.discardWorktree);
    });

    test('a merged PR reports what is still lying around', () {
      final s = _status(pr: _pr(state: 'MERGED'), uncommitted: 2);
      expect(
        s.signals.map((x) => x.label),
        containsAll(<String>['merged', '2 files uncommitted']),
      );
    });

    test('the primary checkout is never offered a discard either', () {
      final s = prStatus(
        pr: _pr(state: 'CLOSED'),
        branch: 'main',
        isPrimary: true,
      );
      // The whole remedy, not just its op: `_op` reads null for a prompt too, so
      // asserting on it would have passed on a bar that offered one.
      expect(s.cta.remedy, isNull);
    });

    test('the primary checkout is never offered a wrap up', () {
      // Wrapping up removes the worktree; doing that to the repo's own checkout
      // would take the repo with it (mirrors `canDeleteWorktree`).
      final s = prStatus(
        pr: _pr(state: 'MERGED'),
        branch: 'main',
        isPrimary: true,
      );
      expect(s.cta.remedy, isNull);
    });
  });

  group('the disclosure count', () {
    test('counts every fact except the loud one', () {
      final s = _status(
        pr: _pr(rollup: 'fail', unresolved: 3),
        uncommitted: 2,
        ahead: 1,
      );
      expect(s.loud.label, '2 files uncommitted');
      expect(s.more, s.signals.length - 1);
      expect(s.more, greaterThan(0));
    });

    test('is zero when there is only one fact', () {
      expect(_status(pr: _pr(rollup: 'pass')).more, 0);
    });
  });

  group('unresolvedUnknown', () {
    test('a shed thread count is not reported as a fact', () {
      // The server sheds the count to save quota; showing "0 threads open" or
      // acting on it would both be lies.
      // A non-zero count *with* the flag set: the number arrived but is not
      // trustworthy. With `unresolved: 0` this test passed even without the
      // guard, so it proved nothing.
      final s = _status(
        pr: _pr(unresolved: 3, unresolvedUnknown: true, rollup: 'pass'),
      );
      expect(s.signals.where((x) => x.label.contains('thread')), isEmpty);
      expect(_prompt(s.cta.remedy), isNot(PrPromptAction.resolveComments));
    });
  });

  group('check progress', () {
    test('a pending rollup reports the reported fraction', () {
      final s = _status(
        pr: _pr(
          rollup: 'pending',
          checks: const [
            PrCheck(name: 'a', bucket: 'pass'),
            PrCheck(name: 'b', bucket: 'pending'),
            PrCheck(name: 'c', bucket: 'pending'),
          ],
        ),
      );
      expect(s.checkProgress, closeTo(1 / 3, 0.001));
    });

    test('is null when nothing is in flight', () {
      expect(_status(pr: _pr(rollup: 'pass')).checkProgress, isNull);
    });
  });

  group('stale', () {
    test('staleness rides along without changing the facts', () {
      final s = _status(pr: _pr(rollup: 'fail', stale: true));
      expect(s.stale, isTrue);
      expect(s.identity, '#142');
      expect(_prompt(s.cta.remedy), PrPromptAction.fixPr);
    });
  });

  // The mockup's §2 legend, row by row. The dot reports the **pull request**,
  // which is not the same thing as the loud fact: a PR can have a green build
  // and an unpushed commit, and those want different colours. Before this the dot
  // simply painted `tone`, so a green PR's dot was grey (the all-clear fact is
  // quiet) and a red build's dot went amber the moment a local commit outranked
  // it.
  group('the dot (mockup §2)', () {
    test('no PR yet, nothing to report — a ring', () {
      expect(_status().dot, PrDot.none);
      expect(_status(branch: 'main').dot, PrDot.none);
    });

    test('no PR but something to report — not a ring: the fact has a hue', () {
      // The legend's row is "hollow ring — *nothing to report*", and the mockup's
      // own `dirty` picture (no PR, 3 uncommitted files) draws a solid amber
      // disc. A ring here would report "nothing" over three uncommitted files.
      expect(_status(uncommitted: 3).dot, PrDot.tone);
      expect(_status(ahead: 1).dot, PrDot.tone);
    });

    test('checks green — solid pass', () {
      expect(_status(pr: _pr(rollup: 'pass')).dot, PrDot.pass);
    });

    test('checks green stays green under a louder local fact', () {
      // `oneProblem` in the mockup: `#142 · 1 commit unpushed` in amber, with a
      // green dot. The sentence carries the problem; the dot carries the build.
      final s = _status(pr: _pr(rollup: 'pass'), ahead: 1);
      expect(s.loud.label, '1 commit unpushed');
      expect(s.tone, PrTone.attention);
      expect(s.dot, PrDot.pass);
    });

    test('checks red — solid fail, even when an amber fact is louder', () {
      // The mockup's `hot` picture draws this amber, but that is a leftover: §8
      // records that its loud fact was changed from `2 checks failing` to
      // `1 commit unpushed` and the dot was not revisited. The legend is the
      // rule, and §8 of the spec says the dot's hue is the *verdict*.
      final s = _status(pr: _pr(rollup: 'fail'), ahead: 1);
      expect(s.loud.label, '1 commit unpushed');
      expect(s.dot, PrDot.fail);
    });

    test('checks in flight — an arc, not a hue', () {
      final s = _status(
        pr: _pr(
          rollup: 'pending',
          checks: const [
            PrCheck(name: 'a', bucket: 'pass'),
            PrCheck(name: 'b', bucket: 'pending'),
          ],
        ),
      );
      expect(s.dot, PrDot.pending);
      expect(s.checkProgress, closeTo(0.5, 0.001));
    });

    test('merged — the only purple in the pane', () {
      expect(_status(pr: _pr(state: 'MERGED')).dot, PrDot.landed);
    });

    test('draft — muted, not up for review', () {
      expect(_status(pr: _pr(isDraft: true)).dot, PrDot.muted);
    });

    test('a draft mutes its own build too', () {
      // §5: a draft is not up for review, so nothing about it is loud — which
      // has to include its dot, or the one graphic shouts what the sentence
      // deliberately does not.
      expect(_status(pr: _pr(isDraft: true, rollup: 'fail')).dot, PrDot.muted);
    });

    test('closed without merging — muted', () {
      expect(_status(pr: _pr(state: 'CLOSED')).dot, PrDot.muted);
    });

    test('an open PR with no verdict falls back to the loud fact', () {
      // Nothing to report about the build, so the dot has nothing of its own to
      // say and defers — the mockup's `conflict`/`behind`/`threads` pictures.
      final s = _status(pr: _pr(rollup: 'unknown'), behind: 2);
      expect(s.dot, PrDot.tone);
      expect(s.tone, PrTone.attention);
    });
  });

  group('isPrimary is carried, not re-derived', () {
    test('the primary checkout says so', () {
      // The menu explains *why* an action is unavailable (D3), and the reason for
      // "Create PR" differs by case: a secondary branch has no commits yet, while
      // the primary checkout is simply not something you raise a PR from. Without
      // this field the menu gave the first reason for both, which is false.
      expect(
        prStatus(pr: null, branch: 'main', isPrimary: true).isPrimary,
        isTrue,
      );
      expect(prStatus(pr: null, branch: 'feat/x').isPrimary, isFalse);
    });
  });

  // A surface can know the branch before the repos snapshot does — the worktree
  // starter is the obvious case, since it renders the bar for a worktree it just
  // asked the server to create.
  group('prStatusFor before the snapshot catches up', () {
    test('a missing entry falls back to the branch the caller knows', () {
      expect(prStatusFor(null, fallbackBranch: 'feat/x').identity, 'feat/x');
    });

    test('with no fallback either, it admits it does not know', () {
      expect(prStatusFor(null).identity, 'detached');
    });
  });
}
