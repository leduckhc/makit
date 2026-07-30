import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';

/// A selectable harness card (icon, label, transport). Selected cards get an
/// accent ring + check; unavailable agents are dimmed and non-tappable. Reused
/// by the New-session sheet's harness grid and by [WorktreeStarter] (the
/// in-pane start surface for SPEC-30).
class HarnessCard extends StatelessWidget {
  const HarnessCard({
    super.key,
    required this.agent,
    required this.selected,
    this.onTap,
  });

  final AgentDescriptor agent;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return SizedBox(
      width: 168,
      child: Card(
        margin: EdgeInsets.zero,
        color: selected ? cs.primaryContainer : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadius12),
          side: BorderSide(
            color: selected ? cs.primary : cs.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadius12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      PhosphorIconsLight.robot,
                      size: 20,
                      color: agent.available ? cs.onSurface : cs.outline,
                    ),
                    const Spacer(),
                    if (selected)
                      Icon(
                        PhosphorIconsFill.checkCircle,
                        size: 18,
                        color: cs.primary,
                      ),
                  ],
                ),
                const SizedBox(height: kSpace8),
                Text(
                  agent.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: kSpace2),
                Text(
                  agent.available ? agent.transport : 'unavailable',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
