import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import 'client_commands.dart';

/// Built-in client commands as `SlashCmd`s, fed into the palette so they
/// list alongside agent-provided commands.
List<SlashCmd> get _builtins =>
    clientCommands.map((c) => c.toSlashCmd()).toList();

class SlashPalette extends StatelessWidget {
  const SlashPalette({
    super.key,
    required this.filter,
    required this.commands,
    required this.onPick,
  });

  final String filter;
  final List<SlashCmd> commands;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    // Strip the leading '/' from the filter, lowercase for matching.
    final q = filter.startsWith('/')
        ? filter.substring(1).toLowerCase()
        : filter.toLowerCase();

    // Combine builtins + agent-provided commands, dedup by name, filter.
    final all = <SlashCmd>[..._builtins, ...commands];
    final seen = <String>{};
    final matches = <SlashCmd>[];
    for (final c in all) {
      if (seen.contains(c.name)) continue;
      seen.add(c.name);
      // Match if the query appears anywhere in name or description (fuzzy enough for v1).
      if (q.isEmpty ||
          c.name.toLowerCase().contains(q) ||
          c.description.toLowerCase().contains(q)) {
        matches.add(c);
      }
    }
    // Prefer prefix matches first, then containment, then alpha.
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

    if (matches.isEmpty) {
      return SizedBox(
        height: 60,
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Padding(
            padding: EdgeInsets.all(kSpace12),
            child: Text(
              'No matching commands. Skills appear once pi finishes loading.',
            ),
          ),
        ),
      );
    }

    return ConstrainedBox(
      // Cap the palette at half the viewport so it never overwhelms the chat
      // above the composer; the list shrink-wraps below that on short lists.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.5,
      ),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: matches.length,
          itemBuilder: (context, i) =>
              _CmdTile(cmd: matches[i], onPick: onPick),
        ),
      ),
    );
  }
}

class _CmdTile extends StatelessWidget {
  const _CmdTile({required this.cmd, required this.onPick});
  final SlashCmd cmd;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      onTap: () => onPick(cmd.invocation),
      leading: _SourceBadge(source: cmd.source),
      title: Row(
        children: [
          Flexible(
            child: Text(
              cmd.invocation,
              style: Theme.of(context).textTheme.bodyMedium?.mono,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (cmd.location != null) ...[
            const SizedBox(width: kSpace6),
            Text(
              cmd.location!,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: cs.outline),
            ),
          ],
        ],
      ),
      subtitle: cmd.description.isEmpty
          ? null
          : Text(cmd.description, maxLines: 2, overflow: TextOverflow.ellipsis),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source});
  final String source;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (label, color, icon) = switch (source) {
      'skill' => ('skill', cs.outline, PhosphorIconsLight.sparkle),
      'prompt' => ('prompt', cs.outline, PhosphorIconsLight.fileText),
      'extension' => ('ext', cs.outline, PhosphorIconsLight.puzzlePiece),
      'builtin' => ('app', cs.outline, PhosphorIconsLight.lightning),
      _ => (source, cs.outline, PhosphorIconsLight.terminalWindow),
    };
    return Tooltip(
      message: label,
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(kRadius6),
        ),
        child: Icon(icon, size: 16, color: color),
      ),
    );
  }
}
