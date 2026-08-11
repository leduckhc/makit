/// How a [StatusSeverity] is drawn — glyph, vivid hue, AA-safe label hue.
///
/// One file so the toast, the Activity list and the sidebar badge cannot tint the
/// same severity differently (the failure mode `pr_tone.dart` documents), and so
/// only the hues `DESIGN.md` sanctions are ever used.
library;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../app/theme.dart';
import 'status_event.dart';

IconData statusGlyph(StatusSeverity severity) => switch (severity) {
  StatusSeverity.progress => PhosphorIconsLight.arrowClockwise,
  StatusSeverity.info => PhosphorIconsLight.info,
  StatusSeverity.success => PhosphorIconsLight.checkCircle,
  StatusSeverity.warning => PhosphorIconsLight.warning,
  StatusSeverity.failure => PhosphorIconsLight.warningCircle,
};

/// The **stripe/dot/icon** hue, and the fill behind the unread count.
///
/// `warning` takes the brightness-resolved `statusWarningText` rather than the
/// vivid `kStatusWarning`: measured on the light surface the vivid amber is
/// 2.07:1, under even the 3:1 floor for a UI component, and these glyphs are
/// small (15 pt) and load-bearing. On dark the getter *is* the vivid amber, so
/// the hue only moves where it has to — the same per-theme resolution
/// `prToneTextColor` makes, for the same reason.
Color statusColor(ColorScheme cs, StatusSeverity severity) =>
    switch (severity) {
      StatusSeverity.progress => cs.primary,
      StatusSeverity.info => cs.outline,
      StatusSeverity.success => cs.primary,
      StatusSeverity.warning => cs.statusWarningText,
      StatusSeverity.failure => cs.error,
    };

/// Text printed **on** a [statusColor] fill (the unread count pill) takes
/// `inkOn(cs, fill)` — the house helper from `pr_tone.dart`, which measures both
/// candidate inks against the actual fill. `cs.surface` alone fails AA on the
/// amber (~2.1:1 in light mode). Pinned by `theme_contrast_test.dart`.
/// Short human label for a severity, used by the Activity filter chips.
String statusSeverityLabel(StatusSeverity severity) => switch (severity) {
  StatusSeverity.progress => 'Progress',
  StatusSeverity.info => 'Info',
  StatusSeverity.success => 'Done',
  StatusSeverity.warning => 'Warnings',
  StatusSeverity.failure => 'Failures',
};
