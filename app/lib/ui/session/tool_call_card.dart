import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../widgets/pulse_spinner.dart';
import 'chat_metrics.dart';
import 'elapsed.dart';
import 'live_now.dart';
import 'timing_labels.dart';
import 'tool_summary.dart';
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
    // Monochrome, matching `ThinkingLine`'s brain glyph. The `risky` tint was
    // dropped deliberately: both servers classify every edit/write/bash call as
    // risky (`pi-sessions.ts:259`, `acp-map.ts:540`), so the amber fired on
    // every row that was not a read and signalled nothing. `destructive` keeps
    // its tint precisely because it stays rare — see
    // `mockups/tool-one-liner.html` §7.
    final (riskColor, riskIcon) = switch (item.risk) {
      ToolRisk.destructive => (
        kToolDestructiveColor,
        renderer?.icon ?? PhosphorIconsLight.warningOctagon,
      ),
      ToolRisk.risky || ToolRisk.safe => (
        cs.onSurfaceVariant.withValues(alpha: kToolGlyphAlpha),
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
          padding: const EdgeInsets.symmetric(vertical: kSpace2),
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
      // Colour is spent only where it is exceptional: a failure keeps the error
      // hue, a resolved call drops to the glyph's own grey (§7).
      ToolStatus.failed => Icon(
        PhosphorIconsLight.warningCircle,
        size: kToolStatusGlyph,
        color: cs.error,
      ),
      ToolStatus.ok => Icon(
        PhosphorIconsLight.checkCircle,
        size: kToolStatusGlyph,
        color: cs.onSurfaceVariant.withValues(alpha: kToolGlyphAlpha),
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
        Icon(riskIcon, size: kToolGlyph, color: riskColor),
        const SizedBox(width: kSpace6),
        Expanded(child: _line(expanded: expanded)),
        const SizedBox(width: kSpace6),
        _durationSlot(),
        status,
        const SizedBox(width: kSpace6),
        caret,
      ],
    );
  }

  /// The row's text: `<verb> <payload>` in the transcript's own sans face and
  /// size (`bodyMedium`, exactly `ThinkingLine`'s), with the verb a weight
  /// heavier. Both parts share one colour at full opacity — dimming the payload
  /// to the thinking preview's 0.65 alpha would put the row's only content at
  /// 2.9:1 (below AA). See `mockups/tool-one-liner.html` §5.
  ///
  /// The line is the SAME in both states: expanding used to swap it for the bare
  /// verb, which meant the body had to open by re-printing the path or command
  /// you were just looking at, as a titled box. Keeping the subject in place is
  /// what lets those sections disappear — `mockups/tool-expanded-body.html` §3.
  Widget _line({required bool expanded}) {
    final cs = Theme.of(context).colorScheme;
    final item = widget.item;
    final base = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.3);
    final line = toolSummaryLine(item, root: _root());
    final parts = splitVerb(line, toolVerb(item));
    final text = Text.rich(
      TextSpan(
        children: [
          if (parts.verb.isNotEmpty)
            TextSpan(
              text: parts.verb,
              style: const TextStyle(fontWeight: kToolVerbWeight),
            ),
          if (parts.verb.isNotEmpty && parts.rest.isNotEmpty)
            const TextSpan(text: ' '),
          if (parts.rest.isNotEmpty) TextSpan(text: parts.rest),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: base,
    );
    // Collapsed shell rows list command *names*, so the arguments are only a
    // hover away (§4A). Expanded rows already show the command in the body.
    final hover = expanded ? null : toolTooltip(item);
    if (hover == null) return text;
    return Tooltip(
      message: hover,
      // Verbatim shell text: monospace, and never squeezed into one line.
      textStyle: Theme.of(
        context,
      ).textTheme.bodySmall?.mono.copyWith(color: cs.onInverseSurface),
      child: text,
    );
  }

  /// The trailing duration token, to the left of the status glyph (SPEC-session-timings
  /// D2/D6/D6a/D6b/D6c/D17). A finished (or turn-closed, D6a) row shows a static
  /// figure gated at [kToolDurationFloor]; a running row in a live session shows
  /// a live counter that escalates past 60 s. Empty otherwise (D19).
  Widget _durationSlot() {
    final item = widget.item;
    final cs = Theme.of(context).colorScheme;
    final baseStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: cs.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    final sessionRunning =
        widget.sessionId != null &&
        ref.watch(
              sessionsProvider.select((s) => s.byId(widget.sessionId!)?.status),
            ) ==
            SessionStatus.running;
    final closeTs = _enclosingTurnCloseTs();

    // A live counter watches the second-cadence ticker (D5), never PulseBuilder.
    if (item.endedTs == null && closeTs == null && sessionRunning) {
      final now = liveNowFor(ref, context);
      return ValueListenableBuilder<int>(
        valueListenable: now,
        builder: (context, nowMs, _) {
          final ms = elapsedMs(start: item.ts, end: nowMs);
          if (ms == null) return const SizedBox.shrink();
          final label = formatElapsed(ms);
          if (label == null) return const SizedBox.shrink();
          final hot = escalates(ms);
          return _reserved(
            Semantics(
              // D17: a live counter is never a live region; past 60 s the
              // escalation is spoken, not colour-only.
              liveRegion: false,
              label: hot ? 'running $label, taking longer than usual' : null,
              child: Text(
                label,
                style: baseStyle?.copyWith(color: hot ? kStatusWarning : null),
              ),
            ),
            baseStyle,
          );
        },
      );
    }

    // Static (finished, or frozen at the turn's close — D6a).
    final state = toolDurationState(
      item: item,
      enclosingTurnCloseTs: closeTs,
      serverNowMs: 0,
      sessionRunning: false,
    );
    final ms = state.ms;
    if (ms == null || !showsFinishedDuration(ms)) {
      return const SizedBox.shrink();
    }
    final label = formatElapsed(ms);
    if (label == null) return const SizedBox.shrink();
    return _reserved(
      Semantics(
        label: 'took $label',
        child: Text(label, style: baseStyle),
      ),
      baseStyle,
    );
  }

  /// Reserve the widest common duration width so a tick never re-ellipsizes the
  /// summary (D6b): an invisible sizer holds the slot, the value is right-aligned.
  Widget _reserved(Widget child, TextStyle? style) => Padding(
    padding: const EdgeInsets.only(right: kSpace8),
    child: Stack(
      alignment: Alignment.centerRight,
      children: [
        Opacity(opacity: 0, child: Text(kDurationWidthSample, style: style)),
        child,
      ],
    ),
  );

  /// The close `ts` of the completed turn enclosing this row, or null when no
  /// closed turn contains it (D6a). Used to freeze a no-end row's counter.
  int? _enclosingTurnCloseTs() {
    final id = widget.sessionId;
    if (id == null) return null;
    final turns = ref.watch(sessionTurnsProvider(id));
    for (final t in turns) {
      if (widget.item.seq >= t.openSeq && widget.item.seq <= t.closeSeq) {
        return t.closeTs;
      }
    }
    return null;
  }
}
