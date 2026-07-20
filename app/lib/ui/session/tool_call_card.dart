import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../store/models.dart';
import 'chat_metrics.dart';
import 'tool_renderers.dart';

/// Collapsed tool-call card. Tap → fullscreen drilldown (handled by caller).
class ToolCallCard extends StatelessWidget {
  const ToolCallCard({super.key, required this.item, required this.onTap});

  final ToolCallItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final renderer = rendererFor(item);
    final (riskColor, riskIcon) = switch (item.risk) {
      ToolRisk.risky => (
        kToolRiskyColor,
        renderer?.icon ?? PhosphorIconsLight.warning,
      ),
      ToolRisk.destructive => (
        kToolDestructiveColor,
        renderer?.icon ?? PhosphorIconsLight.warningOctagon,
      ),
      ToolRisk.safe => (cs.outline, renderer?.icon ?? PhosphorIconsLight.lightning),
    };

    final status = item.status;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.surfaceContainer,
          borderRadius: BorderRadius.circular(kChatRadiusMedium),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(riskIcon, size: 18, color: riskColor),
            const SizedBox(width: 10),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      toolDisplayName(item),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontFamily: 'monospace',
                        fontFamilyFallback: kMonoFallback,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  switch (status) {
                    ToolStatus.running => const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    ToolStatus.failed => Icon(
                      PhosphorIconsLight.warningCircle,
                      size: 14,
                      color: cs.error,
                    ),
                    ToolStatus.ok => Icon(
                      PhosphorIconsLight.checkCircle,
                      size: 14,
                      color: cs.primary,
                    ),
                  },
                ],
              ),
            ),
            const Icon(PhosphorIconsLight.caretRight),
          ],
        ),
      ),
    );
  }
}
