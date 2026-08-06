import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../widgets/pr_detail.dart';
import '../widgets/pr_signals.dart';
import '../widgets/pr_tone.dart';
import '../widgets/wrap_up.dart';

/// Widest the chip's label may get before it elides. Roomier than the home row's
/// because the session subtitle owns its whole line — there is no age column to
/// push off the end.
const double _kChipLabelMaxWidth = 220;

/// The session screen's PR indicator (mobile): a tone dot plus the loudest fact
/// on the subtitle line under the session title — `#42 · 2 checks failing` —
/// opening the shared detail sheet.
///
/// It sits in the subtitle because that line is otherwise dead space outside
/// multiplexer sessions, so at-a-glance state costs no new vertical chrome.
///
/// The mobile counterpart of the desktop composer's next-step bar, reading the
/// same [PrStatus]. It used to show `#42` plus a bare CI verdict word, which said
/// whether the build was unhappy but never what to do about it — and offered the
/// same five prompts on every PR once opened.
class SessionPrChip extends ConsumerWidget {
  const SessionPrChip({
    super.key,
    required this.status,
    this.pr,
    this.projectId,
    this.worktreePath,
    this.branch,
    this.uncommittedFiles = 0,
    this.onInsertPrompt,
  });

  /// The derived facts + the call to action.
  final PrStatus status;

  /// The PR itself, for the sheet's check list and web link. Null when none.
  final PullRequest? pr;

  /// Identity for the direct operations (wrap up / discard).
  final String? projectId;
  final String? worktreePath;

  /// The worktree's branch and uncommitted count, for the confirm dialog.
  final String? branch;
  final int uncommittedFiles;

  /// Where a picked prompt goes.
  final void Function(String prompt)? onInsertPrompt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    // The chip's label; its background keeps the vivid dot hue below.
    final tone = prToneTextColor(cs, status.tone);

    return InkWell(
      borderRadius: BorderRadius.circular(kRadius8),
      onTap: () => showPrDetail(
        context,
        status: status,
        pr: pr,
        sheet: true,
        canInsertPrompt: onInsertPrompt != null,
        onRun: (remedy) => runPrRemedy(
          context,
          ref,
          remedy: remedy,
          status: status,
          pr: pr,
          projectId: projectId,
          worktreePath: worktreePath,
          branch: branch,
          uncommittedFiles: uncommittedFiles,
          onInsertPrompt: onInsertPrompt ?? (_) {},
        ),
      ),
      // The chip is the only way into the PR sheet from a session, so it is a
      // control and gets a control's target (kTouchRow). The tint stays painted
      // around the content — only the transparent hit box is tall.
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kTouchRow),
        // Painted at the top of the box, not centred: the chip keeps its
        // position tight under the session title, and the extra target height
        // extends *downwards* into empty overlay space instead of pushing the
        // chip away from the title.
        child: Align(
          alignment: Alignment.topLeft,
          widthFactor: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: kSpace4,
              vertical: kSpace2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PrToneDot(
                  tone: status.tone,
                  progress: status.checkProgress,
                  hollow: pr == null,
                ),
                const SizedBox(width: kSpace6),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: _kChipLabelMaxWidth,
                  ),
                  child: Text(
                    status.hasPr
                        ? '${status.identity} · ${status.loud.label}'
                        : status.loud.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelXs?.copyWith(
                      color: tone,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
