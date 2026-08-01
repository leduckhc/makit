/// The message navigator's style, and the provider shared transcript UI reads to
/// learn which one to render (SPEC-34).
///
/// This lives in **shared** `ui/` on purpose: the transcript is rendered by both
/// the mobile `SessionScreen` and the desktop `DesktopChatPane`, and shared code
/// must never import `desktop/`. Each app root therefore *overrides*
/// [messageNavigatorStyleProvider] with whatever that surface can actually offer:
///
/// - desktop → the user's `messageNavigatorStylePreference` (the full picker);
/// - mobile → `scrubber` or `off`, from a single on/off switch, because the
///   desktop preference system does not reach mobile and the pointer-only styles
///   have no touch story.
///
/// Coercion is deliberately *not* a function anyone has to remember to call: a
/// hover-only style is unreachable on mobile because mobile never puts one in
/// the provider.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which affordance the transcript offers for finding your own messages.
enum MessageNavigatorStyle {
  /// No navigator at all — builds nothing and attaches no listeners.
  off,

  /// Cosy cluster of ticks in the top-right corner; hover ripples, click jumps.
  rail,

  /// Drag the trailing edge; a preview card snaps prompt to prompt.
  scrubber,

  /// A shortcut opens a filterable list of your messages.
  palette,

  /// A chip showing which prompt produced what you are reading.
  breadcrumb,

  /// A toggle that hides assistant output, leaving your prompts as an outline.
  outline,
}

/// The style the current surface should render.
///
/// Defaults to [MessageNavigatorStyle.off] — the safe floor. A surface that
/// forgets to override this gets no navigator rather than a broken one.
final messageNavigatorStyleProvider = Provider<MessageNavigatorStyle>(
  (ref) => MessageNavigatorStyle.off,
);

/// The rail's tunables, as shared UI sees them.
///
/// Same override discipline as [messageNavigatorStyleProvider]: the *storage*
/// lives in the desktop preference system, but shared code reads this value so
/// `ui/` never imports `desktop/`. Defaults here mirror the preference defaults
/// so a surface with no override still renders the intended rail.
@immutable
class RailOptions {
  /// Creates rail options.
  const RailOptions({
    this.spacing = 6,
    this.ripple = true,
    this.encodeLength = true,
  });

  /// Gap between ticks, in logical pixels.
  final int spacing;

  /// Whether hovering ripples the neighbouring ticks.
  final bool ripple;

  /// Whether a tick's length encodes its message's length.
  final bool encodeLength;

  @override
  bool operator ==(Object other) =>
      other is RailOptions &&
      other.spacing == spacing &&
      other.ripple == ripple &&
      other.encodeLength == encodeLength;

  @override
  int get hashCode => Object.hash(spacing, ripple, encodeLength);
}

/// The rail's options for the current surface.
final railOptionsProvider = Provider<RailOptions>((ref) => const RailOptions());
