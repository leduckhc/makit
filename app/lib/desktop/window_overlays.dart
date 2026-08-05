/// The desktop window's in-window overlay flags, and the invariant between them.
///
/// Settings (SPEC-13) and the metrics dashboard (SPEC-37 decision 9) are both
/// `DesktopWindowBody` children occupying the same z-space, so at most one may
/// be open. Both flags live here, together, for two reasons:
///
/// * **The invariant is enforced once, in `DesktopWindowBody`** — the single
///   widget that owns this z-space — rather than at each of the several call
///   sites that open Settings (sidebar button, keyboard shortcut, app menu) or
///   the metrics popover that opens the dashboard. A rule applied at the host
///   cannot be forgotten by the next caller. It is not in the providers
///   themselves because `listenSelf` is unavailable on the `Ref` a legacy
///   `StateProvider` receives, and rewriting both flags as notifiers would churn
///   eight existing call sites for no behavioural gain.
/// * **It breaks an import cycle.** Declaring each flag next to its own widget
///   made `settings_window.dart` and the metrics overlay import each other, which
///   the analyzer resolves to `dynamic` and silently degrades to unchecked code.
///
/// `settingsOpenProvider` is re-exported from `settings_window.dart`, so existing
/// importers are unaffected.
library;

import 'package:flutter_riverpod/legacy.dart';

/// Whether the in-window Settings surface is showing. Kept as a provider (not a
/// route) so opening is instant and preserves the underlying chat state
/// (SPEC-13 requirement #5).
final settingsOpenProvider = StateProvider<bool>((_) => false);

/// Whether the Tier 2 metrics dashboard overlay is showing.
///
/// A flag, not a workspace tab: `Tab` carries only a `sessionId`, so a
/// non-session tab would need a kind tag threaded through persistence,
/// drag/drop, `findTab`, group derivation, auto-select and pruning — a large
/// change to the workspace model for one panel (decision 9).
final metricsDashboardOpenProvider = StateProvider<bool>((_) => false);
