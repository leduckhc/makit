import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../store/models.dart';
import '../settings/prefs/preference_entries.dart';
import '../settings/prefs/preferences_providers.dart';
import 'pr_actions.dart';

/// The row that sits directly above the docked composer (SPEC-23, desktop):
/// a permanent PR **status pill** (opens the PR on the web; hover shows the CI
/// check list) on the left, and a **PR actions** split button (canned prompts)
/// on the right. The pill renders only when [pr] is non-null; the actions
/// button always shows (its "Create PR" action is the path to *getting* a PR).
class PrComposerBar extends StatelessWidget {
  const PrComposerBar({
    super.key,
    required this.pr,
    required this.onInsertPrompt,
  });

  /// The open PR for the pane's worktree, or null when there is none.
  final PullRequest? pr;

  /// Insert a resolved canned prompt into the composer (does not send).
  final void Function(String prompt) onInsertPrompt;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      child: Row(
        children: [
          if (pr != null) PrStatusPill(pr: pr!),
          const Spacer(),
          PrActionsSplitButton(onInsertPrompt: onInsertPrompt),
        ],
      ),
    );
  }
}

/// Colour for a CI rollup verdict.
Color _rollupColor(BuildContext context, String rollup) {
  final cs = Theme.of(context).colorScheme;
  return switch (rollup) {
    'pass' => const Color(0xFF3FB950),
    'fail' => const Color(0xFFF85149),
    'pending' => const Color(0xFFD29922),
    _ => cs.outline,
  };
}

/// Colour for a single check bucket (shared by the hover list).
Color _bucketColor(BuildContext context, String bucket) {
  final cs = Theme.of(context).colorScheme;
  return switch (bucket) {
    'pass' => const Color(0xFF3FB950),
    'fail' || 'cancel' => const Color(0xFFF85149),
    'pending' => const Color(0xFFD29922),
    _ => cs.outline, // skipping / unknown
  };
}

/// The permanent PR pill: `PR #42` with a CI-verdict dot. Tapping opens the PR
/// on the web; hovering reveals the per-check status list. Tinted grey for a
/// draft PR, else by its CI [PullRequest.checkRollup].
class PrStatusPill extends StatelessWidget {
  const PrStatusPill({super.key, required this.pr});

  final PullRequest pr;

  Future<void> _open() async {
    if (pr.url.isEmpty) return;
    await launchUrl(Uri.parse(pr.url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = pr.isDraft
        ? cs.outline
        : _rollupColor(context, pr.checkRollup);
    final pill = Material(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _open,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(PhosphorIconsLight.gitPullRequest, size: 13, color: color),
              const SizedBox(width: 5),
              Text(
                'PR #${pr.number}',
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (pr.checks.isNotEmpty) ...[
                const SizedBox(width: 6),
                Icon(Icons.circle, size: 8, color: color),
              ],
              if (pr.isDraft) ...[
                const SizedBox(width: 6),
                Text('draft', style: TextStyle(color: color, fontSize: 11)),
              ],
            ],
          ),
        ),
      ),
    );

    // Hover popover: the per-check status list (SPEC-23 bullet 3). Built as a
    // rich tooltip so a coloured dot + name + bucket render per line without a
    // bespoke overlay. Falls back to a plain hint when there are no checks.
    return Tooltip(
      richMessage: _checksTooltip(context),
      waitDuration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: pill,
    );
  }

  InlineSpan _checksTooltip(BuildContext context) {
    final base = Theme.of(context).textTheme.bodySmall ?? const TextStyle();
    if (pr.checks.isEmpty) {
      return TextSpan(
        text: pr.url.isEmpty
            ? 'Open pull request'
            : 'No CI checks · click to open on the web',
        style: base,
      );
    }
    final spans = <InlineSpan>[
      TextSpan(
        text: 'CI checks · click to open\n',
        style: base.copyWith(fontWeight: FontWeight.w600),
      ),
    ];
    for (final c in pr.checks) {
      final label = c.workflowName == null || c.workflowName!.isEmpty
          ? c.name
          : '${c.workflowName!} / ${c.name}';
      spans.add(
        TextSpan(
          children: [
            TextSpan(
              text: '● ',
              style: base.copyWith(color: _bucketColor(context, c.bucket)),
            ),
            TextSpan(text: '$label — ${c.bucket}\n', style: base),
          ],
        ),
      );
    }
    return TextSpan(children: spans);
  }
}

/// The composer's "PR actions" split button (SPEC-23 bullet 4). The main
/// segment repeats the last-picked action; the caret opens a menu of all
/// actions. Selecting one inserts its (possibly overridden) prompt into the
/// composer via [onInsertPrompt] — it never auto-sends. Mirrors the M3
/// split-button idiom from `open_in_ide.dart`.
class PrActionsSplitButton extends ConsumerWidget {
  const PrActionsSplitButton({super.key, required this.onInsertPrompt});

  final void Function(String prompt) onInsertPrompt;

  void _run(WidgetRef ref, PrPromptAction action) {
    ref
        .read(preferencesControllerProvider.notifier)
        .set(lastPrActionPreference, action.name);
    onInsertPrompt(ref.effectivePrPrompt(action));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final last = prActionFromName(ref.preference(lastPrActionPreference));
    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        for (final action in PrPromptAction.values)
          MenuItemButton(
            leadingIcon: Icon(action.icon, size: 18),
            trailingIcon: action == last
                ? const Icon(PhosphorIconsLight.check, size: 16)
                : null,
            onPressed: () => _run(ref, action),
            child: Text(action.label),
          ),
      ],
      builder: (context, controller, _) => _SplitButton(
        label: last.label,
        icon: last.icon,
        menuOpen: controller.isOpen,
        onAction: () => _run(ref, last),
        onToggleMenu: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// A compact labelled M3 split button: a leading action segment (icon + label)
/// and a trailing caret segment that toggles the menu. Tonal `secondaryContainer`
/// fill, connected-shape radii, caret rotates while the menu is open.
class _SplitButton extends StatelessWidget {
  const _SplitButton({
    required this.label,
    required this.icon,
    required this.menuOpen,
    required this.onAction,
    required this.onToggleMenu,
  });

  final String label;
  final IconData icon;
  final bool menuOpen;
  final VoidCallback onAction;
  final VoidCallback onToggleMenu;

  static const double _height = 28;
  static const Radius _outer = Radius.circular(14);
  static const Radius _inner = Radius.circular(6);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final caretColor = menuOpen ? cs.secondary : cs.secondaryContainer;
    final caretFg = menuOpen ? cs.onSecondary : cs.onSecondaryContainer;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Action segment: icon + label runs the last-picked action.
        Tooltip(
          message: 'Insert "$label" prompt',
          child: Material(
            color: cs.secondaryContainer,
            borderRadius: const BorderRadius.horizontal(
              left: _outer,
              right: _inner,
            ),
            child: InkWell(
              onTap: onAction,
              borderRadius: const BorderRadius.horizontal(
                left: _outer,
                right: _inner,
              ),
              child: SizedBox(
                height: _height,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 15, color: cs.onSecondaryContainer),
                      const SizedBox(width: 6),
                      Text(
                        label,
                        style: TextStyle(
                          color: cs.onSecondaryContainer,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 2),
        // Caret segment: toggles the action menu.
        Tooltip(
          message: 'PR actions',
          child: Material(
            color: caretColor,
            borderRadius: const BorderRadius.horizontal(
              left: _inner,
              right: _outer,
            ),
            child: InkWell(
              onTap: onToggleMenu,
              borderRadius: const BorderRadius.horizontal(
                left: _inner,
                right: _outer,
              ),
              child: SizedBox(
                height: _height,
                width: _height,
                child: AnimatedRotation(
                  turns: menuOpen ? 0.5 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(
                    PhosphorIconsLight.caretDown,
                    size: 12,
                    color: caretFg,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
