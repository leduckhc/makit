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

/// The deterministic operations the bar runs itself, rather than asking the agent
/// to. Each is a single unambiguous call — anything needing judgement stays a
/// prompt.
///
/// [wrapUp] and [discardWorktree] destroy a worktree and so are confirmed;
/// [markReady] and [updateBranch] only change state on GitHub, are reversible or
/// additive, and run straight from the button (see `isDestructive`).
enum PrDirectOp {
  /// Merged: stop the worktree's sessions, remove the worktree, delete the
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
    this.checkProgress,
    this.stale = false,
    this.hasPr = false,
    this.isEnded = false,
  });

  /// `#142` for a PR, else the branch name (or `detached`).
  final String identity;

  /// The dot's hue — the tone of the loud signal.
  final PrTone tone;

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
///   6. open review threads.
/// Steps 1–3, 5 and 6 keep the exact precedence the shipped `_situationFor`
/// used, so this rewrite cannot silently reshuffle the offered action.
PrStatus prStatus({
  required PullRequest? pr,
  required String? branch,
  int uncommittedFiles = 0,
  int commitsAhead = 0,
  int commitsBehind = 0,
  bool isPrimary = false,
}) {
  final state = pr?.state.toUpperCase();
  final identity = pr != null ? '#${pr.number}' : (branch ?? 'detached');

  // ── endings ───────────────────────────────────────────────────────────────
  // Removing a worktree is only possible for a secondary one; the primary
  // checkout *is* the repo (mirrors `canDeleteWorktree`). So a landed PR on the
  // primary checkout still says it landed, it just has nothing to offer.
  if (state == 'MERGED' || state == 'CLOSED') {
    final merged = state == 'MERGED';
    final tone = merged ? PrTone.landed : PrTone.blocking;
    final op = merged ? PrDirectOp.wrapUp : PrDirectOp.discardWorktree;
    return PrStatus(
      identity: identity,
      tone: tone,
      hasPr: true,
      isEnded: true,
      stale: pr!.stale,
      signals: [
        PrSignal(merged ? 'merged' : 'closed without merging', tone),
        if (uncommittedFiles > 0)
          PrSignal('${_plural(uncommittedFiles, 'file')} uncommitted', tone),
        if (!isPrimary) PrSignal('worktree still here', tone),
      ],
      cta: isPrimary
          // Nothing to tidy: the primary checkout stays. It still reports that
          // the PR landed, it just has no ending to offer.
          ? const PrCta('Ask the agent', PrTone.quiet)
          : PrCta(
              merged ? 'Wrap up' : 'Discard worktree',
              tone,
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
        detail: failed.isEmpty
            ? null
            : failed.map((c) => c.name).join(' · '),
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
    final mergeable = open != null && open.mergeable?.toUpperCase() == 'MERGEABLE';
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
            // No PR and nothing outstanding. A secondary branch is ready to
            // become one; the primary checkout is not — you do not raise a pull
            // request for `main`, so it just reports that it is clean.
            ? (isPrimary ? 'clean' : 'ready for a PR')
            : passed > 0
            ? '${_plural(passed, 'check')} passed'
            : 'green and up to date',
        PrTone.quiet,
      ),
      );
    }
  }

  final loud = signals.first;
  // A call to action that *has* an action must not look inert. The only quiet
  // facts carrying a remedy are a draft's (a draft mutes its own facts), and a
  // grey button for them reads as disabled. Promoted for the button's tint only;
  // the facts stay quiet wherever they are listed.
  final ctaTone = loud.tone == PrTone.quiet ? PrTone.attention : loud.tone;

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
          // "Create PR" is only ever offered for a branch that could have one.
          canCreatePr: open == null && !isPrimary,
          branch: branch,
        );

  return PrStatus(
    identity: identity,
    tone: loud.tone,
    hasPr: pr != null,
    stale: pr?.stale ?? false,
    signals: signals,
    checkProgress: pending > 0 && open!.checks.isNotEmpty
        ? (open.checks.length - pending) / open.checks.length
        : null,
    cta: cta,
  );
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
    // ("Fix CI", not "Fix PR") because the bar has already said what is wrong.
    PrPromptAction.fixPr => 'Fix CI',
    PrPromptAction.pull => 'Pull',
    PrPromptAction.push => 'Push',
    PrPromptAction.commitAndPush => 'Commit & push',
    PrPromptAction.resolveComments => 'Resolve threads',
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
  return prStatus(
    pr: w.pr,
    branch: w.branch ?? fallbackBranch,
    uncommittedFiles: w.uncommittedFiles,
    commitsAhead: w.aheadCount,
    commitsBehind: w.behindCount,
    isPrimary: w.isPrimary,
  );
}
