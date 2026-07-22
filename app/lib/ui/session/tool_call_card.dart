import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../store/models.dart';
import 'chat_metrics.dart';
import 'tool_renderers.dart';

/// Inline, collapsible tool-call row. Mirrors `ThinkingLine`: collapsed it is a
/// single one-liner (tool icon + summary + status + a trailing disclosure
/// caret); tapping anywhere on the header toggles between the collapsed
/// one-liner and the expanded [ToolRenderer.body]. Long bodies are capped at
/// [kToolExpandedMaxHeight] and scroll internally.
class ToolCallCard extends StatefulWidget {
  const ToolCallCard({super.key, required this.item});

  final ToolCallItem item;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;
  final ScrollController _bodyScroll = ScrollController();

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  void dispose() {
    _bodyScroll.dispose();
    super.dispose();
  }

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

    // The whole header is a single toggle in both states (full-width tap
    // target); a rotating caret shows the expand/collapse affordance.
    final header = Semantics(
      button: true,
      expanded: _expanded,
      onTapHint: _expanded ? 'Collapse tool call' : 'Expand tool call',
      child: InkWell(
        onTap: _toggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: _buildRow(riskIcon, riskColor),
        ),
      ),
    );

    if (!_expanded) return header;

    final body =
        renderer?.body(context, item) ?? genericToolBody(context, item);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: kToolExpandedMaxHeight),
          child: Scrollbar(
            controller: _bodyScroll,
            child: SingleChildScrollView(
              controller: _bodyScroll,
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

  /// The one-liner header: tool icon, summary text, status glyph, and a
  /// trailing rotating disclosure caret. The entire header is the tap target
  /// (built by the caller), so no child owns the gesture.
  Widget _buildRow(IconData riskIcon, Color riskColor) {
    final cs = Theme.of(context).colorScheme;
    final item = widget.item;

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

    // Disclosure caret lives at the trailing (right) edge; points right when
    // collapsed and rotates down when expanded.
    final caret = AnimatedRotation(
      turns: _expanded ? 0.25 : 0,
      duration: const Duration(milliseconds: 150),
      child: Icon(
        PhosphorIconsLight.caretRight,
        size: 13,
        color: cs.onSurfaceVariant.withValues(alpha: 0.7),
      ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(riskIcon, size: 16, color: riskColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _expanded ? toolLabel(item) : toolSummaryLine(item),
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
        const SizedBox(width: 8),
        caret,
      ],
    );
  }
}
