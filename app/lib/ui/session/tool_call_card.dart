import 'package:flutter/material.dart';

import '../../store/models.dart';
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
    final risk = item.risk;
    final (riskColor, riskIcon) = switch (risk) {
      'risky' => (Colors.orange, renderer?.icon ?? Icons.warning_amber_rounded),
      'destructive' => (Colors.red, renderer?.icon ?? Icons.dangerous_outlined),
      _ => (cs.outline, renderer?.icon ?? Icons.bolt_outlined),
    };

    final running = !item.ended;
    final failed = item.ended && (item.exitCode ?? 0) != 0;

    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
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
                  if (running)
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (failed)
                    Icon(Icons.error_outline, size: 14, color: cs.error)
                  else
                    Icon(
                      Icons.check_circle_outline,
                      size: 14,
                      color: cs.primary,
                    ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}
