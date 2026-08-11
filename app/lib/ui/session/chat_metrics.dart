import 'package:flutter/widgets.dart';

import '../../app/theme.dart';

/// Shared layout + color tokens for the chat transcript, used by BOTH the
/// mobile [SessionScreen] and the desktop `DesktopChatPane` so every row
/// (messages, tool cards, thinking/error lines, working indicator) shares one
/// left/right edge, a uniform vertical rhythm, and a single radius scale.
///
/// Rows are *gutter-agnostic*: the item widgets carry no horizontal padding of
/// their own; the surface applies the gutter once via [transcriptRow]. This
/// keeps alignment correct by construction rather than by matching per-widget
/// insets.

/// Horizontal inset applied once by the surface to every transcript row.
const double kChatGutter = 20;

/// Vertical space between adjacent rows. Applied as half above + half below
/// each row by [transcriptRow], so two neighbours sum to a full gap.
const double kChatRowGap = 10;

/// Corner-radius scale. Small = code blocks; medium = tool cards + error
/// banners; large = message bubbles. Aliases of the shared radius tokens.
const double kChatRadiusSmall = kRadius8;
const double kChatRadiusMedium = kRadius12;
const double kChatRadiusLarge = kRadius16;

/// Hairline stroke for code-block panels (markdown fences + tool output). A
/// full 1.0 logical px reads as a heavy frame around every snippet.
///
/// Logical px, not physical: this is one crisp device pixel at 2x, an
/// antialiased 1.5 at 3x and a faint 0.5 at 1x. `width: 0.0` would pin exactly
/// one physical pixel at every ratio instead (and does draw under a border
/// radius), but it reads as "no border" at the call site and moves the weight
/// on 1x/3x away from the 2x rendering this was tuned against.
const double kChatCodeBorderWidth = 0.5;

/// Max height (logical px) of an expanded tool row's body before it scrolls
/// internally — roughly 20 monospace lines plus section chrome. Keeps a long
/// file read or command output from taking over the transcript.
const double kToolExpandedMaxHeight = 340;

/// Leading-glyph size for a collapsed transcript row (tool + thinking). Pinned
/// to `ThinkingLine`'s brain glyph so a tool row is no louder than a reasoning
/// row — see `mockups/tool-one-liner.html` §5.
const double kToolGlyph = 15;

/// Alpha applied to `onSurfaceVariant` for a row's leading glyph and its
/// resolved status tick — the same value the thinking row's brain uses, since
/// the two rows must read as equals.
///
/// 0.70, not the 0.55 this started at: a glyph is a graphical object, so WCAG
/// 1.4.11 asks for 3:1, and 0.55 composited to `#616161` on the dark surface
/// (2.91:1) and `#A7A7A7` on the light one (2.31:1) — measured from the real
/// app, both short. 0.70 lands at 3.92:1 / 3.05:1 and is still visibly quieter
/// than the row's text. Pinned by `theme_contrast_test.dart`.
const double kToolGlyphAlpha = 0.7;

/// Trailing status tick size — a notch under [kToolGlyph], because the leading
/// glyph identifies the row and the tick only confirms it finished.
const double kToolStatusGlyph = 13;

/// Weight of the verb that opens a collapsed tool row (`Run`, `Edit`, …). The
/// verb is the scan column, so it needs *a* step above the payload — but only
/// one: at `w600` (Semibold) the verbs read as headings and pulled the eye away
/// from the payload, which is the actual content. `w500` (Medium) against the
/// payload's `w400` is the smallest step SF Pro Text renders cleanly at 13 px.
const FontWeight kToolVerbWeight = FontWeight.w500;

/// Tuned status hue for a *destructive* tool call (a `delete` kind), matching
/// the sidebar `_StatusDot` palette instead of raw `Colors.red`.
///
/// There is deliberately no `risky` hue: both servers mark every edit/write/
/// bash call risky (`server/src/pi-sessions.ts:259`,
/// `server/src/adapters/acp-map.ts:540`), so an amber glyph fired on every row
/// that was not a read and carried no signal. Keeping *destructive* unspent is
/// what makes it visible when it finally arrives.
const Color kToolDestructiveColor = Color(0xFFE5544B);

/// Wraps a transcript row with the shared horizontal gutter and inter-row gap.
/// Both surfaces call this for every row so all content aligns and the vertical
/// rhythm is uniform regardless of which item types are adjacent.
Widget transcriptRow(Widget child) => Padding(
  padding: const EdgeInsets.symmetric(
    horizontal: kChatGutter,
    vertical: kChatRowGap / 2,
  ),
  child: child,
);
