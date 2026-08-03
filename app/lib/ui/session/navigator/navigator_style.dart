/// Whether the transcript shows the message rail, and the rail's tunables
/// (SPEC-34).
///
/// This lives in **shared** `ui/` on purpose: the transcript is rendered by both
/// the mobile `SessionScreen` and the desktop `DesktopChatPane`, and shared code
/// must never import `desktop/`. Each app root therefore *overrides*
/// [messageNavigatorStyleProvider] with what that surface can actually offer:
///
/// - desktop → the user's `messageNavigatorStylePreference`;
/// - mobile → left at `off`. The rail is a pointer design, and a phone has no
///   screen to spend on permanent chrome, so mobile reaches its own messages
///   through a sheet in the session-actions menu instead
///   (`messages_sheet.dart`). This is a product choice, not a technical limit:
///   the preference system lives in `store/` and mobile loads it too.
///
/// Coercion is deliberately *not* a function anyone has to remember to call: the
/// rail is unreachable on mobile because mobile never puts it in the provider.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which affordance the transcript offers for finding your own messages.
enum MessageNavigatorStyle {
  /// No navigator at all — builds nothing and attaches no listeners.
  off,

  /// Cosy cluster of ticks in the top-right corner; hover ripples, click jumps.
  rail,
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
