import 'package:flutter_riverpod/legacy.dart';

/// Layout state for the desktop sidebar. The sidebar can be folded away
/// (fully hidden) and resized within [kSidebarMinWidth]–[kSidebarMaxWidth].
/// State is in-memory (resets on restart) — persistence can be layered on
/// later via shared_preferences if desired.

/// Smallest width the sidebar can be dragged to.
const double kSidebarMinWidth = 250;

/// Largest width the sidebar can be dragged to.
const double kSidebarMaxWidth = 450;

/// Width the sidebar opens at before the user resizes it.
const double kSidebarDefaultWidth = 320;

/// Height of the top drag strip that stands in for the hidden OS titlebar
/// (matches the standard macOS titlebar height, clearing the traffic lights).
const double kTitleBarStripHeight = 28;

/// Left inset that clears the macOS traffic-light buttons overlaying the
/// window's top-left corner — used by the sidebar fold button and, when the
/// sidebar is hidden, by the pane header's unfold button.
const double kTrafficLightInset = 90;

/// Whether the sidebar is folded away (fully hidden).
final sidebarCollapsedProvider = StateProvider<bool>((_) => false);

/// Current sidebar width in logical pixels, clamped to the min/max above.
final sidebarWidthProvider = StateProvider<double>((_) => kSidebarDefaultWidth);
