/// Queued-message chips (SPEC-35) — the strip above the composer field showing
/// what you typed while the agent was busy and could not be steered.
///
/// One chip per pending message, oldest first: the text (single line, elided),
/// an optional attachment count, and a `✕` that cancels it. Unlike an
/// attachment chip these carry no upload state — the message is either still
/// pending or already gone from the queue.
library;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';

/// Vertical stack of [QueuedChip]s, oldest first.
class QueuedChips extends StatelessWidget {
  const QueuedChips({super.key, required this.queued, required this.onCancel});

  final List<QueuedMessage> queued;
  final ValueChanged<String> onCancel;

  @override
  Widget build(BuildContext context) {
    if (queued.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(
        left: kSpace8,
        right: kSpace8,
        bottom: kSpace4,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final q in queued)
            QueuedChip(
              // Keyed by the server-assigned id so element reuse cannot pair a
              // chip with a different message as the queue drains.
              key: ValueKey(q.id),
              message: q,
              onCancel: () => onCancel(q.id),
            ),
        ],
      ),
    );
  }
}

/// One pending message.
class QueuedChip extends StatelessWidget {
  const QueuedChip({
    super.key,
    required this.message,
    required this.onCancel,
  });

  final QueuedMessage message;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final count = message.attachmentCount ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: kSpace4),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainer,
          borderRadius: BorderRadius.circular(kRadius12),
        ),
        padding: const EdgeInsets.only(left: kSpace8),
        child: Row(
          children: [
            Tooltip(
              message: 'Waiting for the agent to finish',
              child: Icon(
                PhosphorIconsLight.clock,
                size: 14,
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: kSpace8),
            Expanded(
              child: Text(
                message.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: kSpace4),
              Icon(
                PhosphorIconsLight.paperclip,
                size: 12,
                color: cs.onSurfaceVariant,
              ),
              Text(
                '$count',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
            IconButton(
              onPressed: onCancel,
              tooltip: 'Cancel this message',
              visualDensity: VisualDensity.compact,
              iconSize: 14,
              icon: Icon(PhosphorIconsLight.x, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
