/// Whether the Tier 2 metrics dashboard overlay is open (SPEC-37 decision 9).
///
/// A flag, not a workspace tab: `Tab` carries only a `sessionId`, so a non-session
/// tab would need a kind tag threaded through persistence, drag/drop, group
/// derivation, auto-select and pruning. This mirrors `settingsOpenProvider`
/// instead, which already solves exactly this problem.
///
/// The overlay that renders it lands with T10; this seam exists separately so the
/// Tier 1 popover's `Open dashboard →` has a real destination to set.
library;

import 'package:flutter_riverpod/legacy.dart';

/// True while the dashboard overlay is showing.
final metricsDashboardOpenProvider = StateProvider<bool>((ref) => false);
