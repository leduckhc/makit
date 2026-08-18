/// Shared chat-transcript rendering used by BOTH the mobile [SessionScreen]
/// and the desktop `DesktopChatPane`, so the two surfaces render an identical
/// item set by construction rather than by two hand-kept-in-sync switches.
///
/// [chatItemWidget] maps a [ChatItem] to its widget. All rows are
/// gutter-agnostic: horizontal insets + inter-row spacing are owned by the
/// surface via [transcriptRow] (see chat_metrics.dart), so the mobile
/// [SessionScreen] and desktop `DesktopChatPane` align identically by
/// construction.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../../store/turns.dart';
import '../widgets/glass.dart';
import '../widgets/pulse.dart';
import 'ask_card.dart';
import 'chat_message.dart';
import 'chat_metrics.dart';
import 'elapsed.dart';
import 'live_now.dart';
import 'navigator/jump_flash.dart';
import 'media_view.dart';
import 'tool_call_card.dart';
import 'transcript_expansion.dart';
import 'turn_receipt.dart';

/// Distance (logical px) from the newest message within which an incoming item
/// re-pins the transcript to the bottom. Beyond it, the user is treated as
/// reading history and is left untouched.
const double kAnchorNearBottomPx = 120.0;

/// Pins a reversed (`reverse: true`) transcript back to the newest message
/// (scroll offset `0`) after a new item arrives — but only when the user is
/// already near the bottom, so scrolling up to read history is never yanked
/// away. Shared by the mobile [SessionScreen] and desktop `DesktopChatPane` so
/// both surfaces anchor identically. Uses `jumpTo` (not `animateTo`) for a
/// deterministic snap that never stacks animations during fast token streams.
void anchorToNewestIfNearBottom(ScrollController scroll) {
  final nearBottom =
      !scroll.hasClients || scroll.position.pixels <= kAnchorNearBottomPx;
  if (!nearBottom) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (scroll.hasClients) scroll.jumpTo(0);
  });
}

/// Glass "jump to newest" affordance shown above the composer once the newest
/// message has scrolled off (i.e. the transcript stopped following the tail past
/// [kAnchorNearBottomPx]). Tapping it *jumps* — no long scroll animation through
/// a history that may be thousands of rows.
///
/// Sized like the composer's send button (36pt circle, 18pt glyph) and tinted
/// lighter than the bars so the transcript stays readable behind it.
class JumpToNewestButton extends StatelessWidget {
  /// Creates the affordance for the transcript driven by [scroll].
  const JumpToNewestButton({super.key, required this.scroll});

  /// The transcript controller (a `reverse: true` list: newest is offset 0).
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: scroll,
      builder: (context, _) {
        final visible =
            scroll.hasClients &&
            scroll.position.hasPixels &&
            scroll.position.pixels > kAnchorNearBottomPx;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          // Hidden state builds no glass at all (the shader is not free).
          child: visible
              ? GlassSurface(
                  key: const ValueKey('jump-to-newest'),
                  borderRadius: 18,
                  tint: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0x40181818)
                      : const Color(0x40FFFFFF),
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: IconButton(
                      tooltip: 'Jump to newest',
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      icon: const Icon(PhosphorIconsLight.arrowDown),
                      onPressed: () => scroll.jumpTo(0),
                    ),
                  ),
                )
              : const SizedBox.shrink(key: ValueKey('jump-to-newest-hidden')),
        );
      },
    );
  }
}

/// Maps a folded [ChatItem] to its transcript widget. Tool calls render as
/// inline collapsible rows (see [ToolCallCard]) that expand in place — there is
/// no full-screen detail navigation. Horizontal gutter + inter-row spacing are
/// applied by the caller via [transcriptRow], so the item widgets carry none
/// themselves.
Widget chatItemWidget(
  String sessionId,
  ChatItem item, {
  int position = -1,
}) => switch (item) {
  // SPEC-message-navigator: a pass-through unless active — the landing highlight after a jump.
  UserMessageItem() => JumpFlashHighlight(
    sessionId: sessionId,
    position: position,
    child: ChatBubble.user(
      text: item.text,
      ts: item.ts,
      attachments: item.attachments,
      // SPEC-mid-turn-steering-and-queue: captions a message that went into the running turn.
      steered: item.steered,
    ),
  ),
  AgentMessageItem() => AgentMessage(text: item.text, ts: item.ts),
  // SPEC-session-timings D9: the dim line that closes a turn. Static text derived from
  // timestamps, so it renders identically in a closed transcript (D19).
  TurnReceiptItem() => TurnReceipt(item: item),
  // An image/GIF the agent produced (SPEC-assistant-display-media) — the one thing a terminal
  // client can't show. Rendered inline, tap for fullscreen.
  AgentMediaItem() => AgentMediaView(item: item),
  ThinkingItem() => ThinkingLine(
    text: item.text,
    expansionKey: transcriptRowExpansionKey(sessionId, item),
    startTs: item.ts,
    lastTs: item.lastTs,
    streaming: item.streaming,
  ),
  // An answered askUserQuestion settles into a quiet resolved card (chosen
  // highlighted, rest dimmed) rather than a foldable tool row (SPEC-ask-user-inline-in-chat #1).
  ToolCallItem() when _isAnsweredAsk(item) => AnsweredAskCard(item: item),
  ToolCallItem() => ToolCallCard(
    item: item,
    sessionId: sessionId,
    expansionKey: transcriptRowExpansionKey(sessionId, item),
  ),
  ErrorItem() => ErrorBanner(message: item.message),
};

/// A persisted, answered ask-user tool call. Matches pi's `ask_user` and the
/// `askUserQuestion` variants other adapters use (underscore/case-insensitive).
bool _isAnsweredAsk(ToolCallItem item) {
  if (!item.ended) return false;
  final n = item.name.toLowerCase().replaceAll('_', '');
  return n == 'askuser' || n == 'askuserquestion';
}

/// Stable identity for a chat item's transcript row. Applied by each surface at
/// the **ListView child level** (via `KeyedSubtree`) so stateful rows
/// ([ToolCallCard], [ThinkingLine]) keep their expand/collapse state when the
/// reversed list reorders as new items stream in — otherwise Flutter would
/// reconcile the unkeyed rows by position and migrate/reset state to the wrong
/// item.
Key chatItemKey(ChatItem item) => switch (item) {
  ToolCallItem() => ValueKey('tool-${item.callId}'),
  _ => ValueKey('seq-${item.seq}'),
};

/// Maps a transcript row's [chatItemKey] back to its index in the reversed
/// list, for the surfaces' `findChildIndexCallback`.
///
/// Without it a lazy list reconciles its built children **by index**: every new
/// item shifts each older row down one slot, the key at that slot no longer
/// matches, and Flutter throws the row away and inflates a fresh one. Every row
/// on screen therefore loses its state (an unfolded tool re-folds) and its
/// measured extent on *every* streamed item. With this callback the sliver
/// finds each existing child at its new index and keeps it — state, keep-alive
/// and layout offset included.
///
/// Returns a closure per build; the key→index map is built lazily on first use
/// (only frames that actually move rows pay for it) and is valid for the
/// [items] list it was made from.
int? Function(Key) transcriptChildIndexFinder(
  List<ChatItem> items, {
  required bool hasTrailer,
}) {
  Map<Key, int>? byKey;
  return (key) {
    // Reversed list: item at position p renders at index length-1-p, shifted by
    // the trailing row (which always occupies index 0) when present.
    byKey ??= {
      for (var p = 0; p < items.length; p++)
        chatItemKey(items[p]): items.length - 1 - p + (hasTrailer ? 1 : 0),
    };
    return byKey![key];
  };
}

/// The trailing transcript row shown below the newest message. An awaiting
/// inline ask takes priority over the working indicator: Pi stays `running`
/// while it emits an `askUserQuestion`, so both can be true at once — showing
/// the working indicator then would hide the question and (with the composer
/// paused) deadlock the user. Prefer the ask.
enum TranscriptTrailer { none, working, ask }

TranscriptTrailer trailerFor({required bool running, required bool awaiting}) =>
    awaiting
    ? TranscriptTrailer.ask
    : (running ? TranscriptTrailer.working : TranscriptTrailer.none);

/// The trailing row's content, shared by both surfaces (SPEC-pending-queue-edit-reorder).
///
/// Beyond the ask card / working indicator it also hosts the **inline** pending
/// queue, which is why the queue needs no synthetic entries in [foldEvents]: the
/// trailer is already a non-event row that SPEC-chat-scroll-anchoring's anchoring and SPEC-message-navigator's
/// key→index map both account for.
///
/// Order is deliberate — pending messages sit ABOVE the ask/working row, so the

/// Reasoning/thinking trace. Folded to a single greyed one-liner with an
/// ellipsis; a tap toggles between the full (selectable) text and the
/// one-liner. When expanded, tapping the leading icon collapses it again.
///
/// The unfolded flag lives in [expandedTranscriptRowsProvider] rather than in
/// this widget, so it survives the row being rebuilt or scrolled out of the lazy
/// list's cache — which is also why the row needs no keep-alive.
class ThinkingLine extends ConsumerWidget {
  /// Creates a reasoning line showing [text], folded under [expansionKey].
  const ThinkingLine({
    super.key,
    required this.text,
    required this.expansionKey,
    this.startTs,
    this.lastTs,
    this.streaming = false,
  });

  /// The reasoning text (trimmed for display).
  final String text;

  /// This row's identity in [expandedTranscriptRowsProvider].
  final String expansionKey;

  /// When reasoning started (SPEC-session-timings D7), or null when unknown (previews/tests
  /// that render a bare line). With [lastTs]/[streaming] it drives the leading
  /// `Thought for 12s` / `Thinking … 41s` label.
  final int? startTs;

  /// When reasoning last advanced (the final `agent.thinking` or latest delta).
  final int? lastTs;

  /// True while reasoning tokens are still streaming in.
  final bool streaming;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `select` so folding one row doesn't rebuild every other reasoning row.
    final expanded = ref.watch(
      expandedTranscriptRowsProvider.select(
        (rows) => rows.contains(expansionKey),
      ),
    );
    final cs = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: cs.onSurfaceVariant.withValues(alpha: 0.65),
      fontStyle: FontStyle.italic,
      height: 1.3,
    );
    void toggle() =>
        ref.read(expandedTranscriptRowsProvider.notifier).toggle(expansionKey);
    final textWidget = expanded
        ? SelectableText(text.trim(), style: style, onTap: toggle)
        : Text(
            text.trim(),
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
    // Expanded: SelectableText handles taps on the text for selection; a tap
    // on the leading icon collapses. Collapsed: whole row is a tap target that
    // expands.
    return expanded
        ? Semantics(
            onTap: toggle,
            onTapHint: 'Collapse thinking',
            child: _buildRow(
              context,
              textWidget,
              onLeadingTap: toggle,
              durationLabel: _durationLabel(context, ref),
              expanded: true,
            ),
          )
        : InkWell(
            onTap: toggle,
            child: _buildRow(
              context,
              textWidget,
              durationLabel: _durationLabel(context, ref),
            ),
          );
  }

  Widget _buildRow(
    BuildContext context,
    Widget textWidget, {
    VoidCallback? onLeadingTap,
    Widget? durationLabel,
    bool expanded = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    // Size and alpha come from the shared row tokens, not literals: the tool row
    // was asked to match this glyph exactly, and one constant is the only way
    // that survives a future tweak to either row.
    Widget leading = Icon(
      PhosphorIconsLight.brain,
      size: kToolGlyph,
      color: cs.onSurfaceVariant.withValues(alpha: kToolGlyphAlpha),
    );
    if (onLeadingTap != null) {
      leading = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onLeadingTap,
        child: leading,
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        leading,
        const SizedBox(width: kSpace6),
        // Folded, the label and the one-line preview share the row: the
        // duration leads (D7) and the preview trails it, ellipsised.
        //
        // Unfolded, the reasoning is a paragraph, not a trailing fragment.
        // Keeping it on the label's line would indent every wrapped line around
        // a word that only belongs to the first one and cost the paragraph the
        // label's width, so the label takes its own line and the text starts
        // fresh beneath it — flush left with the label, under the icon's gutter.
        if (durationLabel != null && expanded)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                durationLabel,
                const SizedBox(height: kSpace2),
                textWidget,
              ],
            ),
          )
        else ...[
          if (durationLabel != null) ...[
            durationLabel,
            const SizedBox(width: kSpace6),
          ],
          Expanded(child: textWidget),
        ],
      ],
    );
  }

  /// The leading `Thought for 12s` / `Thinking … 41s` label (SPEC-session-timings D7). Always
  /// shown (min `1s`), and — unlike the preview text — in `onSurfaceVariant` at
  /// FULL opacity, never the pre-existing 0.65 alpha that fails AA (D9b).
  Widget? _durationLabel(BuildContext context, WidgetRef ref) {
    final start = startTs;
    if (start == null) return null;
    final cs = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: cs.onSurfaceVariant,
      fontStyle: FontStyle.italic,
      height: 1.3,
    );

    if (streaming) {
      final now = liveNowFor(ref, context);
      return ValueListenableBuilder<int>(
        valueListenable: now,
        builder: (context, nowMs, _) {
          final label = _spanLabel(start, nowMs);
          return label == null
              ? const SizedBox.shrink()
              : Text('Thinking … $label', style: style);
        },
      );
    }
    final label = _spanLabel(start, lastTs);
    return label == null ? null : Text('Thought for $label', style: style);
  }

  /// The span label from [start] to [end], min `1s` (D7/D14), or null when the
  /// span is unrepresentable (D10b).
  String? _spanLabel(int start, int? end) {
    final ms = elapsedMs(start: start, end: end);
    if (ms == null) return null;
    return formatElapsed(ms < 1000 ? 1000 : ms);
  }
}

/// Inline error banner shown for an [ErrorItem]: a leading warning icon +
/// message on a rounded error-container card. Gutter + spacing come from the
/// surface ([transcriptRow]).
class ErrorBanner extends StatelessWidget {
  /// Creates an error banner for [message].
  const ErrorBanner({super.key, required this.message});

  /// The error text.
  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(kSpace12),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(kChatRadiusMedium),
      ),
      child: Row(
        children: [
          Icon(
            PhosphorIconsLight.warningCircle,
            size: 18,
            color: cs.onErrorContainer,
          ),
          const SizedBox(width: kSpace8),
          Expanded(
            child: Text(message, style: TextStyle(color: cs.onErrorContainer)),
          ),
        ],
      ),
    );
  }
}

/// Trailing "working" indicator shown at the tail of the transcript while the
/// session is running: a shimmering work-flavoured word. Shared by mobile and
/// desktop so both surfaces show the same treatment. Gutter + spacing come from
/// the surface ([transcriptRow]).
class WorkingIndicator extends ConsumerStatefulWidget {
  /// Creates the indicator. When [sessionId] is set, a live turn counter is
  /// shown beside the word (SPEC-session-timings D8).
  const WorkingIndicator({super.key, this.sessionId});

  /// The running session, so the counter can read its open turn's start.
  final String? sessionId;

  @override
  ConsumerState<WorkingIndicator> createState() => _WorkingIndicatorState();
}

class _WorkingIndicatorState extends ConsumerState<WorkingIndicator> {
  static const _words = [
    'Thinking',
    'Cooking',
    'Pondering',
    'Crunching',
    'Conjuring',
    'Reasoning',
    'Tinkering',
    'Brewing',
    'Computing',
    'Noodling',
    'Scheming',
    'Percolating',
    'Wrangling',
    'Analyzing',
    'Plotting',
    'Untangling',
  ];

  late final String _word = _words[Random().nextInt(_words.length)];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = cs.onSurfaceVariant.withValues(alpha: 0.18);
    final highlight = cs.onSurface;
    // Built once and closed over, so the sweep never re-lays-out the word.
    final word = Text(
      _word,
      style: Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(fontStyle: FontStyle.italic),
    );
    // The sweep runs on the shared low-rate clock, so the ShaderMask's
    // saveLayer is paid ~20 times a second instead of at every vsync.
    final shimmer = PulseBuilder(
      period: const Duration(milliseconds: 1400),
      reverse: false,
      builder: (context, t) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) => LinearGradient(
          colors: [base, highlight, base],
          stops: const [0.35, 0.5, 0.65],
          transform: _SlideGradient(t),
        ).createShader(bounds),
        child: word,
      ),
    );

    final counter = _turnCounter(context, cs);
    if (counter == null) return shimmer;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        shimmer,
        const SizedBox(width: kSpace6),
        counter,
      ],
    );
  }

  /// The live turn counter (SPEC-session-timings D8): `47s` beside the word, off the shared
  /// second-cadence ticker (D5). No 60 s escalation — a long turn is normal (D6).
  /// Null when there is no session or no open turn.
  Widget? _turnCounter(BuildContext context, ColorScheme cs) {
    final id = widget.sessionId;
    if (id == null) return null;
    final events = ref.watch(eventsProvider).forSession(id);
    final startTs = openTurnStartMs(events);
    if (startTs == null) return null;
    final style = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: cs.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final now = liveNowFor(ref, context);
    return ValueListenableBuilder<int>(
      valueListenable: now,
      builder: (context, nowMs, _) {
        final ms = elapsedMs(start: startTs, end: nowMs);
        if (ms == null) return const SizedBox.shrink();
        final label = formatElapsed(ms < 1000 ? 1000 : ms);
        return label == null
            ? const SizedBox.shrink()
            : Text(label, style: style);
      },
    );
  }
}

/// Slides a gradient horizontally across its bounds as [t] goes 0→1, so the
/// highlight band sweeps left→right (a shimmer). Clamp tiling keeps the
/// off-band area the base colour.
class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.t);
  final double t;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues((t * 2 - 1) * bounds.width, 0, 0);
  }
}
