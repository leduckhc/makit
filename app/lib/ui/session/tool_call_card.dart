import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../widgets/pulse_spinner.dart';
import 'chat_metrics.dart';
import 'transcript_expansion.dart';
import 'tool_renderers.dart';

/// Inline, collapsible tool-call row. Mirrors `ThinkingLine`: collapsed it is a
/// single one-liner (tool icon + summary + status + a trailing disclosure
/// caret shown on hover); tapping anywhere on the header toggles between the
/// collapsed one-liner and the expanded [ToolRenderer.body]. Long bodies are
/// capped at [kToolExpandedMaxHeight] and scroll internally.
class ToolCallCard extends ConsumerStatefulWidget {
  const ToolCallCard({
    super.key,
    required this.item,
    required this.expansionKey,
    this.sessionId,
  });

  final ToolCallItem item;

  /// Session this row belongs to — used to resolve the worktree path that
  /// absolute paths in the collapsed one-liner are shown relative to. Null in
  /// tests/previews that render a card standalone.
  final String? sessionId;

  /// This row's identity in [expandedTranscriptRowsProvider].
  final String expansionKey;

  @override
  ConsumerState<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends ConsumerState<ToolCallCard> {
  bool _hovered = false;
  final ScrollController _bodyScroll = ScrollController();

  // Whether this call is unfolded lives in [expandedTranscriptRowsProvider], not
  // here: the row is discarded whenever it leaves the lazy list's cache or the
  // pane is rebuilt, and an unfold must outlive that.
  void _toggle() => ref
      .read(expandedTranscriptRowsProvider.notifier)
      .toggle(widget.expansionKey);

  @override
  void dispose() {
    _bodyScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final item = widget.item;
    // `select` so folding one row doesn't rebuild every other tool row.
    final expanded = ref.watch(
      expandedTranscriptRowsProvider.select(
        (rows) => rows.contains(widget.expansionKey),
      ),
    );
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
      expanded: expanded,
      onTapHint: expanded ? 'Collapse tool call' : 'Expand tool call',
      child: InkWell(
        onTap: _toggle,
        onHover: (h) => setState(() => _hovered = h),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: kSpace6),
          child: _buildRow(riskIcon, riskColor, expanded: expanded),
        ),
      ),
    );

    if (!expanded) return header;

    final body =
        renderer?.body(context, item) ?? genericToolBody(context, item);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        const SizedBox(height: kSpace4),
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

  /// The session's worktree path, so `/Users/…/worktree/app/lib/x.dart`
  /// renders as `app/lib/x.dart`. Watched narrowly so an unrelated session
  /// update never rebuilds this row.
  String? _root() {
    final id = widget.sessionId;
    if (id == null) return null;
    return ref.watch(sessionsProvider.select((s) => s.byId(id)?.worktreePath));
  }

  /// The one-liner header: tool icon, summary text, status glyph, and a
  /// trailing rotating disclosure caret. The entire header is the tap target
  /// (built by the caller), so no child owns the gesture.
  Widget _buildRow(
    IconData riskIcon,
    Color riskColor, {
    required bool expanded,
  }) {
    final cs = Theme.of(context).colorScheme;
    final item = widget.item;

    final status = switch (item.status) {
      // PulseSpinner, not Material's: this one is visible for most of a turn,
      // and a vsync ticker here costs more than the whole card.
      // Labelled: the header's Semantics carries button/expanded, not status, so
      // this spinner is the only signal that the call is still in flight.
      ToolStatus.running => const PulseSpinner(
        size: 10,
        semanticsLabel: 'running',
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
    // collapsed and rotates down when expanded. Only visible on hover (its
    // space is reserved so the row never reflows).
    final caret = AnimatedOpacity(
      opacity: _hovered ? 1 : 0,
      duration: const Duration(milliseconds: 120),
      child: AnimatedRotation(
        turns: expanded ? 0.25 : 0,
        duration: const Duration(milliseconds: 150),
        child: Icon(
          PhosphorIconsLight.caretRight,
          size: 13,
          color: cs.onSurfaceVariant.withValues(alpha: 0.7),
        ),
      ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(riskIcon, size: 16, color: riskColor),
        const SizedBox(width: kSpace8),
        Expanded(
          child: Text(
            expanded ? toolLabel(item) : toolSummaryLine(item, root: _root()),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.mono.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.3,
            ),
          ),
        ),
        const SizedBox(width: kSpace8),
        status,
        const SizedBox(width: kSpace8),
        caret,
      ],
    );
  }
}
