import 'package:flutter/widgets.dart';

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
/// banners; large = message bubbles.
const double kChatRadiusSmall = 8;
const double kChatRadiusMedium = 12;
const double kChatRadiusLarge = 16;

/// Max height (logical px) of an expanded tool row's body before it scrolls
/// internally — roughly 20 monospace lines plus section chrome. Keeps a long
/// file read or command output from taking over the transcript.
const double kToolExpandedMaxHeight = 340;

/// Tuned status hues for tool-call risk, matching the sidebar `_StatusDot`
/// palette (and the mockups) instead of raw `Colors.orange` / `Colors.red`,
/// which shout against the neutral M3 surfaces.
const Color kToolRiskyColor = Color(0xFFE8A33D);
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
