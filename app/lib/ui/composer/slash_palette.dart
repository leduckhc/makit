import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import 'client_commands.dart';

/// Height of one palette row. Fixed so the list can be laid out with an
/// `itemExtent` and the highlighted row scrolled into view by arithmetic
/// instead of a per-row `GlobalKey`.
const double kSlashRowHeight = 52;

/// Tallest the palette may ever get: five rows plus its own padding. It floats
/// over the transcript, so it stays small enough to read the message it is
/// being typed into; the caller clamps this further to the free space actually
/// available above the composer.
const double kSlashPaletteMaxHeight = kSlashRowHeight * 5 + kSpace8 * 2;

/// Key on the currently highlighted row, so keyboard navigation is observable
/// from tests without exposing the palette's internals.
const Key kSlashSelectedRowKey = Key('slash-selected-row');

/// Built-in client commands as `SlashCmd`s, listed alongside agent-provided
/// ones.
List<SlashCmd> get _builtins =>
    clientCommands.map((c) => c.toSlashCmd()).toList();

/// The commands matching [filter] (with or without its leading `/`), builtins
/// first-class alongside [commands], deduped by name and ordered
/// prefix-match → containment → alphabetical.
///
/// Pure, and the single source of truth for what the palette shows: the
/// composer needs the same list to move its highlight, and two independently
/// computed orderings would let Tab pick a different command than the one
/// under the highlight.
List<SlashCmd> filterSlashCommands(String filter, List<SlashCmd> commands) {
  final q = filter.startsWith('/')
      ? filter.substring(1).toLowerCase()
      : filter.toLowerCase();

  final seen = <String>{};
  final matches = <SlashCmd>[];
  for (final c in [..._builtins, ...commands]) {
    if (!seen.add(c.name)) continue;
    if (q.isEmpty ||
        c.name.toLowerCase().contains(q) ||
        c.description.toLowerCase().contains(q)) {
      matches.add(c);
    }
  }
  matches.sort((a, b) {
    int score(SlashCmd c) {
      final n = c.name.toLowerCase();
      if (q.isEmpty) return 2;
      if (n.startsWith(q)) return 0;
      if (n.contains(q)) return 1;
      return 2;
    }

    final s = score(a).compareTo(score(b));
    return s != 0 ? s : a.name.compareTo(b.name);
  });
  return matches;
}

/// The floating command popover shown while a `/…` is being typed.
///
/// Presentation only: [matches] and [selectedIndex] are owned by the composer
/// (which drives them from the keyboard), and the palette just paints them and
/// keeps the highlighted row scrolled into view.
class SlashPalette extends StatefulWidget {
  const SlashPalette({
    super.key,
    required this.matches,
    required this.selectedIndex,
    required this.onPick,
    this.maxHeight = kSlashPaletteMaxHeight,
  });

  /// Rows to show, best match first. Empty renders the "no matches" hint.
  final List<SlashCmd> matches;

  /// Index of the highlighted row in [matches].
  final int selectedIndex;

  /// Called with a command's invocation (`/name`) when a row is chosen.
  final ValueChanged<String> onPick;

  /// Hard cap on the popover's height, clamped by the caller to the space free
  /// above the composer so the first row is never pushed off-screen.
  final double maxHeight;

  @override
  State<SlashPalette> createState() => _SlashPaletteState();
}

class _SlashPaletteState extends State<SlashPalette> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(SlashPalette old) {
    super.didUpdateWidget(old);
    if (old.selectedIndex != widget.selectedIndex) _revealSelected();
  }

  /// Scrolls the highlighted row just into view, by the minimum amount.
  void _revealSelected() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final top = widget.selectedIndex * kSlashRowHeight;
    final bottom = top + kSlashRowHeight;
    final double target;
    if (top < pos.pixels) {
      target = top;
    } else if (bottom > pos.pixels + pos.viewportDimension) {
      target = bottom - pos.viewportDimension;
    } else {
      return; // already visible
    }
    _scroll.jumpTo(target.clamp(pos.minScrollExtent, pos.maxScrollExtent));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _Card(
      child: widget.matches.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: kSpace12,
                vertical: kSpace12,
              ),
              child: Text(
                'No matching commands — skills appear once the agent finishes '
                'loading.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            )
          : ConstrainedBox(
              constraints: BoxConstraints(maxHeight: widget.maxHeight),
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(vertical: kSpace8),
                shrinkWrap: true,
                itemExtent: kSlashRowHeight,
                itemCount: widget.matches.length,
                itemBuilder: (context, i) => _CmdRow(
                  key: i == widget.selectedIndex ? kSlashSelectedRowKey : null,
                  cmd: widget.matches[i],
                  selected: i == widget.selectedIndex,
                  onPick: widget.onPick,
                ),
              ),
            ),
    );
  }
}

/// The popover shell: a raised neutral card with a hairline and a soft shadow,
/// on the design system's card radius. Not glass — DESIGN.md reserves glass for
/// the top bar and the composer itself, and a translucent list over a
/// transcript is unreadable.
class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kSpace8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(kRadius16),
          border: Border.all(color: cs.outlineVariant),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kRadius16),
          child: Material(color: Colors.transparent, child: child),
        ),
      ),
    );
  }
}

class _CmdRow extends StatelessWidget {
  const _CmdRow({
    super.key,
    required this.cmd,
    required this.selected,
    required this.onPick,
  });

  final SlashCmd cmd;
  final bool selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kSpace6, vertical: 1),
      child: Material(
        color: selected ? cs.primary.withValues(alpha: 0.12) : null,
        borderRadius: BorderRadius.circular(kRadius10),
        child: InkWell(
          onTap: () => onPick(cmd.invocation),
          borderRadius: BorderRadius.circular(kRadius10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: kSpace8),
            child: Row(
              children: [
                _SourceBadge(source: cmd.source, selected: selected),
                const SizedBox(width: kSpace8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              cmd.invocation,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.mono.copyWith(
                                fontWeight: FontWeight.w600,
                                color: selected ? cs.primary : cs.onSurface,
                              ),
                            ),
                          ),
                          if (cmd.location != null) ...[
                            const SizedBox(width: kSpace6),
                            Text(
                              cmd.location!,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: cs.outline,
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (cmd.description.isNotEmpty)
                        Text(
                          cmd.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                    ],
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

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source, required this.selected});
  final String source;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (label, icon) = switch (source) {
      'skill' => ('skill', PhosphorIconsLight.sparkle),
      'prompt' => ('prompt', PhosphorIconsLight.fileText),
      'extension' => ('ext', PhosphorIconsLight.puzzlePiece),
      'builtin' => ('app', PhosphorIconsLight.lightning),
      _ => (source, PhosphorIconsLight.terminalWindow),
    };
    final color = selected ? cs.primary : cs.outline;
    return Tooltip(
      message: label,
      child: Container(
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(kRadius6),
        ),
        child: Icon(icon, size: 14, color: color),
      ),
    );
  }
}
