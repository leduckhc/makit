import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../ui/widgets/icon_glyph.dart';
import '../../ui/widgets/pr_detail.dart';
import '../../ui/widgets/pr_signals.dart';
import '../../ui/widgets/pr_tone.dart';
import '../../ui/widgets/wrap_up.dart';

/// Tooltip on a stale bar. Names *why* the data is dimmed — a refresh that could
/// not complete against GitHub's quota — so the user can tell last-known data
/// from current data instead of guessing at the dimming.
const kStalePrTooltip =
    'Last known state — could not refresh (GitHub quota). '
    'Retrying automatically.';

/// The row directly above the docked composer: **one sentence about the
/// worktree, and the one action that moves it forward.**
///
/// `<dot> #142 · 2 checks failing   +2 more            [ Fix CI ▾ ]`
///
/// Replaces the old two-zone bar (a `PR #42` pill plus a general-purpose
/// six-prompt split button), whose two halves secretly depended on each other:
/// the pill's neighbouring chip is what set the button's default action, and
/// nothing on screen said so. Here the sentence *is* the reason for the button,
/// read left to right.
///
/// What it shows comes entirely from [PrStatus] — the shared derivation the
/// mobile row and sheet also read, so the three surfaces cannot disagree about
/// whether a PR is failing. This widget only decides how much of it fits: the
/// loud fact in full, the rest as a `+n more` disclosure onto [showPrDetail].
class PrComposerBar extends ConsumerWidget {
  const PrComposerBar({
    super.key,
    required this.status,
    required this.onInsertPrompt,
    this.pr,
    this.projectId,
    this.worktreePath,
    this.branch,
    this.uncommittedFiles = 0,
  });

  /// The derived facts + the call to action. See [prStatusFor].
  final PrStatus status;

  /// The PR itself, for the detail sheet's check list and its web link. Null
  /// when the worktree has none.
  final PullRequest? pr;

  /// Identity for the direct operations (wrap up / discard). When either is
  /// null those actions are unavailable — there is nothing safe to act on.
  final String? projectId;
  final String? worktreePath;

  /// The worktree's branch, for the confirm dialog's "delete the local branch"
  /// step. Not derivable from [status] — its identity is the PR number by then.
  final String? branch;

  /// Files with uncommitted changes, for the confirm's data-loss warning. Passed
  /// rather than parsed back out of a signal label.
  final int uncommittedFiles;

  /// Insert a resolved canned prompt into the composer (does not send).
  final void Function(String prompt) onInsertPrompt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
      child: Row(
        children: [
          Flexible(
            child: _Reason(
              status: status,
              onOpen: () => _openDetail(context, ref),
            ),
          ),
          if (status.more > 0) ...[
            const SizedBox(width: kSpace8),
            _MoreLink(
              count: status.more,
              onTap: () => _openDetail(context, ref),
            ),
          ],
          const SizedBox(width: kSpace10),
          PrCtaButton(
            status: status,
            onInsertPrompt: onInsertPrompt,
            onRun: (remedy) => _run(context, ref, remedy),
          ),
        ],
      ),
    );
  }

  void _openDetail(BuildContext context, WidgetRef ref) => showPrDetail(
    context,
    status: status,
    pr: pr,
    onRun: (remedy) => _run(context, ref, remedy),
  );

  Future<void> _run(BuildContext context, WidgetRef ref, PrRemedy remedy) =>
      runPrRemedy(
        context,
        ref,
        remedy: remedy,
        status: status,
        pr: pr,
        projectId: projectId,
        worktreePath: worktreePath,
        branch: branch,
        uncommittedFiles: uncommittedFiles,
        onInsertPrompt: onInsertPrompt,
      );
}

/// The sentence: a status dot, the PR number (or branch), and the loud fact.
/// Truncates with an ellipsis rather than growing the row — the composer's width
/// is not negotiable, and a bar that reflows as CI churns is worse than one that
/// elides.
class _Reason extends StatelessWidget {
  const _Reason({required this.status, required this.onOpen});

  final PrStatus status;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tone = prToneColor(cs, status.tone);
    final base = Theme.of(context).textTheme.bodySmall ?? const TextStyle();
    // Only the *derived* half dims when stale. The PR number never goes stale,
    // so dimming it too (as the old pill did, wholesale) hid the one fact that
    // was still reliable.
    final dim = status.stale ? 0.55 : 1.0;

    final sentence = Text.rich(
      TextSpan(
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(right: kSpace6),
              child: PrToneDot(
                tone: status.tone,
                progress: status.checkProgress,
                hollow: status.identity.isNotEmpty && !status.identity.startsWith('#'),
              ),
            ),
          ),
          TextSpan(
            text: status.identity,
            style: base.copyWith(
              color: cs.onSurface.withValues(alpha: dim),
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(
            text: '  ·  ',
            style: base.copyWith(color: cs.outlineVariant),
          ),
          TextSpan(
            text: status.loud.label,
            style: base.copyWith(color: tone.withValues(alpha: dim)),
          ),
          if (status.stale)
            TextSpan(
              text: '  ·  last known',
              style: base.copyWith(color: cs.outline, fontSize: 11),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
    );

    return Tooltip(
      message: status.stale ? kStalePrTooltip : 'Show detail',
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(kRadius6),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kSpace4,
            vertical: kSpace2,
          ),
          child: sentence,
        ),
      ),
    );
  }
}

/// `+2 more` — the disclosure onto the full fact list.
class _MoreLink extends StatelessWidget {
  const _MoreLink({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Show the other $count',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadius6),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kSpace4,
            vertical: kSpace2,
          ),
          child: Text(
            '+$count more',
            style: Theme.of(context).textTheme.labelXs?.copyWith(
              color: cs.outline,
              decoration: TextDecoration.underline,
              decorationStyle: TextDecorationStyle.dotted,
              decorationColor: cs.outlineVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// The call to action: the remedy for the loud fact, plus a caret onto the full
/// menu ([showPrActionMenu]).
///
/// Three visual registers, so "ask the agent to try" and "delete this worktree
/// now" can never be confused for each other:
///  * **idle** — nothing pressing: a quiet outline, and the main segment opens
///    the menu rather than pretending one of six prompts is the obvious step,
///  * **agent prompt** — tonal fill in the fact's tone; inserts text,
///  * **direct op** — solid fill; runs now (behind a confirm when destructive).
class PrCtaButton extends ConsumerWidget {
  const PrCtaButton({
    super.key,
    required this.status,
    required this.onInsertPrompt,
    required this.onRun,
  });

  final PrStatus status;
  final void Function(String prompt) onInsertPrompt;
  final void Function(PrRemedy remedy) onRun;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final cta = status.cta;
    final tone = prToneColor(cs, cta.tone);
    final remedy = cta.remedy;
    final direct = remedy is DirectRemedy;

    final (Color bg, Color fg, Color? border) = switch (cta) {
      PrCta(remedy: null) => (Colors.transparent, cs.onSurfaceVariant, cs.outlineVariant),
      _ when direct => (tone, _onDirect(cs, cta.tone), null),
      _ => (
        Color.alphaBlend(tone.withValues(alpha: 0.18), cs.surfaceContainerHigh),
        tone,
        null,
      ),
    };

    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      menuChildren: buildPrActionMenu(
        context,
        ref,
        status: status,
        onRun: onRun,
      ),
      builder: (context, controller, _) => _SplitButton(
        label: cta.label,
        icon: prRemedyIcon(remedy),
        background: bg,
        foreground: fg,
        border: border,
        menuOpen: controller.isOpen,
        // Idle has no verb to run, so its main segment opens the menu too —
        // otherwise it would be a button that does nothing.
        onAction: remedy == null
            ? () => controller.isOpen ? controller.close() : controller.open()
            : () => onRun(remedy),
        onToggleMenu: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  /// Readable foreground on a solid tone fill.
  static Color _onDirect(ColorScheme cs, PrTone tone) =>
      tone == PrTone.blocking ? cs.onError : cs.surface;
}

/// A compact labelled split button: a leading action segment (icon + label) and
/// a trailing caret segment that toggles the menu, separated by a hairline.
/// Mirrors the M3 split-button idiom already used by `open_in_ide.dart`.
class _SplitButton extends StatelessWidget {
  const _SplitButton({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.border,
    required this.menuOpen,
    required this.onAction,
    required this.onToggleMenu,
  });

  final String label;
  final IconGlyph icon;
  final Color background;
  final Color foreground;
  final Color? border;
  final bool menuOpen;
  final VoidCallback onAction;
  final VoidCallback onToggleMenu;

  static const double _height = 28;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadius8),
        side: border == null ? BorderSide.none : BorderSide(color: border!),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: label,
            child: InkWell(
              onTap: onAction,
              child: SizedBox(
                height: _height,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: kSpace12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      icon.build(size: 13, color: foreground),
                      const SizedBox(width: kSpace6),
                      Text(
                        label,
                        style: Theme.of(context).textTheme.labelXs?.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // A plain 1px box, not a VerticalDivider: that keeps the button out of
          // VerticalDivider type-finders used elsewhere (e.g. pane dividers).
          Container(
            width: 1,
            height: _height,
            color: foreground.withValues(alpha: 0.20),
          ),
          Tooltip(
            message: 'PR actions',
            child: InkWell(
              onTap: onToggleMenu,
              child: SizedBox(
                height: _height,
                width: _height,
                child: AnimatedRotation(
                  turns: menuOpen ? 0.5 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(
                    PhosphorIconsLight.caretDown,
                    size: 12,
                    color: foreground,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
