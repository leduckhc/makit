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
    this.uncommittedFiles = 0,
  });

  /// The open PR for the pane's worktree, or null when there is none.
  final PullRequest? pr;

  /// Files with uncommitted changes in the pane's worktree (0 when none).
  final int uncommittedFiles;

  /// Insert a resolved canned prompt into the composer (does not send).
  final void Function(String prompt) onInsertPrompt;

  @override
  Widget build(BuildContext context) {
    final unresolved = pr?.unresolvedComments ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (pr != null) PrStatusPill(pr: pr!),
                if (uncommittedFiles > 0)
                  _CountLabel(
                    icon: PhosphorIconsLight.pencilSimple,
                    text: _plural(uncommittedFiles, 'uncommitted file'),
                    color: const Color(0xFFD29922),
                  ),
                if (unresolved > 0)
                  _CountLabel(
                    icon: PhosphorIconsLight.chatCircleText,
                    text: _plural(unresolved, 'unresolved comment'),
                    color: const Color(0xFFD29922),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          PrActionsSplitButton(
            onInsertPrompt: onInsertPrompt,
            hasPr: pr != null,
            unresolvedComments: unresolved,
            uncommittedFiles: uncommittedFiles,
          ),
        ],
      ),
    );
  }
}

/// `N thing` / `N things` — tiny English pluralizer for the count labels.
String _plural(int n, String singular) => '$n $singular${n == 1 ? '' : 's'}';

/// A compact tinted chip — icon + count text — used for the composer's
/// "X uncommitted files" / "X unresolved comments" hints beside the PR pill.
class _CountLabel extends StatelessWidget {
  const _CountLabel({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fill = Color.alphaBlend(color.withValues(alpha: 0.12), cs.surface);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
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

/// Sort rank for a check bucket: failures float to the top so the most obvious
/// issues are easiest to spot, then in-flight, then skipped, then passing.
int _bucketRank(String bucket) => switch (bucket) {
  'fail' || 'cancel' => 0,
  'pending' => 1,
  'skipping' => 2,
  'pass' => 3,
  _ => 4,
};

/// Human-readable status word for a check bucket (the third column).
String _bucketLabel(String bucket) => switch (bucket) {
  'pass' => 'passed',
  'fail' => 'failed',
  'cancel' => 'cancelled',
  'pending' => 'pending',
  'skipping' => 'skipped',
  _ => bucket,
};

/// Leading status glyph for a check bucket (the first column).
IconData _bucketIcon(String bucket) => switch (bucket) {
  'pass' => PhosphorIconsLight.checkCircle,
  'fail' || 'cancel' => PhosphorIconsLight.xCircle,
  'pending' => PhosphorIconsLight.clock,
  'skipping' => PhosphorIconsLight.minusCircle,
  _ => PhosphorIconsLight.circleDashed,
};

/// Checks sorted by [_bucketRank], stable within a bucket (preserves the
/// server's original order for ties).
List<PrCheck> _sortedChecks(List<PrCheck> checks) {
  final indexed = [for (var i = 0; i < checks.length; i++) (i, checks[i])];
  indexed.sort((a, b) {
    final byRank = _bucketRank(a.$2.bucket).compareTo(_bucketRank(b.$2.bucket));
    return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// The permanent PR pill: `PR #42` with a CI-verdict dot. Tapping opens the PR
/// on the web; hovering reveals the per-check status list ([_ChecksPopover]).
/// Tinted grey for a draft PR, else by its CI [PullRequest.checkRollup].
class PrStatusPill extends StatefulWidget {
  const PrStatusPill({super.key, required this.pr});

  final PullRequest pr;

  @override
  State<PrStatusPill> createState() => _PrStatusPillState();
}

class _PrStatusPillState extends State<PrStatusPill> {
  final _pillKey = GlobalKey();
  final _popover = OverlayPortalController();

  Future<void> _open() async {
    final url = widget.pr.url;
    if (url.isEmpty) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final pr = widget.pr;
    final cs = Theme.of(context).colorScheme;
    final color = pr.isDraft
        ? cs.outline
        : _rollupColor(context, pr.checkRollup);
    // Opaque tint: composite the verdict tint over the surface so the pill is
    // solid (not see-through over content behind it) while keeping the light
    // tinted look and legible same-colour foreground.
    final fill = Color.alphaBlend(color.withValues(alpha: 0.14), cs.surface);
    final pill = Material(
      color: fill,
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

    // Hover popover: the per-check status list (SPEC-23 bullet 3), rendered as a
    // light design-system surface anchored just above the pill. Display-only,
    // so it ignores pointer events and never blocks the pill's tap/hover.
    //
    // OverlayPortal hands its overlay child *tight* (full-screen) constraints,
    // so we anchor with an explicit `Positioned` (left + bottom) computed from
    // the pill's render box: that both places the card above the pill and lets
    // it shrink-wrap to its content instead of filling the window.
    return MouseRegion(
      onEnter: (_) => _popover.show(),
      onExit: (_) => _popover.hide(),
      child: OverlayPortal(
        controller: _popover,
        overlayChildBuilder: (context) {
          final pillBox = _pillKey.currentContext?.findRenderObject();
          final overlayBox = Overlay.of(context).context.findRenderObject();
          if (pillBox is! RenderBox ||
              overlayBox is! RenderBox ||
              !pillBox.hasSize) {
            return const SizedBox.shrink();
          }
          final topLeft = pillBox.localToGlobal(
            Offset.zero,
            ancestor: overlayBox,
          );
          return Positioned(
            left: topLeft.dx,
            bottom: overlayBox.size.height - topLeft.dy + 6,
            child: IgnorePointer(child: _ChecksPopover(pr: pr)),
          );
        },
        child: KeyedSubtree(key: _pillKey, child: pill),
      ),
    );
  }
}

/// The hover popover for [PrStatusPill]: a light, design-system surface listing
/// each CI check as three columns — `[status glyph] [name] [status]` — ordered
/// by [_bucketRank] so failures sit at the top.
class _ChecksPopover extends StatelessWidget {
  const _ChecksPopover({required this.pr});

  final PullRequest pr;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.bodySmall ?? const TextStyle();
    final checks = _sortedChecks(pr.checks);
    final header = checks.isEmpty
        ? (pr.url.isEmpty
              ? 'Open pull request'
              : 'No CI checks · click to open')
        : 'CI checks · click to open';
    return Material(
      color: cs.surfaceContainerHigh,
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  header,
                  style: base.copyWith(
                    fontSize: 11,
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (checks.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  for (final c in checks) _CheckRow(check: c),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One check line in [_ChecksPopover]: three columns — a coloured status glyph,
/// the (workflow-qualified) name, and the human status word.
class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.check});

  final PrCheck check;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.bodySmall ?? const TextStyle();
    final color = _bucketColor(context, check.bucket);
    final label = check.workflowName == null || check.workflowName!.isEmpty
        ? check.name
        : '${check.workflowName!} / ${check.name}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          Icon(_bucketIcon(check.bucket), size: 12, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: base.copyWith(fontSize: 11, color: cs.onSurface),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _bucketLabel(check.bucket),
            style: base.copyWith(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// The composer's "PR actions" split button (SPEC-23 bullet 4). The main
/// segment repeats the last-picked action; the caret opens a menu of all
/// actions. Selecting one inserts its (possibly overridden) prompt into the
/// composer via [onInsertPrompt] — it never auto-sends. Mirrors the M3
/// split-button idiom from `open_in_ide.dart`.
class PrActionsSplitButton extends ConsumerWidget {
  const PrActionsSplitButton({
    super.key,
    required this.onInsertPrompt,
    this.hasPr = false,
    this.unresolvedComments = 0,
    this.uncommittedFiles = 0,
  });

  final void Function(String prompt) onInsertPrompt;

  /// Whether the worktree already heads an open PR. When true, "Create PR" is
  /// dropped from the menu — there's nothing to create.
  final bool hasPr;

  /// Unresolved review threads on the PR (drives the contextual default).
  final int unresolvedComments;

  /// Uncommitted files in the worktree (drives the contextual default).
  final int uncommittedFiles;

  /// The actions offered in the menu, minus "Create PR" once a PR exists.
  List<PrPromptAction> get _actions => [
    for (final a in PrPromptAction.values)
      if (!(hasPr && a == PrPromptAction.createPr)) a,
  ];

  /// The main-segment (default) action: uncommitted work first, then unresolved
  /// comments, else the user's last pick (never a filtered-out action).
  PrPromptAction _defaultAction(WidgetRef ref) {
    if (uncommittedFiles > 0) return PrPromptAction.commitAndPush;
    if (unresolvedComments > 0) return PrPromptAction.resolveComments;
    final last = prActionFromName(ref.preference(lastPrActionPreference));
    return _actions.contains(last) ? last : _actions.first;
  }

  void _run(WidgetRef ref, PrPromptAction action) {
    ref
        .read(preferencesControllerProvider.notifier)
        .set(lastPrActionPreference, action.name);
    onInsertPrompt(ref.effectivePrPrompt(action));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final last = _defaultAction(ref);
    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        for (final action in _actions)
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
