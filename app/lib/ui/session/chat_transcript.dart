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
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../widgets/glass.dart';
import 'ask_card.dart';
import 'chat_message.dart';
import 'chat_metrics.dart';
import 'media_view.dart';
import 'tool_call_card.dart';

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

/// Keeps the rows the user is *reading* nailed to the same screen position when
/// the transcript's extent changes underneath them.
///
/// The transcript is `reverse: true`, so scroll offsets are measured from the
/// newest message. That makes the newest end stable (good: the session opens
/// pinned to the latest) but every offset *above* it shifts whenever content
/// grows — which is constantly, in a live session: streamed tokens extend the
/// tail, new items arrive, a tool row expands. At a fixed pixel offset the user
/// therefore sees the transcript slide, and an expanded row grows upward off
/// the top of the viewport instead of downward.
///
/// Once the user has scrolled into history (beyond [kAnchorNearBottomPx]) this
/// physics absorbs the extent delta into the offset, which re-anchors the
/// viewport to the content instead of to the newest message: streaming below is
/// then invisible. Within the near-bottom band nothing is compensated, so the
/// transcript stays glued to the newest message as before. Folding a row is
/// handled by [retainRowPosition] instead.
class TranscriptScrollPhysics extends ScrollPhysics {
  /// Creates transcript physics that compensate when [anchor] is armed.
  const TranscriptScrollPhysics({required this.anchor, super.parent});

  /// Says which extent changes are real content changes — see [TranscriptAnchor].
  final TranscriptAnchor anchor;

  @override
  TranscriptScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      TranscriptScrollPhysics(anchor: anchor, parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final pixels = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    if (oldPosition.pixels <= kAnchorNearBottomPx) return pixels;
    // While the user drags/flings, the gesture owns the offset and the lazy list
    // is constantly re-estimating the extent of the rows it builds on the way.
    // Compensating then would add a jump mid-drag, so leave scrolling alone.
    if (isScrolling) return pixels;
    final delta = newPosition.maxScrollExtent - oldPosition.maxScrollExtent;
    if (delta == 0 || !anchor.claim()) return pixels;
    return (pixels + delta).clamp(
      newPosition.minScrollExtent,
      newPosition.maxScrollExtent,
    );
  }
}

/// Tells [TranscriptScrollPhysics] which extent changes are worth compensating.
///
/// Armed by the surface when the item list actually changes (a new item, a
/// streamed delta). Every *other* extent change is the lazy list refining its
/// estimate for unbuilt rows — correcting the offset builds more rows, which
/// changes the estimate again, so compensating those drifts the viewport and
/// can make it correct itself every layout pass until it throws. Row folds are
/// handled separately and exactly by [retainRowPosition].
class TranscriptAnchor {
  bool _armed = false;

  /// Marks the next extent change as a real content change.
  void arm() => _armed = true;

  /// Consumes the armed state; true at most once per [arm].
  bool claim() {
    if (!_armed) return false;
    _armed = false;
    return true;
  }

  /// Resets to a clean state. Used when switching to a new session.
  void reset() => _armed = false;
}

/// Runs [change] (a fold/unfold that resizes the row at [context]) while keeping
/// that row anchored to its current screen position.
///
/// Needed because the transcript is `reverse: true`: scroll offsets are measured
/// from the newest message, so a row's *bottom* edge is the fixed one and it
/// grows upward — unfolding a long tool body would shoot the header the user
/// just tapped off the top of the viewport. The row's own before/after screen
/// position is measured (rather than the list's extent delta) because a lazy
/// list also re-estimates the extent of its unbuilt rows when one row grows,
/// which would over-correct.
void retainRowPosition(BuildContext context, VoidCallback change) {
  double? topOf() =>
      (context.findRenderObject() as RenderBox?)?.localToGlobal(Offset.zero).dy;
  final position = Scrollable.maybeOf(context)?.position;
  final before = topOf();
  change();
  if (position == null || before == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted || !position.hasContentDimensions) return;
    final after = topOf();
    if (after == null) return;
    // Positive drift = the row moved up; push the content back down by it. In a
    // reversed viewport (axis direction up) a larger offset moves content down.
    final drift = before - after;
    if (drift.abs() < 0.5) return;
    final sign = position.axisDirection == AxisDirection.up ? 1 : -1;
    position.jumpTo(
      (position.pixels + sign * drift).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
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
Widget chatItemWidget(ChatItem item) => switch (item) {
  UserMessageItem() => ChatBubble.user(text: item.text, ts: item.ts),
  AgentMessageItem() => AgentMessage(text: item.text, ts: item.ts),
  // An image/GIF the agent produced (SPEC-22) — the one thing a terminal
  // client can't show. Rendered inline, tap for fullscreen.
  AgentMediaItem() => AgentMediaView(item: item),
  ThinkingItem() => ThinkingLine(text: item.text),
  // An answered askUserQuestion settles into a quiet resolved card (chosen
  // highlighted, rest dimmed) rather than a foldable tool row (SPEC-25 #1).
  ToolCallItem() when _isAnsweredAsk(item) => AnsweredAskCard(item: item),
  ToolCallItem() => ToolCallCard(item: item),
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

/// Reasoning/thinking trace. Folded to a single greyed one-liner with an
/// ellipsis; a tap toggles between the full (selectable) text and the
/// one-liner. When expanded, tapping the leading icon collapses it again.
class ThinkingLine extends StatefulWidget {
  /// Creates a reasoning line showing [text].
  const ThinkingLine({super.key, required this.text});

  /// The reasoning text (trimmed for display).
  final String text;

  @override
  State<ThinkingLine> createState() => _ThinkingLineState();
}

class _ThinkingLineState extends State<ThinkingLine>
    with AutomaticKeepAliveClientMixin {
  bool _expanded = false;

  // An expansion is user state, so the row must survive being scrolled out of
  // the lazy list's cache — otherwise it silently re-folds itself.
  @override
  bool get wantKeepAlive => _expanded;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: cs.onSurfaceVariant.withValues(alpha: 0.65),
      fontStyle: FontStyle.italic,
      height: 1.3,
    );
    void toggle() => retainRowPosition(
      context,
      () => setState(() {
        _expanded = !_expanded;
        updateKeepAlive();
      }),
    );
    final textWidget = _expanded
        ? SelectableText(widget.text.trim(), style: style, onTap: toggle)
        : Text(
            widget.text.trim(),
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
    // Expanded: SelectableText handles taps on the text for selection; a tap
    // on the leading icon collapses. Collapsed: whole row is a tap target that
    // expands.
    return _expanded
        ? Semantics(
            onTap: toggle,
            onTapHint: 'Collapse thinking',
            child: _buildRow(textWidget, onLeadingTap: toggle),
          )
        : InkWell(onTap: toggle, child: _buildRow(textWidget));
  }

  Widget _buildRow(Widget textWidget, {VoidCallback? onLeadingTap}) {
    final cs = Theme.of(context).colorScheme;
    Widget leading = Icon(
      PhosphorIconsLight.brain,
      size: 15,
      color: cs.onSurfaceVariant.withValues(alpha: 0.55),
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
        Expanded(child: textWidget),
      ],
    );
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
class WorkingIndicator extends StatefulWidget {
  /// Creates the indicator.
  const WorkingIndicator({super.key});

  @override
  State<WorkingIndicator> createState() => _WorkingIndicatorState();
}

class _WorkingIndicatorState extends State<WorkingIndicator>
    with SingleTickerProviderStateMixin {
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

  // One controller for the whole State lifetime, driving the shimmer sweep.
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = cs.onSurfaceVariant.withValues(alpha: 0.18);
    final highlight = cs.onSurface;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => LinearGradient(
            colors: [base, highlight, base],
            stops: const [0.35, 0.5, 0.65],
            transform: _SlideGradient(_c.value),
          ).createShader(bounds),
          child: child,
        );
      },
      child: Text(
        _word,
        style: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(fontStyle: FontStyle.italic),
      ),
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
