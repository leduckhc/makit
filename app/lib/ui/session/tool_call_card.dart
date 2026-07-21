import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../store/models.dart';
import 'chat_metrics.dart';
import 'tool_renderers.dart';

/// Inline, collapsible tool-call row. Mirrors `ThinkingLine`: collapsed it is a
/// single one-liner (tool icon + summary + status); tapping expands the tool's
/// [ToolRenderer.body] in place. Tapping the leading icon (when expanded)
/// collapses it again. Long bodies are capped at [kToolExpandedMaxHeight] and
/// scroll internally.
class ToolCallCard extends StatefulWidget {
  const ToolCallCard({super.key, required this.item});

  final ToolCallItem item;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final item = widget.item;
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
      ToolRisk.safe => (
        cs.onSurfaceVariant,
        renderer?.icon ?? PhosphorIconsLight.lightning,
      ),
    };

    final row = _buildRow(riskIcon, riskColor);
    if (!_expanded) return InkWell(onTap: _toggle, child: row);

    final body =
        renderer?.body(context, item) ?? genericToolBody(context, item);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row,
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: kToolExpandedMaxHeight),
          child: Scrollbar(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: body,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The collapsed one-liner: leading tool icon, summary text, trailing status.
  /// When expanded the leading icon becomes the collapse target.
  Widget _buildRow(IconData riskIcon, Color riskColor) {
    final cs = Theme.of(context).colorScheme;
    final item = widget.item;

    Widget leading = Icon(riskIcon, size: 16, color: riskColor);
    if (_expanded) {
      leading = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: leading,
      );
    }

    final status = switch (item.status) {
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
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        leading,
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            toolSummaryLine(item),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 13,
              fontFamily: 'monospace',
              fontFamilyFallback: kMonoFallback,
              height: 1.3,
            ),
          ),
        ),
        const SizedBox(width: 8),
        status,
      ],
    );
  }
}
