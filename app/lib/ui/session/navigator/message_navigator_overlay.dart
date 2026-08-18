/// The shared mount point for the message navigator (SPEC-message-navigator).
///
/// Both the mobile `SessionScreen` and the desktop `DesktopChatPane` already
/// wrap their transcript in a `Stack`; each adds this one child, so the
/// affordance the user gets is decided in exactly one place instead of drifting
/// between two surfaces.
///
/// Whether the rail appears comes from [messageNavigatorStyleProvider], which
/// each app root overrides with what that surface can offer — there is no
/// platform sniffing here, and in particular **no `MediaQuery.navigationMode`**:
/// that property is `{traditional, directional}` focus traversal for TV remotes
/// and says nothing about whether a pointer exists.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../store/chat_items.dart';
import '../transcript_list.dart';
import 'navigator_style.dart';
import 'rail.dart';
import 'transcript_jumper.dart';
import 'user_message_indices.dart';

/// Everything a navigator needs. One object so the navigator never reaches into
/// the store itself.
@immutable
class MessageNavigatorContext {
  /// Bundles the transcript state a navigator renders from.
  const MessageNavigatorContext({
    required this.items,
    required this.positions,
    required this.jumper,
    required this.target,
    required this.controller,
    required this.hasTrailer,
  });

  /// The transcript, ascending (oldest first).
  final List<ChatItem> items;

  /// Positions within [items] of the user's own messages, ascending.
  final List<int> positions;

  /// Performs the jump.
  final TranscriptJumper jumper;

  /// Render-layer handle, for "which row am I looking at".
  final TranscriptJumpTarget target;

  /// The transcript's scroll controller (offset 0 == newest).
  final ScrollController controller;

  /// Whether a trailing row currently occupies child index 0.
  final bool hasTrailer;

  /// Text of the user message at [positions]`[i]`, for previews.
  String textAt(int i) {
    final item = items[positions[i]];
    return item is UserMessageItem ? item.text : '';
  }
}

/// Renders the message rail when the current surface is configured for it.
class MessageNavigatorOverlay extends ConsumerStatefulWidget {
  /// Creates the overlay for the transcript driven by [controller].
  const MessageNavigatorOverlay({
    super.key,
    required this.sessionId,
    required this.controller,
    required this.target,
    required this.items,
    required this.hasTrailer,
    this.topInset = 0,
  });

  /// Session whose transcript this is.
  final String sessionId;

  /// The transcript's scroll controller.
  final ScrollController controller;

  /// The jump handle also given to the [TranscriptListView].
  final TranscriptJumpTarget target;

  /// The transcript, ascending.
  final List<ChatItem> items;

  /// Whether a trailing row currently occupies child index 0.
  final bool hasTrailer;

  /// Space at the top of the transcript that the navigator must stay clear of.
  ///
  /// Mobile floats a glass top bar over the transcript, so a navigator anchored
  /// at the Stack's top edge would sit *behind* it — invisible and untappable.
  /// Each surface passes the same inset it uses for the list's top padding.
  final double topInset;

  @override
  ConsumerState<MessageNavigatorOverlay> createState() =>
      _MessageNavigatorOverlayState();
}

class _MessageNavigatorOverlayState
    extends ConsumerState<MessageNavigatorOverlay> {
  late final TranscriptJumper _jumper = TranscriptJumper(
    target: widget.target,
    itemCount: () => widget.items.length,
    hasTrailer: () => widget.hasTrailer,
    onFlash: (position) => recordJumpFlash(ref, widget.sessionId, position),
  );

  @override
  Widget build(BuildContext context) {
    final style = ref.watch(messageNavigatorStyleProvider);
    // `off` builds nothing at all: no ticks, no scroll listener, no glass.
    if (style == MessageNavigatorStyle.off) return const SizedBox.shrink();

    final positions = userMessagePositions(widget.items);
    if (positions.isEmpty) return const SizedBox.shrink();

    final navigatorContext = MessageNavigatorContext(
      items: widget.items,
      positions: positions,
      jumper: _jumper,
      target: widget.target,
      controller: widget.controller,
      hasTrailer: widget.hasTrailer,
    );

    // Inset once, here, rather than in the navigator: it places itself with
    // `Positioned` inside this padded box.
    return Positioned.fill(
      top: widget.topInset,
      child: Stack(
        clipBehavior: Clip.none,
        children: [MessageRail(context: navigatorContext)],
      ),
    );
  }
}
