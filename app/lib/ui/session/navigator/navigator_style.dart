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

/// The scrubber's tunables. Same override discipline as [RailOptions].
@immutable
class ScrubberOptions {
  /// Creates scrubber options.
  const ScrubberOptions({this.liveScroll = true, this.timestamps = true});

  /// Whether the transcript scrolls during the drag (false = commit on release).
  final bool liveScroll;

  /// Whether the preview card shows a relative timestamp.
  final bool timestamps;

  @override
  bool operator ==(Object other) =>
      other is ScrubberOptions &&
      other.liveScroll == liveScroll &&
      other.timestamps == timestamps;

  @override
  int get hashCode => Object.hash(liveScroll, timestamps);
}

/// The scrubber's options for the current surface.
final scrubberOptionsProvider = Provider<ScrubberOptions>(
  (ref) => const ScrubberOptions(),
);

/// The breadcrumb's tunables.
@immutable
class BreadcrumbOptions {
  /// Creates breadcrumb options.
  const BreadcrumbOptions({this.autoHide = true, this.counter = true});

  /// Whether the chip dims itself while pinned to the newest message.
  final bool autoHide;

  /// Whether the chip shows its "4/7" position counter.
  final bool counter;

  @override
  bool operator ==(Object other) =>
      other is BreadcrumbOptions &&
      other.autoHide == autoHide &&
      other.counter == counter;

  @override
  int get hashCode => Object.hash(autoHide, counter);
}

/// The breadcrumb's options for the current surface.
final breadcrumbOptionsProvider = Provider<BreadcrumbOptions>(
  (ref) => const BreadcrumbOptions(),
);

/// The palette's tunables.
@immutable
class PaletteOptions {
  /// Creates palette options.
  const PaletteOptions({this.searchAll = false});

  /// Whether the palette searches assistant/tool rows too.
  final bool searchAll;

  @override
  bool operator ==(Object other) =>
      other is PaletteOptions && other.searchAll == searchAll;

  @override
  int get hashCode => searchAll.hashCode;
}

/// The palette's options for the current surface.
final paletteOptionsProvider = Provider<PaletteOptions>(
  (ref) => const PaletteOptions(),
);

/// Outline mode's tunables.
@immutable
class OutlineOptions {
  /// Creates outline options.
  const OutlineOptions({this.hideTools = false, this.showCounts = true});

  /// Whether tool-call rows are hidden as well as assistant messages.
  final bool hideTools;

  /// Whether a per-prompt "N rows hidden" count is shown.
  final bool showCounts;

  @override
  bool operator ==(Object other) =>
      other is OutlineOptions &&
      other.hideTools == hideTools &&
      other.showCounts == showCounts;

  @override
  int get hashCode => Object.hash(hideTools, showCounts);
}

/// Outline mode's options for the current surface.
final outlineOptionsProvider = Provider<OutlineOptions>(
  (ref) => const OutlineOptions(),
);
