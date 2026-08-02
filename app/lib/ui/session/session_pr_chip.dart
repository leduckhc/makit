import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../widgets/pr_sheet.dart';
import '../widgets/pr_state_style.dart';

/// The session screen's PR indicator (SPEC-23, mobile): a tap-through chip on
/// the subtitle line under the session title — `#42` plus the CI verdict —
/// opening [showPrSheet] for the detail the desktop shows on hover.
///
/// It sits in the subtitle because that line is otherwise dead space outside
/// multiplexer sessions, so at-a-glance CI state costs no new vertical chrome.
class SessionPrChip extends StatelessWidget {
  const SessionPrChip({super.key, required this.pr, this.onInsertPrompt});

  final PullRequest pr;

  /// Forwarded to the sheet's PR actions — see [showPrSheet].
  final void Function(String prompt)? onInsertPrompt;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = prStateStyle(cs, pr);
    final isOpen = pr.state.toUpperCase() == 'OPEN';
    final (icon: color, label: labelColor) = prPillColors(cs, pr);
    final verdict = isOpen && pr.checkRollup != 'none'
        ? prCheckBucketLabel(pr.checkRollup)
        : null;

    return InkWell(
      borderRadius: BorderRadius.circular(kRadius8),
      onTap: () => showPrSheet(context, pr, onInsertPrompt: onInsertPrompt),
      // The chip is the only way into the PR sheet from a session, so it is a
      // control and gets a control's target (kTouchRow). The tint stays painted
      // around the content — only the transparent hit box is tall.
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kTouchRow),
        // Painted at the top of the box, not centred: the chip keeps its old
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
                style.glyph.build(size: kPillIconSize, color: color),
                const SizedBox(width: 3),
                Text(
                  '#${pr.number}',
                  style: Theme.of(context).textTheme.labelXs?.copyWith(
                    color: labelColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (verdict != null) ...[
                  const SizedBox(width: kSpace6),
                  Text(
                    verdict,
                    style: Theme.of(
                      context,
                    ).textTheme.labelXs?.copyWith(color: labelColor),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
