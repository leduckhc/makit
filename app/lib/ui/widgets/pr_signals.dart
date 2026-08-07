/// The derivation behind the composer's next-step bar and its mobile
/// counterparts: turn a worktree's raw facts into an ordered list of **signals**
/// and the single **call to action** that clears the loudest one.
///
/// One function, three surfaces. The desktop bar, the mobile worktree row and
/// the PR sheet all read from [prStatus], which is what stops them drifting —
/// they did drift before (see `prPillColors`'s docstring: an open failing PR
/// read red in a session and brand-green on the home list).
///
/// The bar itself (direction B1) shows the **loud** signal plus a `+n more`
/// disclosure; the popover/sheet shows all of [PrStatus.signals]. So this file
/// owns *what is true and what to do about it*, and the widgets own *how much
/// of it is on screen*.
library;

import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../store/models.dart';
import 'icon_glyph.dart';
import 'pr_actions.dart';

/// How loud a fact is. Drives tint everywhere, and nothing else.
enum PrTone {
  /// Cannot land until fixed — conflicts, a red build.
  blocking,

  /// Waiting on the user — uncommitted work, unpushed commits, open threads.
  attention,

  /// True but not actionable — checks in flight, a draft, all-clear.
  quiet,

  /// Terminal good news — merged.
  landed,
}

/// What the status dot reports, which is the **pull request's own state** — not
/// the loud fact.
///
/// The two are not the same claim and the mockup's §2 legend gives the dot to the
/// PR: `#142 · 1 commit unpushed` reads amber in the sentence (that is the next
/// step) over a *green* dot (the build is fine). Painting the dot from [PrTone]
/// instead collapsed both into one hue, which made a green PR's dot grey — the
/// all-clear fact is [PrTone.quiet] — and turned a red build amber the moment a
/// local commit outranked it in §5.
enum PrDot {
  /// No pull request **and nothing outstanding**: a hollow ring in the outline
  /// grey, "nothing to report". Tone-independent by design — see [PrDot.tone] for
  /// why a branch with local work is not this.
  none,

  /// Checks green.
  pass,

  /// Checks red.
  fail,

  /// Checks in flight: an arc, [PrStatus.checkProgress] of the way round.
  pending,

  /// Merged — the only purple in the pane.
  landed,

  /// A draft, or closed without merging: muted, not up for review. A draft mutes
  /// its own build here too, or the one graphic would shout what §5 deliberately
  /// keeps quiet.
  muted,

  /// The pull request has no verdict of its own, so the dot defers to
  /// [PrStatus.tone]: a branch with no PR but uncommitted or unpushed work, or an
  /// open PR whose rollup says nothing (conflicts, a moved base, open threads).
  tone,
}

/// The deterministic operations the bar runs itself, rather than asking the agent
/// to. Each is a single unambiguous call — anything needing judgement stays a
/// prompt.
///
/// [wrapUp], [discardWorktree] and [squashMerge] cannot be taken back in one
/// click and so are confirmed; [markReady] and [updateBranch] only change state
/// on GitHub, are reversible or additive, and run straight from the button (see
/// [needsConfirm]).
enum PrDirectOp {
  /// Merged: remove the worktree, reconcile the sessions bound to it, delete the
  /// branch, then fast-forward the PR's base branch in the primary checkout.
  wrapUp,

  /// Closed without merging: remove the worktree and its branch. No base
  /// branch to catch up, because nothing landed.
  discardWorktree,

  /// Take the PR out of draft (`gh pr ready`). Reversible.
  markReady,

  /// Merge the base branch into the PR head on GitHub (`gh pr update-branch`) —
  /// the remedy for `mergeStateStatus: BEHIND`.
  updateBranch,

  /// Land the PR with GitHub's squash strategy (`gh pr merge --squash`).
  /// Deliberately does not delete the branch: the merged state then offers
  /// [wrapUp], which stops the worktree's sessions first.
  squashMerge,
}

/// Whether [op] must be confirmed before it runs.
///
/// Not the same as "destructive": squash-merging destroys nothing locally, but it
/// publishes to a shared branch and cannot be taken back with one click, so it
/// asks. The two reversible GitHub changes ([markReady] undoes with
/// `gh pr ready --undo`, [updateBranch] only adds a commit) do not — a dialog on
/// those would train the user to dismiss dialogs unread, which is exactly what
/// would make the wrap-up and merge dialogs worthless.
bool needsConfirm(PrDirectOp op) => switch (op) {
  PrDirectOp.wrapUp ||
  PrDirectOp.discardWorktree ||
  PrDirectOp.squashMerge => true,
  PrDirectOp.markReady || PrDirectOp.updateBranch => false,
};

/// Whether [op] ends in `git branch -D`.
///
/// The caller must know *which* branch before dispatching one of these: the
/// server resolves the branch again when it runs, and the `expectBranch` guard
/// that keeps the two answers honest can only be sent if the app has one.
bool deletesBranch(PrDirectOp op) => switch (op) {
  PrDirectOp.wrapUp || PrDirectOp.discardWorktree => true,
  PrDirectOp.squashMerge ||
  PrDirectOp.markReady ||
  PrDirectOp.updateBranch => false,
};

/// How a signal or CTA is resolved.
sealed class PrRemedy {
  const PrRemedy();
}

/// Insert a canned prompt in the composer. Never sends — the user reviews it.
final class PromptRemedy extends PrRemedy {
  const PromptRemedy(this.action);

  final PrPromptAction action;
}

/// Run a server command now (with a confirm when [needsConfirm]).
final class DirectRemedy extends PrRemedy {
  const DirectRemedy(this.op);

  final PrDirectOp op;
}

/// Hand the agent *every* outstanding problem at once, as one composed prompt.
///
/// Offered only when there are two or more facts with a remedy: with one, it
/// would be that fact's own remedy under a vaguer label. The prompt is built at
/// run time from the current signals (see `magicFixPrompt`), which is why this
/// carries no action — the facts are the argument.
final class MagicRemedy extends PrRemedy {
  const MagicRemedy();
}

/// One fact about the worktree, and the remedy that clears it.
class PrSignal {
  const PrSignal(this.label, this.tone, {this.remedy, this.detail});

  /// Sentence fragment, e.g. `2 checks failing`. Reads as the continuation of
  /// `<identity> · …`, so it is lower case and carries its own count.
  final String label;

  final PrTone tone;

  /// What clears it, or null for a fact you cannot act on (checks in flight).
  ///
  /// Only ever a [PromptRemedy] or a [DirectRemedy]. [MagicRemedy] is composed
  /// *from* the signals and so belongs to [PrCta] alone — a signal that claimed
  /// to be fixed by "fix everything" would be circular. Enforced by test rather
  /// than by the type, which would need a second hierarchy to say so.
  final PrRemedy? remedy;

  /// Optional second line for the popover/sheet, e.g. the failing check names.
  final String? detail;
}

/// The bar's single call to action. A [remedy] of null is the **idle** CTA:
/// nothing is pressing, so the button offers the menu instead of pretending one
/// of six prompts is the obvious next step.
class PrCta {
  const PrCta(this.label, this.tone, {this.remedy});

  final String label;
  final PrTone tone;
  final PrRemedy? remedy;

  /// True when there is no specific next step to name.
  bool get isIdle => remedy == null;
}

/// Everything the bar, the row and the sheet need.
class PrStatus {
  const PrStatus({
    required this.identity,
    required this.tone,
    required this.signals,
    required this.cta,
    this.dot = PrDot.tone,
    this.checkProgress,
    this.stale = false,
    this.hasPr = false,
    this.isEnded = false,
    this.isPrimary = false,
  });

  /// `#142` for a PR, else the branch name (or `detached`).
  final String identity;

  /// The tone of the loud signal — the sentence's hue, and the dot's when [dot]
  /// is [PrDot.tone].
  final PrTone tone;

  /// What the status dot reports (mockup §2). Derived here rather than at each
  /// surface: the three of them used to re-derive `hollow: pr == null` for
  /// themselves, which is exactly the duplication §4 exists to prevent.
  final PrDot dot;

  /// Facts, loudest first. Never empty.
  final List<PrSignal> signals;

  final PrCta cta;

  /// Fraction of checks that have reported, or null when none are in flight.
  /// Drawn as an arc on the dot: a rollup is a *count*, so a determinate arc is
  /// honest where an indeterminate spinner is not.
  final double? checkProgress;

  /// Last-known data (a refresh could not complete against GitHub's quota).
  final bool stale;

  /// Whether a pull request exists. Set from `pr != null`, never inferred from
  /// [identity]: `#42` is a legal branch name, and reading the display string
  /// would classify such a branch as a PR and hide "Create PR" from it.
  final bool hasPr;

  /// True once the pull request has ended (merged or closed), so its build result
  /// and review threads are history rather than next steps. Set by the derivation
  /// — the menu used to detect this by comparing signal labels, which would have
  /// broken silently the moment a label was reworded.
  final bool isEnded;

  /// The repo's own checkout, which cannot be wrapped up or discarded and is not
  /// a branch you raise a pull request from. Carried so the menu can give the
  /// *right* reason for a disabled action (D3) instead of the secondary-branch one.
  final bool isPrimary;

  /// The one signal the bar shows in full.
  PrSignal get loud => signals.first;

  /// How many facts the `+n more` disclosure stands for.
  int get more => signals.length - 1;

  /// Nothing worth a chip on a dense list: no pull request to reach, and nothing
  /// actually outstanding.
  ///
  /// Deliberately ignores the CTA. A clean branch with no PR still *offers*
  /// "Create PR", but that is an invitation, not a fact — putting it on every
  /// branch of every repo card added a meta line to rows that had nothing to
  /// report and pushed the card's own controls off screen. The desktop bar always
  /// renders, so it keeps the offer; the list stays quiet.
  bool get isQuiet => !hasPr && !signals.any((s) => s.remedy != null);
}

/// `N thing` / `N things`.
String _plural(int n, String singular, [String? plural]) =>
    '$n ${n == 1 ? singular : (plural ?? '${singular}s')}';

/// What an *ended* worktree left lying around beyond its own files: sessions
/// still bound to it, and a primary checkout whose branch has moved on since.
///
/// Grouped rather than three loose parameters because they share one lifetime —
/// they are the `left behind` half of the wrap-up brief (mockup §4) and mean
/// nothing while the pull request is still open.
///
/// Both counts already exist in the repos snapshot; nothing new is fetched. The
/// base's count is the **primary checkout's** own `behindCount`, which the server
/// derives as `HEAD..@{upstream}` there — that is precisely "main is N behind".
class PrResidue {
  const PrResidue({this.sessions = 0, this.baseBranch, this.baseBehind = 0});

  /// Sessions bound to the worktree, archived ones excluded by the server. A
  /// wrap-up or discard archives every one of them, which is what the fact names
  /// — *not* "still running": the set includes idle, awaiting and exited
  /// sessions, so claiming they are running would be false for most of them.
  final int sessions;

  /// The branch checked out in the primary checkout, for the fact's wording.
  /// Null when there is no primary worktree in the snapshot, or it is detached.
  final String? baseBranch;

  /// How far that branch trails its upstream.
  final int baseBehind;
}

/// Derive the status of a worktree.
///
/// Takes primitives rather than a `Worktree` because two desktop callers hold
/// the counts without one (the pane and the worktree starter).
///
/// Ordering is deliberate and pinned by tests. A merged/closed PR short-circuits
/// everything — its build and its review threads are history, and the only thing
/// left to do is tidy up. Otherwise, loudest first:
///   1. uncommitted work (you cannot fix anything without committing first),
///   2. behind the remote (a push is rejected while behind),
///   3. unpushed commits,
///   4. conflicts with the base,
///   5. a red build,
///   6. the base branch moved on (`mergeStateStatus: BEHIND`),
///   7. open review threads.
/// Steps 1–3, 5 and 7 keep the exact precedence the shipped `_situationFor`
/// used, so this rewrite cannot silently reshuffle the offered action.
PrStatus prStatus({
  required PullRequest? pr,
  required String? branch,
  int uncommittedFiles = 0,
  int commitsAhead = 0,
  int commitsBehind = 0,
  bool isPrimary = false,
  PrResidue residue = const PrResidue(),
}) {
  final state = pr?.state.toUpperCase();
  final identity = pr != null ? '#${pr.number}' : (branch ?? 'detached');

  // ── endings ───────────────────────────────────────────────────────────────
  // Removing a worktree is only possible for a secondary one; the primary
  // checkout *is* the repo (mirrors `canDeleteWorktree`). So a landed PR on the
  // primary checkout still says it landed, it just has nothing to offer.
  if (state == 'MERGED' || state == 'CLOSED') {
    final merged = state == 'MERGED';
    // Two tones, because the fact and the button make different claims. A closed
    // pull request is *history*, not an alarm — mockup §3 gives it a quiet lead —
    // but the button that cleans up after it deletes a worktree and a branch, so
    // it keeps the blocking red.
    final factTone = merged ? PrTone.landed : PrTone.quiet;
    final ctaTone = merged ? PrTone.landed : PrTone.blocking;
    final op = merged ? PrDirectOp.wrapUp : PrDirectOp.discardWorktree;
    return PrStatus(
      identity: identity,
      tone: factTone,
      dot: merged ? PrDot.landed : PrDot.muted,
      hasPr: true,
      isEnded: true,
      isPrimary: isPrimary,
      stale: pr!.stale,
      signals: [
        PrSignal(merged ? 'merged' : 'closed without merging', factTone),
        // The residue is *not* landed. Only the ending itself earns the purple:
        // painting `2 files uncommitted` in it said the uncommitted work had
        // merged, and the mockup's `left behind` group draws these neutral (§4).
        if (uncommittedFiles > 0)
          PrSignal(
            '${_plural(uncommittedFiles, 'file')} uncommitted',
            PrTone.quiet,
          ),
        if (!isPrimary) const PrSignal('worktree still here', PrTone.quiet),
        // The rest of the residue, in the mockup's `left behind` order. Reported
        // only here: while the PR is open, "a session is running in it" is not a
        // fact about the pull request — it is how you are working on it.
        if (residue.sessions > 0)
          PrSignal(
            '${_plural(residue.sessions, 'session')} to archive',
            PrTone.quiet,
          ),
        if (residue.baseBranch != null && residue.baseBehind > 0)
          PrSignal(
            '${residue.baseBranch} is '
            '${_plural(residue.baseBehind, 'commit')} behind',
            PrTone.quiet,
          ),
      ],
      cta: isPrimary
          // Nothing to tidy: the primary checkout stays. It still reports that
          // the PR landed, it just has no ending to offer.
          ? const PrCta('Ask the agent', PrTone.quiet)
          : PrCta(
              merged ? 'Wrap up' : 'Discard worktree',
              ctaTone,
              remedy: DirectRemedy(op),
            ),
    );
  }

  // ── live states ───────────────────────────────────────────────────────────
  final open = pr != null && state == 'OPEN' ? pr : null;
  // A draft is not up for review, so nothing about it is loud — its red build is
  // not the user's next action. Same rule the shipped pill already applies.
  final draft = open?.isDraft ?? false;

  final signals = <PrSignal>[];

  if (uncommittedFiles > 0) {
    signals.add(
      PrSignal(
        '${_plural(uncommittedFiles, 'file')} uncommitted',
        PrTone.attention,
        remedy: const PromptRemedy(PrPromptAction.commitAndPush),
      ),
    );
  }
  if (commitsBehind > 0) {
    signals.add(
      PrSignal(
        '${_plural(commitsBehind, 'commit')} behind',
        PrTone.attention,
        remedy: const PromptRemedy(PrPromptAction.pull),
      ),
    );
  }
  if (commitsAhead > 0) {
    signals.add(
      PrSignal(
        '${_plural(commitsAhead, 'commit')} unpushed',
        PrTone.attention,
        remedy: const PromptRemedy(PrPromptAction.push),
      ),
    );
  }
  if (open != null && open.mergeable?.toUpperCase() == 'CONFLICTING') {
    signals.add(
      const PrSignal(
        'conflicts with the base',
        PrTone.blocking,
        // Integrating the base is what resolves them, and the built-in "pull"
        // prompt already says "resolving any conflicts".
        remedy: PromptRemedy(PrPromptAction.pull),
      ),
    );
  }
  if (open != null && open.checkRollup == 'fail') {
    final failed = open.checks
        .where((c) => c.bucket == 'fail' || c.bucket == 'cancel')
        .toList();
    signals.add(
      PrSignal(
        // The rollup can say `fail` with an empty check list (a shed lookup),
        // and "0 checks failing" would be a lie.
        failed.isEmpty
            ? 'CI failing'
            : '${_plural(failed.length, 'check')} failing',
        draft ? PrTone.quiet : PrTone.blocking,
        remedy: const PromptRemedy(PrPromptAction.fixPr),
        detail: failed.isEmpty ? null : failed.map((c) => c.name).join(' · '),
      ),
    );
  }
  // GitHub's own "Update branch" condition: the base has commits this head does
  // not. Ranked below a red build (updating reruns CI anyway) and above review
  // threads (a stale head can make review comments moot).
  if (open != null && open.mergeStateStatus?.toUpperCase() == 'BEHIND') {
    signals.add(
      const PrSignal(
        'the base branch moved on',
        PrTone.attention,
        remedy: DirectRemedy(PrDirectOp.updateBranch),
      ),
    );
  }
  if (open != null && !open.unresolvedUnknown && open.unresolvedComments > 0) {
    signals.add(
      PrSignal(
        '${_plural(open.unresolvedComments, 'thread')} open',
        draft ? PrTone.quiet : PrTone.attention,
        remedy: const PromptRemedy(PrPromptAction.resolveComments),
      ),
    );
  }

  // Facts with no remedy, reported last: they are context, never a next step.
  final pending = open?.checks.where((c) => c.bucket == 'pending').length ?? 0;
  if (pending > 0) {
    signals.add(
      PrSignal(
        '$pending of ${open!.checks.length} checks still running',
        PrTone.quiet,
      ),
    );
  } else if (open?.checkRollup == 'pending') {
    // The count lives in the check list, but the *verdict* lives in the rollup —
    // and SPEC-32 sheds the list while keeping the rollup. Reading only the list
    // made a running build indistinguishable from an all-clear, which then
    // offered `Squash & merge` on a build that had not finished.
    signals.add(const PrSignal('CI still running', PrTone.quiet));
  }
  // Last, so it only becomes the loud fact once the PR has nothing else
  // outstanding — marking a half-finished PR ready is not the next step.
  if (draft) {
    signals.add(
      const PrSignal(
        'still a draft',
        PrTone.quiet,
        remedy: DirectRemedy(PrDirectOp.markReady),
      ),
    );
  }

  // ── the all-clear ─────────────────────────────────────────────────────────
  if (signals.isEmpty) {
    final passed = open?.checks.where((c) => c.bucket == 'pass').length ?? 0;
    // Nothing outstanding *and* GitHub says it would take the merge: this is the
    // moment its own button lights up, so ours does too. Reaching here already
    // implies no conflicts, no red or in-flight build, no threads, no local work
    // and not a draft — each of those adds a signal above.
    //
    // BLOCKED means a required review or check is missing, so GitHub would refuse;
    // a null/UNKNOWN mergeability is not a yes, and guessing would offer a merge
    // that errors.
    final mergeable =
        open != null && open.mergeable?.toUpperCase() == 'MERGEABLE';
    final blocked = open?.mergeStateStatus?.toUpperCase() == 'BLOCKED';
    if (mergeable && !blocked) {
      signals.add(
        const PrSignal(
          'ready to merge',
          PrTone.quiet,
          remedy: DirectRemedy(PrDirectOp.squashMerge),
        ),
      );
    } else {
      signals.add(
        PrSignal(
          open == null
              // No PR *this derivation recognises*. A pull request in an
              // unrecognised state is not a branch waiting for one — saying
              // `#142 · ready for a PR` contradicted itself in four words — so it
              // reports that the state is the thing it does not know.
              ? (pr != null
                    ? 'PR state unknown'
                    // A secondary branch is ready to become one; the primary
                    // checkout is not — you do not raise a pull request for
                    // `main`, so it just reports that it is clean.
                    : (isPrimary ? 'clean' : 'ready for a PR'))
              : passed > 0
              ? '${_plural(passed, 'check')} passed'
              : 'green and up to date',
          PrTone.quiet,
        ),
      );
    }
  }

  final loud = signals.first;
  // A call to action that *has* an action must not look inert. Several quiet
  // facts carry a remedy — `still a draft`, `ready to merge`, and a draft's own
  // build and threads (a draft mutes its facts) — and a grey button for them
  // reads as disabled. Promoted for the button's tint only; the facts stay quiet
  // wherever they are listed.
  //
  // Promoted to the *remedy's* own tone where it has one: landing a pull request
  // is what purple means everywhere else in the pane, and an amber "Squash &
  // merge" said `attention` about the one action that is good news (mockup §3
  // `ready`).
  final ctaTone = loud.tone != PrTone.quiet
      ? loud.tone
      : switch (loud.remedy) {
          DirectRemedy(op: PrDirectOp.squashMerge) => PrTone.landed,
          _ => PrTone.attention,
        };

  // "Fix everything" is the honest single next step only when it really would fix
  // everything. The composed prompt carries prompt-backed facts alone, so a
  // pending direct op (say `the base branch moved on`) would be silently left
  // undone behind a button that claims otherwise — better to name one verb.
  final actionable = signals.where((s) => s.remedy != null).toList();
  final promptBacked = actionable.where((s) => s.remedy is PromptRemedy).length;
  final cta = promptBacked >= 2 && promptBacked == actionable.length
      ? PrCta('Fix', ctaTone, remedy: const MagicRemedy())
      : _ctaFor(
          loud,
          tone: ctaTone,
          // "Create PR" is only ever offered for a branch that could have one —
          // keyed off the PR itself, not off `open`: a PR in a state this
          // derivation does not recognise leaves `open` null while very much
          // having one.
          canCreatePr: pr == null && !isPrimary,
          branch: branch,
        );

  return PrStatus(
    identity: identity,
    tone: loud.tone,
    dot: _dotFor(open, draft: draft, hasPr: pr != null, signals: signals),
    hasPr: pr != null,
    isPrimary: isPrimary,
    stale: pr?.stale ?? false,
    signals: signals,
    checkProgress: pending > 0 && open!.checks.isNotEmpty
        ? (open.checks.length - pending) / open.checks.length
        : null,
    cta: cta,
  );
}

/// The status dot for a live (neither merged nor closed) worktree, in precedence
/// order — mockup §2.
///
/// [draft] comes before the check rows on purpose: §5 mutes a draft's own facts
/// because it is not up for review, and a red arc over a deliberately quiet
/// sentence would undo that.
PrDot _dotFor(
  PullRequest? open, {
  required bool draft,
  required bool hasPr,
  required List<PrSignal> signals,
}) {
  // "Nothing to report" is the whole meaning of the ring, so it is not enough for
  // the PR to be missing: a branch with three uncommitted files has plenty to
  // report and gets its fact's hue (the mockup's `dirty` picture).
  if (!hasPr && !signals.any((s) => s.remedy != null)) return PrDot.none;
  if (draft) return PrDot.muted;
  if (open == null) return PrDot.tone;
  // In flight by either account: a reported pending check, or a rollup that says
  // pending with its list shed.
  if (open.checks.any((c) => c.bucket == 'pending') ||
      open.checkRollup == 'pending') {
    return PrDot.pending;
  }
  if (open.checkRollup == 'fail') return PrDot.fail;
  // Green means *nothing needs you*, so the pass verdict only holds while nothing
  // is pressing. A PR with conflicts, a moved base, open threads or unpushed work
  // drew the same green as one that was ready to merge — the one ambient graphic
  // said all-clear and left the sentence to contradict it.
  //
  // A red or in-flight build still outranks (both are checked above): `hot` keeps
  // its red dot over an amber sentence, which is what §8.1 exists for.
  if (open.checkRollup == 'pass' && signals.first.tone == PrTone.quiet) {
    return PrDot.pass;
  }
  // Either something is pressing, or there is no verdict to report (a shed lookup,
  // or a PR with no checks at all) — so the dot defers to the loud fact.
  return PrDot.tone;
}

/// The CTA for the loud signal: its remedy, labelled with the remedy's own verb.
/// A signal with no remedy leaves the CTA idle — except on a branch that could
/// still become a pull request, where "create one" is the standing offer.
PrCta _ctaFor(
  PrSignal loud, {
  required PrTone tone,
  required bool canCreatePr,
  required String? branch,
}) {
  final remedy = loud.remedy;
  if (remedy == null) {
    if (canCreatePr && branch != null) {
      return const PrCta(
        'Create PR',
        PrTone.attention,
        remedy: PromptRemedy(PrPromptAction.createPr),
      );
    }
    return const PrCta('Ask the agent', PrTone.quiet);
  }
  return PrCta(prRemedyLabel(remedy), tone, remedy: remedy);
}

/// The verb on the button for a remedy.
String prRemedyLabel(PrRemedy remedy) => switch (remedy) {
  PromptRemedy(action: final a) => switch (a) {
    // The bar names the *situation's* verb, which is terser than the menu label
    // ("Fix", not "Fix PR") because the bar has already said what is wrong. The
    // magic remedy wears the same "Fix" deliberately — both fix, and the sentence
    // beside the button is what says how much (SPEC-38 §8 D12).
    PrPromptAction.fixPr => 'Fix',
    PrPromptAction.pull => 'Pull',
    PrPromptAction.push => 'Push',
    PrPromptAction.commitAndPush => 'Commit & push',
    PrPromptAction.resolveComments => 'Resolve',
    PrPromptAction.createPr => 'Create PR',
  },
  DirectRemedy(op: PrDirectOp.wrapUp) => 'Wrap up',
  DirectRemedy(op: PrDirectOp.discardWorktree) => 'Discard worktree',
  DirectRemedy(op: PrDirectOp.markReady) => 'Mark ready',
  DirectRemedy(op: PrDirectOp.updateBranch) => 'Update branch',
  DirectRemedy(op: PrDirectOp.squashMerge) => 'Squash & merge',
  MagicRemedy() => 'Fix',
};

/// The glyph on the button for a remedy. A prompt reuses the action's own icon
/// (so the bar and the Settings list agree); the direct ops get their own.
/// A null remedy is the idle CTA, which offers the menu rather than a verb.
IconGlyph prRemedyIcon(PrRemedy? remedy) => switch (remedy) {
  PromptRemedy(action: final a) => a.icon,
  DirectRemedy(op: PrDirectOp.wrapUp) => const IconGlyph.font(
    PhosphorIconsLight.broom,
  ),
  DirectRemedy(op: PrDirectOp.discardWorktree) => const IconGlyph.font(
    PhosphorIconsLight.trash,
  ),
  DirectRemedy(op: PrDirectOp.markReady) => const IconGlyph.font(
    PhosphorIconsLight.checkCircle,
  ),
  DirectRemedy(op: PrDirectOp.updateBranch) => const IconGlyph.font(
    PhosphorIconsLight.arrowsMerge,
  ),
  DirectRemedy(op: PrDirectOp.squashMerge) => const IconGlyph.font(
    PhosphorIconsLight.gitMerge,
  ),
  MagicRemedy() => const IconGlyph.font(PhosphorIconsLight.magicWand),
  null => const IconGlyph.font(PhosphorIconsLight.sparkle),
};

/// [prStatus] for a located worktree (see `ReposState.locateWorktree`).
///
/// A null [at] means the repos snapshot does not know this path yet — a brand
/// new worktree, or a non-git project. That is a real, common state (the
/// worktree starter renders in it), so it degrades to "no PR, nothing
/// outstanding" rather than hiding the bar.
PrStatus prStatusFor(
  ({RepoInfo repo, Worktree worktree})? at, {
  String? fallbackBranch,
}) {
  final w = at?.worktree;
  if (w == null) {
    return prStatus(pr: null, branch: fallbackBranch);
  }
  // The `left behind` half of the wrap-up brief, assembled from the snapshot the
  // caller already holds — see [PrResidue]. `firstWhereOrNull` by hand: the
  // primary worktree is normally present, but a snapshot mid-refresh (or a
  // non-git project) can carry none.
  Worktree? primary;
  for (final other in at!.repo.worktrees) {
    if (other.isPrimary) {
      primary = other;
      break;
    }
  }
  return prStatus(
    pr: w.pr,
    branch: w.branch ?? fallbackBranch,
    uncommittedFiles: w.uncommittedFiles,
    commitsAhead: w.aheadCount,
    commitsBehind: w.behindCount,
    isPrimary: w.isPrimary,
    // Residue is what a wrap-up or discard would *take with it*, and the primary
    // checkout is never removed (see the ending branch: it gets no direct op at
    // all). So it has no residue to report — its sessions are not going anywhere,
    // and naming its own branch as "behind" would report it against itself.
    residue: w.isPrimary
        ? const PrResidue()
        : PrResidue(
            sessions: w.sessionIds.length,
            baseBranch: primary?.branch,
            baseBehind: primary?.behindCount ?? 0,
          ),
  );
}
