/// Shared chat-transcript rendering used by BOTH the mobile [SessionScreen]
/// and the desktop `DesktopChatPane`, so the two surfaces render an identical
/// item set by construction rather than by two hand-kept-in-sync switches.
///
/// [chatItemWidget] maps a [ChatItem] to its widget; the item widgets
/// ([ThinkingLine], [ErrorBanner], [WorkingIndicator]) take a [compact] flag
/// that toggles the cosmetic mobile/desktop padding (and, for the reasoning
/// line, the icon set) — not a redesign.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../store/models.dart';
import 'chat_message.dart';
import 'tool_call_card.dart';

/// Maps a folded [ChatItem] to its transcript widget. [onOpenTool] is invoked
/// when a tool card is tapped (mobile routes via `go_router`; desktop pushes a
/// full-screen route). [compact] selects the desktop (docked pane) cosmetics.
Widget chatItemWidget(
  ChatItem item, {
  required void Function(ToolCallItem) onOpenTool,
  bool compact = false,
}) => switch (item) {
  UserMessageItem() => ChatBubble.user(text: item.text, ts: item.ts),
  AgentMessageItem() => AgentMessage(text: item.text, ts: item.ts),
  ThinkingItem() => ThinkingLine(text: item.text, compact: compact),
  ToolCallItem() => ToolCallCard(item: item, onTap: () => onOpenTool(item)),
  ErrorItem() => ErrorBanner(message: item.message, compact: compact),
};

/// Reasoning/thinking trace. Folded to a single greyed one-liner with an
/// ellipsis; a tap toggles between the full (selectable) text and the
/// one-liner. When expanded, tapping the leading icon collapses it again.
class ThinkingLine extends StatefulWidget {
  /// Creates a reasoning line showing [text]. [compact] uses the tighter
  /// desktop padding + the `material_symbols` icon; otherwise the mobile
  /// padding + the outlined material icon.
  const ThinkingLine({super.key, required this.text, this.compact = false});

  /// The reasoning text (trimmed for display).
  final String text;

  /// Desktop (docked pane) cosmetics when true; mobile otherwise.
  final bool compact;

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
      widget.compact ? Symbols.psychology : Icons.psychology_outlined,
      weight: 200,
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
    return Padding(
      padding: widget.compact
          ? const EdgeInsets.symmetric(vertical: 6)
          : const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          leading,
          const SizedBox(width: 6),
          Expanded(child: textWidget),
        ],
      ),
    );
  }
}

/// Inline error banner shown for an [ErrorItem]. Mobile shows a leading icon +
/// message on a horizontal-inset card; desktop (compact) shows a plain padded
/// message that matches the docked pane's rhythm.
class ErrorBanner extends StatelessWidget {
  /// Creates an error banner for [message].
  const ErrorBanner({super.key, required this.message, this.compact = false});

  /// The error text.
  final String message;

  /// Desktop (docked pane) cosmetics when true; mobile otherwise.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (compact) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.errorContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(message, style: TextStyle(color: cs.onErrorContainer)),
      );
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

/// Trailing "working" indicator shown at the tail of the transcript while the
/// session is running. Mobile shows a shimmering work-flavoured word; desktop
/// (compact) shows a plain spinner + label suited to the docked pane.
class WorkingIndicator extends StatefulWidget {
  /// Creates the indicator. [compact] renders the plain desktop spinner.
  const WorkingIndicator({super.key, this.compact = false});

  /// Desktop (docked pane) cosmetics when true; mobile shimmer otherwise.
  final bool compact;

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

  AnimationController? _c;

  @override
  void initState() {
    super.initState();
    // Only the mobile shimmer needs an animation controller.
    if (!widget.compact) {
      _c = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400),
      )..repeat();
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.compact) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text('working…'),
          ],
        ),
      );
    }
    final cs = Theme.of(context).colorScheme;
    final base = cs.onSurfaceVariant.withValues(alpha: 0.18);
    final highlight = cs.onSurface;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
      child: AnimatedBuilder(
        animation: _c!,
        builder: (context, child) {
          return ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (bounds) => LinearGradient(
              colors: [base, highlight, base],
              stops: const [0.35, 0.5, 0.65],
              transform: _SlideGradient(_c!.value),
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
