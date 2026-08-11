/// The confirm sheet for switching the window to another profile (SPEC-50 D10).
///
/// Its shape is deliberate: the **"keeps running"** half is what makes the button
/// usable. Switching sounds like it might stop your work, and the honest answer
/// is that it does not — the profile you leave keeps its server up, its agents
/// running and its phones paired. Saying so removes the hesitation.
library;

import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../daemon/server_profile.dart';
import '../../chat/server_profile_badge.dart' show hueForProfileId;

/// Asks whether to switch from [from] to [to].
///
/// Returns true when the user confirms. [targetRunning] tailors the copy: if the
/// target's daemon is already up there is nothing to start, and promising to
/// start it would be a small lie.
Future<bool> confirmProfileSwitch(
  BuildContext context, {
  required ServerProfile from,
  required ServerProfile to,
  required bool targetRunning,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) =>
        _SwitchSheet(from: from, to: to, targetRunning: targetRunning),
  );
  return result ?? false;
}

class _SwitchSheet extends StatelessWidget {
  const _SwitchSheet({
    required this.from,
    required this.to,
    required this.targetRunning,
  });

  final ServerProfile from;
  final ServerProfile to;
  final bool targetRunning;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: hueForProfileId(to.id),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: kSpace8),
          Expanded(child: Text('Switch to “${to.name}”?')),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'This window will reconnect to ${to.name}’s server.',
                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: kSpace16),
              _Block(
                label: 'What happens here',
                tone: cs.error,
                lines: [
                  if (!targetRunning) '${to.name}’s server starts',
                  'this window reloads — panes and scroll reset',
                  'unsent composer drafts in this window are discarded',
                ],
              ),
              const SizedBox(height: kSpace12),
              _Block(
                label: 'What keeps running',
                tone: cs.primary,
                lines: [
                  '${from.name}’s server stays up',
                  '${from.name}’s agents are not interrupted',
                  'devices paired to ${from.name} stay paired',
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('Switch to ${to.name}'),
        ),
      ],
    );
  }
}

/// Asks whether to switch away from [victim] to [target] **and delete** [victim].
///
/// One sheet rather than two, because it is one intent. It has to carry both
/// consequences honestly: the window moves, and a profile's data is erased. The
/// “kept” line matters most — people read “delete” next to a path beside their
/// worktree as “deletes my branch”.
Future<bool> confirmSwitchAwayAndDelete(
  BuildContext context, {
  required ServerProfile victim,
  required ServerProfile target,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      final cs = Theme.of(context).colorScheme;
      final text = Theme.of(context).textTheme;
      return AlertDialog(
        title: Text('Delete “${victim.name}”?'),
        content: SizedBox(
          width: 430,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '“${victim.name}” is the profile this window is using, so the '
                  'window will switch to “${target.name}” first.',
                  style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: kSpace16),
                _Block(
                  label: 'What happens',
                  tone: cs.error,
                  lines: [
                    'this window switches to “${target.name}”',
                    '“${victim.name}” is stopped, then its server state is erased',
                    'its sessions, transcripts, pairings and TLS identity go',
                  ],
                ),
                const SizedBox(height: kSpace12),
                _Block(
                  label: 'What is kept',
                  tone: cs.primary,
                  lines: const [
                    'your worktrees and repos are never touched',
                    'every other profile is unaffected',
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: cs.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Switch & delete “${victim.name}”'),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

class _Block extends StatelessWidget {
  const _Block({required this.label, required this.tone, required this.lines});

  final String label;
  final Color tone;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: text.labelSmall?.copyWith(
            color: tone,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: kSpace6),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '· ',
                  style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                Expanded(
                  child: Text(
                    line,
                    style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
