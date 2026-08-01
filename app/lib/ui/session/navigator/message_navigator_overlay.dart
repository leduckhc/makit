/// The shared mount point for the message navigator (SPEC-34).
///
/// Both the mobile `SessionScreen` and the desktop `DesktopChatPane` already
/// wrap their transcript in a `Stack`; each adds this one child, so which
/// affordance the user gets is decided in exactly one place instead of drifting
/// between two surfaces.
///
/// The style comes from [messageNavigatorStyleProvider], which each app root
/// overrides with what that surface can offer — there is no platform sniffing
/// here, and in particular **no `MediaQuery.navigationMode`**: that property is
/// `{traditional, directional}` focus traversal for TV remotes and says nothing
/// about whether a pointer exists.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../store/chat_items.dart';
import '../transcript_list.dart';
import 'navigator_style.dart';
import 'rail.dart';
import 'transcript_jumper.dart';
import 'user_message_indices.dart';

/// Everything a navigator needs. One object so all five styles share a
/// constructor shape and none of them reaches into the store itself.
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

/// Renders whichever navigator the current surface is configured for.
class MessageNavigatorOverlay extends ConsumerStatefulWidget {
  /// Creates the overlay for the transcript driven by [controller].
  const MessageNavigatorOverlay({
    super.key,
    required this.sessionId,
    required this.controller,
    required this.target,
    required this.items,
    required this.hasTrailer,
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

  @override
  ConsumerState<MessageNavigatorOverlay> createState() =>
      _MessageNavigatorOverlayState();
}

class _MessageNavigatorOverlayState
    extends ConsumerState<MessageNavigatorOverlay> {
  late final TranscriptJumper _jumper = TranscriptJumper(
    controller: widget.controller,
    target: widget.target,
    itemCount: () => widget.items.length,
    hasTrailer: () => widget.hasTrailer,
  );

  @override
  void dispose() {
    _jumper.dispose();
    super.dispose();
  }

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

    return switch (style) {
      MessageNavigatorStyle.off => const SizedBox.shrink(),
      MessageNavigatorStyle.rail => MessageRail(context: navigatorContext),
      // Not built yet — the enum ships complete so the preference is
      // forward-compatible, but these styles are still `[coming soon]` in
      // Settings and must not render a half-thing here.
      MessageNavigatorStyle.scrubber ||
      MessageNavigatorStyle.palette ||
      MessageNavigatorStyle.breadcrumb ||
      MessageNavigatorStyle.outline => const SizedBox.shrink(),
    };
  }
}
