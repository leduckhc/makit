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

import '../../store/models.dart';
import 'chat_message.dart';
import 'chat_metrics.dart';
import 'ask_card.dart';
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

/// Maps a folded [ChatItem] to its transcript widget. Tool calls render as
/// inline collapsible rows (see [ToolCallCard]) that expand in place — there is
/// no full-screen detail navigation. Horizontal gutter + inter-row spacing are
/// applied by the caller via [transcriptRow], so the item widgets carry none
/// themselves.
Widget chatItemWidget(ChatItem item) => switch (item) {
  UserMessageItem() => ChatBubble.user(text: item.text, ts: item.ts),
  AgentMessageItem() => AgentMessage(text: item.text, ts: item.ts),
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

class _ThinkingLineState extends State<ThinkingLine> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = TextStyle(
      color: cs.onSurfaceVariant.withValues(alpha: 0.65),
      fontSize: 13,
      fontStyle: FontStyle.italic,
      height: 1.3,
    );
    void toggle() => setState(() => _expanded = !_expanded);
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
        const SizedBox(width: 6),
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
      padding: const EdgeInsets.all(12),
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
          const SizedBox(width: 8),
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
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          fontStyle: FontStyle.italic,
        ),
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
