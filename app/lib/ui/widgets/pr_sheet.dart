import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import 'pr_actions.dart';
import 'pr_state_style.dart';
import 'sheet_header.dart';

/// Opens the PR detail sheet for [pr] — the mobile counterpart of the desktop
/// composer bar's hover popover (SPEC-23). Touch has no hover, so the per-check
/// list lives behind a tap instead.
///
/// [onInsertPrompt] wires up the PR *actions*: pass it from a surface that has a
/// composer to insert into (the session screen). Omit it and the sheet is
/// read-only, which is what the home screen wants — there is nowhere to put a
/// prompt there.
Future<void> showPrSheet(
  BuildContext context,
  PullRequest pr, {
  void Function(String prompt)? onInsertPrompt,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => SafeArea(
    child: PrSheetBody(pr: pr, onInsertPrompt: onInsertPrompt),
  ),
);

/// The body of the PR sheet: the PR's identity and state, the facts that decide
/// whether it can land (mergeability, unresolved review threads), the full CI
/// check list (failures first, [sortPrChecks]) and — when [onInsertPrompt] is
/// given — the canned PR actions.
class PrSheetBody extends ConsumerWidget {
  const PrSheetBody({super.key, required this.pr, this.onInsertPrompt});

  final PullRequest pr;

  /// Insert a resolved canned prompt into a composer. Null hides the actions.
  final void Function(String prompt)? onInsertPrompt;

  Future<void> _open(BuildContext context) async {
    if (pr.url.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(pr.url);
    try {
      if (uri == null) throw const FormatException('bad PR url');
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open the PR')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final style = prStateStyle(cs, pr);
    final isOpen = pr.state.toUpperCase() == 'OPEN';
    final checks = sortPrChecks(pr.checks);
    // Mergeability and review threads only matter while the PR can still land;
    // on a merged/closed PR they are history, not a next step.
    final conflicting = isOpen && pr.mergeable?.toUpperCase() == 'CONFLICTING';
    final unresolved = isOpen && !pr.unresolvedUnknown
        ? pr.unresolvedComments
        : 0;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: 'PR #${pr.number}'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    style.glyph.build(size: 16, color: style.color),
                    const SizedBox(width: kSpace6),
                    Text(
                      pr.state.toLowerCase(),
                      style: Theme.of(context).textTheme.labelXs?.copyWith(
                        color: style.textColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    // Draft is an open-PR state, so it drops off once the PR
                    // lands or is closed (mirrors the desktop pill).
                    if (isOpen && pr.isDraft) ...[
                      const SizedBox(width: kSpace8),
                      Text(
                        'draft',
                        style: Theme.of(
                          context,
                        ).textTheme.labelXs?.copyWith(color: cs.outline),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: kSpace6),
                Text(pr.title, style: Theme.of(context).textTheme.bodyMedium),
                if (conflicting || unresolved > 0) ...[
                  const SizedBox(height: kSpace10),
                  if (conflicting)
                    _Fact(
                      icon: PhosphorIconsLight.warning,
                      text: 'Conflicts with the base branch',
                      color: prCheckBucketColor(cs, 'fail'),
                    ),
                  if (unresolved > 0)
                    _Fact(
                      icon: PhosphorIconsLight.chatCircle,
                      text:
                          '$unresolved unresolved '
                          '${unresolved == 1 ? 'comment' : 'comments'}',
                      color: prCheckBucketColor(cs, 'pending'),
                    ),
                ],
                if (checks.isNotEmpty) ...[
                  const SizedBox(height: kSpace12),
                  for (final c in checks) PrCheckRow(check: c),
                ],
                if (onInsertPrompt != null) ...[
                  const SizedBox(height: kSpace12),
                  const Divider(height: 1),
                  const SizedBox(height: kSpace6),
                  Text(
                    'Ask the agent to…',
                    style: Theme.of(context).textTheme.labelXs?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  // "Create PR" is dropped: this sheet only opens for a PR that
                  // already exists (desktop filters it for the same reason).
                  // Selecting an action inserts its prompt and never sends — the
                  // user reviews it in the composer first.
                  for (final action in PrPromptAction.values)
                    if (action != PrPromptAction.createPr)
                      _ActionRow(
                        action: action,
                        onTap: () {
                          final prompt = ref.effectivePrPrompt(action);
                          Navigator.of(context).maybePop();
                          onInsertPrompt!(prompt);
                        },
                      ),
                ],
                if (pr.url.isNotEmpty) ...[
                  const SizedBox(height: kSpace12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _open(context),
                      icon: const Icon(
                        PhosphorIconsLight.arrowSquareOut,
                        size: 16,
                      ),
                      label: const Text('Open on GitHub'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One canned PR action in the sheet: glyph + label, full-width tap target.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.action, required this.onTap});

  final PrPromptAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: kSpace10),
        child: Row(
          children: [
            action.icon.build(size: 16, color: cs.primary),
            const SizedBox(width: kSpace10),
            Expanded(
              child: Text(
                action.label,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Icon(PhosphorIconsLight.arrowUpRight, size: 14, color: cs.outline),
          ],
        ),
      ),
    );
  }
}

/// One line of PR context: a tinted glyph plus a sentence.
class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: kSpace6),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

/// One CI check: a coloured status glyph, the workflow-qualified name, and the
/// human status word — the same three columns as the desktop popover.
class PrCheckRow extends StatelessWidget {
  const PrCheckRow({super.key, required this.check});

  final PrCheck check;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.bodySmall ?? const TextStyle();
    final color = prCheckBucketColor(cs, check.bucket);
    final workflow = check.workflowName;
    final label = workflow == null || workflow.isEmpty
        ? check.name
        : '$workflow / ${check.name}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(prCheckBucketIcon(check.bucket), size: 14, color: color),
          const SizedBox(width: kSpace6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: base.copyWith(color: cs.onSurface),
            ),
          ),
          const SizedBox(width: kSpace12),
          Text(
            prCheckBucketLabel(check.bucket),
            style: base.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
