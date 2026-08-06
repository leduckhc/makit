/// Running a [PrRemedy], and the confirm that guards the destructive ones.
///
/// Three kinds of action share one entry point ([runPrRemedy]) so every surface —
/// the desktop bar, its menu, the detail sheet, the mobile row — dispatches
/// identically:
///  * a [PromptRemedy] inserts its canned text in the composer and stops. The
///    user reads it and presses Send; nothing is ever sent on their behalf.
///  * a [MagicRemedy] does the same with one prompt composed from every
///    outstanding prompt-backed fact, in precedence order.
///  * a [DirectRemedy] runs a server command. The three that cannot be taken
///    back in one click ask first, and the question spells out every step rather
///    than saying "are you sure?".
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/prefs/preference_entries.dart';
import '../../store/prefs/preferences_providers.dart';
import '../../store/store.dart';
import 'pr_actions.dart';
import 'pr_signals.dart';

/// What a direct op did, for the snackbar.
class PrOpOutcome {
  const PrOpOutcome(this.message, {this.detail});

  final String message;

  /// Extra explanation the user could not have predicted (e.g. why the base
  /// branch was left alone), surfaced behind a "Why?" action.
  final String? detail;
}

/// What a [PrOpRunner] needs to identify the thing being acted on.
class PrOpTarget {
  const PrOpTarget({
    required this.projectId,
    required this.worktreePath,
    this.baseBranch,
    this.expectBranch,
  });

  final String projectId;
  final String worktreePath;

  /// The PR's `baseRefName`, for wrap up's fast-forward leg.
  final String? baseBranch;

  /// The branch the confirm dialog named. The server resolves the branch again
  /// when it runs, so without this the user could confirm "delete feat/x" and
  /// have a different branch deleted — one they checked out since the snapshot.
  final String? expectBranch;
}

/// Runs a direct op against the server.
///
/// Injected rather than called inline so the decision half of [runPrRemedy]
/// (confirm or not, then dispatch) is testable without a live connection: the
/// real implementation returns a future that never completes offline, which left
/// a pending timer and made it impossible to assert that a non-confirming op
/// skips its dialog.
typedef PrOpRunner =
    Future<PrOpOutcome> Function(PrDirectOp op, PrOpTarget target);

/// The default executor: the real server commands, and what each reports.
final prOpRunnerProvider = Provider<PrOpRunner>(
  (ref) => (op, target) async {
    final store = ref.read(storeControllerProvider.notifier);
    switch (op) {
      case PrDirectOp.wrapUp:
        final report = await store.wrapUpWorktree(
          target.projectId,
          target.worktreePath,
          baseBranch: target.baseBranch,
          expectBranch: target.expectBranch,
        );
        return PrOpOutcome(report.summary, detail: report.detail);
      case PrDirectOp.discardWorktree:
        final report = await store.discardWorktree(
          target.projectId,
          target.worktreePath,
          expectBranch: target.expectBranch,
        );
        return PrOpOutcome(report.summary, detail: report.detail);
      case PrDirectOp.markReady:
        await store.markPrReady(target.projectId, target.worktreePath);
        return const PrOpOutcome('Marked ready for review');
      case PrDirectOp.updateBranch:
        await store.updatePrBranch(target.projectId, target.worktreePath);
        return const PrOpOutcome('Merged the base branch in');
      case PrDirectOp.squashMerge:
        await store.squashMergePr(target.projectId, target.worktreePath);
        return const PrOpOutcome('Squashed and merged');
    }
  },
);

/// Dispatch [remedy].
///
/// [projectId] and [worktreePath] are required for a [DirectRemedy]; when either
/// is missing the op is refused with a message rather than silently doing
/// nothing, because a button that looks armed and isn't is worse than an error.
///
/// [branch] and [uncommittedFiles] are passed rather than derived from [status]:
/// the branch is not recoverable from `status.identity` once a PR exists (it is
/// the PR number by then), and inferring the uncommitted count by string-matching
/// a display label would let a reworded label silently delete a data-loss warning.
Future<void> runPrRemedy(
  BuildContext context,
  WidgetRef ref, {
  required PrRemedy remedy,
  required PrStatus status,
  required PullRequest? pr,
  required String? projectId,
  required String? worktreePath,
  required void Function(String prompt) onInsertPrompt,
  String? branch,
  int uncommittedFiles = 0,
}) async {
  // The sheet or dialog holding this callback can outlive the widget that opened
  // it — a repos snapshot can drop the worktree row while its sheet is still up.
  // Everything below touches `ref` and `context`, both of which throw on a
  // defunct element, so bail before the first of them rather than after.
  if (!context.mounted) return;
  switch (remedy) {
    case PromptRemedy(action: final action):
      // Remember the pick so the menu can mark it, matching the old bar.
      ref
          .read(preferencesControllerProvider.notifier)
          .set(lastPrActionPreference, action.name);
      onInsertPrompt(ref.effectivePrPrompt(action));
    case MagicRemedy():
      // Every fact that has a prompt-shaped remedy, handed over at once and in
      // precedence order — an unordered list invites a pull onto a dirty tree.
      // Facts you cannot act on (checks in flight) are not problems to fix.
      onInsertPrompt(
        ref.magicFixPrompt([
          for (final s in status.signals)
            if (s.remedy is PromptRemedy) (label: s.label, detail: s.detail),
        ]),
      );
    case DirectRemedy(op: final op):
      final messenger = ScaffoldMessenger.of(context);
      // Resolved before any await: the widget that owns `ref` can be disposed
      // while the confirm dialog is up (its row may vanish on a snapshot), and
      // reading a disposed ref throws.
      final run = ref.read(prOpRunnerProvider);
      if (projectId == null || worktreePath == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('No worktree to act on')),
        );
        return;
      }
      // Only the irreversible ones ask (see [needsConfirm]). Marking a PR ready
      // or updating its branch is reversible/additive, and a confirm there would
      // be the kind of dialog users learn to dismiss unread — which is what makes
      // the wrap-up and merge confirms worth reading.
      if (needsConfirm(op)) {
        final confirmed = await showPrDirectConfirm(
          context,
          op: op,
          pr: pr,
          worktreePath: worktreePath,
          branch: branch,
          uncommittedFiles: uncommittedFiles,
          identity: status.identity,
        );
        if (confirmed != true) return;
        if (!context.mounted) return;
      }
      try {
        final outcome = await run(
          op,
          PrOpTarget(
            projectId: projectId,
            worktreePath: worktreePath,
            baseBranch: pr?.baseRefName,
            expectBranch: branch,
          ),
        );
        if (!messenger.mounted) return;
        messenger.showSnackBar(
          SnackBar(
            content: Text(outcome.message),
            action: outcome.detail == null
                ? null
                : SnackBarAction(
                    label: 'Why?',
                    onPressed: () => messenger.showSnackBar(
                      SnackBar(content: Text(outcome.detail!)),
                    ),
                  ),
          ),
        );
      } catch (e) {
        if (!messenger.mounted) return;
        messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
  }
}

/// Ask before a direct op that cannot be taken back in one click.
///
/// Each op states what it will actually do, in order, and names the branches
/// involved — a "wrap up" that silently moved `main`, or a merge that silently
/// squashed, would both be alarming; one that silently *didn't* would be
/// misleading.
Future<bool?> showPrDirectConfirm(
  BuildContext context, {
  required PrDirectOp op,
  required PullRequest? pr,
  required String worktreePath,
  required String identity,
  String? branch,
  int uncommittedFiles = 0,
}) {
  final base = pr?.baseRefName;

  final (
    IconData icon,
    Color Function(ColorScheme) tint,
    String title,
    String verb,
  ) = switch (op) {
    PrDirectOp.wrapUp => (
      PhosphorIconsLight.broom,
      (ColorScheme cs) => cs.prMergedText,
      'Wrap up',
      'Wrap up',
    ),
    PrDirectOp.discardWorktree => (
      PhosphorIconsLight.trash,
      (ColorScheme cs) => cs.error,
      'Discard worktree',
      'Discard',
    ),
    PrDirectOp.squashMerge => (
      PhosphorIconsLight.gitMerge,
      (ColorScheme cs) => cs.prMergedText,
      'Squash & merge',
      'Squash & merge',
    ),
    // Never reached: these do not ask (see [needsConfirm]).
    _ => (
      PhosphorIconsLight.question,
      (ColorScheme cs) => cs.primary,
      'Continue',
      'Continue',
    ),
  };

  return showDialog<bool>(
    context: context,
    builder: (dctx) {
      final cs = Theme.of(dctx).colorScheme;
      return AlertDialog(
        title: Row(
          children: [
            Icon(icon, size: 20, color: tint(cs)),
            const SizedBox(width: kSpace8),
            Text(title),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(switch (op) {
              PrDirectOp.wrapUp =>
                'This pull request has merged. Tidy up after it:',
              PrDirectOp.discardWorktree =>
                'This pull request was closed without merging. Remove what it '
                    'left behind:',
              _ =>
                'Land $identity on ${base ?? 'its base branch'}, GitHub-side:',
            }, style: Theme.of(dctx).textTheme.bodyMedium),
            // The sentence above asserts a PR state the app took from its last
            // snapshot, and nothing re-checks GitHub before acting (SPEC-38 §11a
            // L1). When that snapshot is explicitly last-known — SPEC-32 shed the
            // refresh to save quota — the assertion may be false, so qualify it.
            //
            // It warns rather than refusing: blocking here would reintroduce the
            // very failure the L1 fix was rejected for, where tidying up stops
            // working exactly when quota is tight.
            if (pr?.stale == true) ...[
              const SizedBox(height: kSpace8),
              const _Step(
                'Its state could not be refreshed (GitHub quota), so this may '
                'already be out of date',
                warn: true,
              ),
            ],
            const SizedBox(height: kSpace12),
            if (op == PrDirectOp.squashMerge) ...[
              _Step(
                'Squash every commit on this branch into one on '
                '${base ?? 'the base branch'}',
              ),
              // The two things a user is most likely to assume happen and be
              // wrong about, so both are stated rather than left to be inferred.
              const _Step('Close the pull request'),
              const _Step(
                'Leave this worktree and its sessions alone — tidy up '
                'separately afterwards',
              ),
            ] else ...[
              // Order matters and mirrors the server: the worktree goes first,
              // and only then are its sessions reconciled — doing it the other
              // way round could orphan them if the git removal failed.
              _Step('Remove the worktree at $worktreePath'),
              // Live sessions are archived, not stopped: the transcript and the
              // resume handle survive (SPEC-29). Drafts have neither, so they go.
              const _Step(
                'Archive the sessions running in it (drafts are discarded)',
              ),
              if (branch != null) _Step('Delete the local branch $branch'),
              if (op == PrDirectOp.wrapUp)
                _Step(
                  base == null
                      ? 'Fast-forward the default branch in the primary checkout'
                      : 'Fast-forward $base in the primary checkout',
                ),
              if (uncommittedFiles > 0)
                _Step(
                  '${uncommittedFiles == 1 ? '1 file' : '$uncommittedFiles files'}'
                  ' uncommitted here will be lost',
                  warn: true,
                ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(verb),
          ),
        ],
      );
    },
  );
}

/// One line of the confirm dialog's plan.
class _Step extends StatelessWidget {
  const _Step(this.text, {this.warn = false});

  final String text;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = warn ? cs.error : cs.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            warn ? PhosphorIconsLight.warning : PhosphorIconsLight.dot,
            size: 15,
            color: color,
          ),
          const SizedBox(width: kSpace6),
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
